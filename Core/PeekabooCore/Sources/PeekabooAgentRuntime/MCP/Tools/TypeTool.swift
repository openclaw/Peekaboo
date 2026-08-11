import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for typing text
public struct TypeTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "TypeTool")
    private let context: MCPToolContext

    public let name = "type"

    public var description: String {
        """
        Types text into UI elements or a targeted app process.
        Supports human typing (--wpm) or fixed-delay (--delay) pacing. Use `press` for key presses and chords.
        Background delivery requires an element/snapshot/app/pid target. Set `foreground=true` for intentional input
        at the current keyboard focus or when the app must be focused first. app and pid are alternatives; provide at
        most one window selector, and pair window_title/window_index with app or pid.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6
        and anthropic/claude-opus-5
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "text": SchemaBuilder.string(description: "The text to type."),
                "on": SchemaBuilder.string(
                    description: "Optional. Element ID to type into (from `see` or `inspect_ui`). " +
                        "If omitted, provide snapshot/app/pid for background delivery or set foreground=true."),
                "snapshot": SchemaBuilder.string(
                    description: "Optional. Snapshot ID from `see` or `inspect_ui`. " +
                        "When `on` is omitted, the snapshot process is the background typing target."),
                "delay": SchemaBuilder.integer(
                    description: "Optional. Delay between keystrokes in milliseconds (linear profile). Default: 0.",
                    default: 0),
                "profile": SchemaBuilder.string(
                    description: "Optional. Typing profile: linear (default) or human."),
                "wpm": SchemaBuilder.integer(
                    description: "Optional. Human typing speed (80-220 WPM). Overrides delay when set."),
                "clear": SchemaBuilder.boolean(
                    description: "Optional. Clear the field before typing (Cmd+A, Delete).",
                    default: false),
                "foreground": SchemaBuilder.boolean(
                    description: "Optional. Focus a supplied target or intentionally send global keyboard input.",
                    default: false),
                "app": SchemaBuilder.string(
                    description: "Optional. Target app name/bundle ID, or 'PID:<n>' for background typing."),
                "pid": SchemaBuilder.integer(
                    description: "Optional. Target process ID for background typing when no element snapshot is used."),
                "window_id": SchemaBuilder.integer(description: "Optional. Window ID; requires foreground=true."),
                "window_title": SchemaBuilder
                    .string(description: "Optional. Window title (substring match); requires foreground=true."),
                "window_index": SchemaBuilder
                    .integer(description: "Optional. Window index (0-based); requires app/pid and foreground=true."),
            ],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let mutationTracker = TypeMutationTracker()
        do {
            let request = try self.parseRequest(arguments: arguments)
            return try await self.performType(request: request, mutationTracker: mutationTracker)
        } catch let error as TypeToolValidationError {
            return ToolResponse.error(error.message)
        } catch let error as MCPInteractionTargetError {
            return ToolResponse.error(error.localizedDescription)
        } catch let error as InputDeliveryIndeterminateError {
            let invalidatedSnapshotId = await UISnapshotManager.shared
                .invalidateActiveSnapshot(id: mutationTracker.snapshotId)
            var meta: [String: Value] = [
                "mutation_dispatched": .bool(true),
                "retry_safe": .bool(false),
                "requires_fresh_observation": .bool(true),
                "characters_typed": error.emittedUnitCount.map(Value.int) ?? .null,
            ]
            if let invalidatedSnapshotId {
                meta["invalidated_snapshot"] = .string(invalidatedSnapshotId)
            }
            return ToolResponse.error(
                error.localizedDescription,
                meta: .object(meta))
        } catch {
            self.logger.error("Type execution failed: \(error)")
            return ToolResponse.error("Failed to type text: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func getSnapshot(id: String?) async -> UISnapshot? {
        await UISnapshotManager.shared.getSnapshot(id: id)
    }

    private func parseRequest(arguments: ToolArguments) throws -> TypeRequest {
        let wordsPerMinute = try arguments.validatedInt("wpm")
        let profile = try self.parseProfile(arguments.getString("profile"), wordsPerMinute: wordsPerMinute)
        let target = try MCPInteractionTarget(
            app: arguments.getString("app"),
            pid: arguments.validatedInt("pid"),
            windowTitle: arguments.getString("window_title"),
            windowIndex: arguments.validatedInt("window_index"),
            windowId: arguments.validatedInt("window_id"))

        let request = try TypeRequest(
            text: arguments.getString("text"),
            elementId: arguments.getString("on"),
            snapshotId: arguments.getString("snapshot"),
            delay: arguments.validatedInt("delay") ?? 0,
            profile: profile,
            wordsPerMinute: wordsPerMinute,
            clearField: arguments.getBool("clear") ?? false,
            foreground: arguments.getBool("foreground") ?? false,
            target: target)

        guard request.hasActions else {
            throw TypeToolValidationError("Must specify text to type or clear=true")
        }

        if let wpm = request.wordsPerMinute, !(80...220).contains(wpm) {
            throw TypeToolValidationError("wpm must be between 80 and 220")
        }

        if request.wordsPerMinute != nil, request.profile != .human {
            throw TypeToolValidationError("wpm is only supported with the human profile")
        }

        return request
    }

    private func parseProfile(_ raw: String?, wordsPerMinute: Int?) throws -> TypingProfile {
        guard let raw else { return wordsPerMinute == nil ? .linear : .human }
        guard let profile = TypingProfile(rawValue: raw.lowercased()) else {
            throw TypeToolValidationError("profile must be 'human' or 'linear'")
        }
        return profile
    }

    @MainActor
    private func performType(
        request: TypeRequest,
        mutationTracker: TypeMutationTracker) async throws -> ToolResponse
    {
        let automation = self.context.automation
        let startTime = Date()

        let targetContext = try await self.resolveTargetContext(for: request)
        let snapshotContext = try await self.resolveSnapshotContext(
            for: request,
            targetContext: targetContext)

        let targetProcessIdentity = try await self.backgroundProcessIdentity(
            request: request,
            snapshot: snapshotContext)
        let targetProcessIdentifier = targetProcessIdentity.map { Int($0.processIdentifier) }
        let actions = try self.buildActions(for: request)
        let effectiveSnapshotId = snapshotContext?.id
        mutationTracker.snapshotId = effectiveSnapshotId

        let elementFocusClickCompleted: Bool
        do {
            elementFocusClickCompleted = try await self.focusIfNeeded(
                targetContext: targetContext,
                request: request,
                automation: automation,
                targetProcessIdentity: targetProcessIdentity)
        } catch let error as InputDeliveryIndeterminateError {
            throw InputDeliveryIndeterminateError(
                operation: .type,
                causeDescription: error.causeDescription ?? error.localizedDescription)
        }

        let typeResult: TypeResult
        do {
            if elementFocusClickCompleted {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if let targetProcessIdentity {
                typeResult = try await self.performBackgroundType(
                    actions: actions,
                    cadence: request.cadence,
                    snapshotId: effectiveSnapshotId,
                    expectedProcessIdentity: targetProcessIdentity,
                    automation: automation)
            } else {
                typeResult = try await automation.typeActions(
                    actions,
                    cadence: request.cadence,
                    snapshotId: effectiveSnapshotId)
            }
        } catch let error as InputDeliveryIndeterminateError {
            throw InputDeliveryIndeterminateError(
                operation: .type,
                emittedUnitCount: error.emittedUnitCount,
                causeDescription: error.causeDescription ?? error.localizedDescription)
        } catch {
            guard elementFocusClickCompleted else { throw error }
            throw InputDeliveryIndeterminateError(
                operation: .type,
                causeDescription: error.localizedDescription)
        }

        let invalidatedSnapshotId = await UISnapshotManager.shared.invalidateActiveSnapshot(id: effectiveSnapshotId)
        let executionTime = Date().timeIntervalSince(startTime)
        let message = self.buildSummary(
            request: request,
            executionTime: executionTime,
            result: typeResult)
        var baseMetaDict: [String: Value] = [
            "execution_time": .double(executionTime),
            "characters_typed": .double(Double(typeResult.totalCharacters)),
            "delivery_mode": .string(targetProcessIdentifier == nil ? "foreground" : "background"),
        ]
        if let targetProcessIdentifier {
            baseMetaDict["target_pid"] = .int(targetProcessIdentifier)
        }
        if let invalidatedSnapshotId {
            baseMetaDict["invalidated_snapshot"] = .string(invalidatedSnapshotId)
            baseMetaDict["requires_fresh_observation"] = .bool(true)
        }
        let baseMeta: Value = .object(baseMetaDict)
        let summary = self.buildEventSummary(
            request: request,
            targetContext: targetContext)
        let mergedMeta = ToolEventSummary.merge(summary: summary, into: baseMeta)

        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: mergedMeta)
    }

    @MainActor
    private func focusIfNeeded(
        targetContext: TargetElementContext?,
        request: TypeRequest,
        automation: any UIAutomationServiceProtocol,
        targetProcessIdentity: ApplicationProcessIdentity?) async throws -> Bool
    {
        guard let context = targetContext else {
            if targetProcessIdentity == nil {
                _ = try await request.target.focusIfRequested(
                    windows: self.context.windows,
                    onlyWhenTargeted: true)
            }
            return false
        }

        let element = context.element
        if let targetProcessIdentity, !request.foreground {
            guard let automation = automation as? any TargetedClickServiceProtocol,
                  automation.supportsTargetedClicks,
                  automation.supportsProcessGenerationPinnedClicks
            else {
                throw TypeToolValidationError("This automation host does not support background element focus.")
            }
            try await automation.click(
                target: .elementId(element.id),
                clickType: .single,
                snapshotId: context.snapshot.id,
                expectedProcessIdentity: targetProcessIdentity)
        } else {
            try await automation.click(
                target: .elementId(element.id),
                clickType: .single,
                snapshotId: context.snapshot.id)
        }
        return true
    }

    private func backgroundProcessIdentity(
        request: TypeRequest,
        snapshot: UISnapshot?) async throws -> ApplicationProcessIdentity?
    {
        guard !request.foreground else { return nil }

        if request.target.hasTarget {
            let identity = try await request.target.requireBackgroundProcessIdentity(
                applications: self.context.applications,
                windows: self.context.windows)
            if let snapshot {
                guard let snapshotIdentity = try await self.snapshotProcessIdentity(snapshot) else {
                    throw TypeToolValidationError(
                        "The selected snapshot has no capture-time process-generation receipt. " +
                            "Capture fresh UI state.")
                }
                guard snapshotIdentity == identity else {
                    throw TypeToolValidationError(
                        "The selected snapshot belongs to a different process generation. Capture fresh UI state.")
                }
            }
            return identity
        }
        if let identity = try await self.snapshotProcessIdentity(snapshot) {
            return identity
        }
        if snapshot != nil || request.elementId != nil || request.snapshotId != nil {
            throw TypeToolValidationError(
                "The selected snapshot does not identify a target process. Capture an app/window snapshot or set " +
                    "foreground=true for intentional global input.")
        }
        throw TypeToolValidationError(
            "Typing requires on, snapshot, app, or pid targeting. Set foreground=true for intentional global input.")
    }

    @MainActor
    private func performBackgroundType(
        actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity,
        automation: any UIAutomationServiceProtocol) async throws -> TypeResult
    {
        guard let automation = automation as? any TargetedTypeServiceProtocol,
              automation.supportsTargetedTypeActions,
              automation.supportsProcessGenerationPinnedTypeActions
        else {
            throw TypeToolValidationError("This automation host does not support background typing.")
        }
        return try await automation.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity)
    }

    private func snapshotProcessIdentity(_ snapshot: UISnapshot?) async throws -> ApplicationProcessIdentity? {
        guard let snapshot, let processIdentifier = snapshot.applicationProcessId, processIdentifier > 0 else {
            return nil
        }
        if let windowIdentity = snapshot.windowMutationIdentity,
           windowIdentity.ownerProcessIdentifier != processIdentifier
        {
            throw TypeToolValidationError("The selected snapshot has inconsistent process metadata.")
        }
        if let identity = snapshot.applicationProcessIdentity {
            return identity
        }
        throw TypeToolValidationError(
            "The selected snapshot has no capture-time process-generation receipt. Capture fresh UI state.")
    }

    @MainActor
    private func resolveTargetContext(for request: TypeRequest) async throws -> TargetElementContext? {
        guard let elementId = request.elementId else { return nil }
        guard let snapshot = await self.getSnapshot(id: request.snapshotId) else {
            throw TypeToolValidationError("No active snapshot. Run 'see' or 'inspect_ui' first to capture UI state.")
        }

        guard let element = await snapshot.getElement(byId: elementId) else {
            throw TypeToolValidationError(
                "Element '\(elementId)' not found in current snapshot. Run 'see' or 'inspect_ui' to update UI state.")
        }
        guard !element.isOCRSemanticEvidence else {
            throw TypeToolValidationError(OCRSemanticEvidencePolicy.interactionRefusalMessage)
        }

        return TargetElementContext(snapshot: snapshot, element: element)
    }

    private func resolveSnapshotContext(
        for request: TypeRequest,
        targetContext: TargetElementContext?) async throws -> UISnapshot?
    {
        if let targetContext {
            return targetContext.snapshot
        }
        guard request.snapshotId != nil else { return nil }
        guard let snapshot = await self.getSnapshot(id: request.snapshotId) else {
            throw TypeToolValidationError("Snapshot not found. Run 'see' or 'inspect_ui' to capture fresh UI state.")
        }
        return snapshot
    }
}

@MainActor
private final class TypeMutationTracker {
    var snapshotId: String?
}
