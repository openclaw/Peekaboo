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
        Types text into UI elements or at current focus.
        Supports special keys ({return}, {tab}, etc.) plus human typing (--wpm) or fixed-delay (--delay) pacing.
        Can target specific elements or type at current keyboard focus. Uses background delivery by default when a
        target process is known; set `foreground` when the app must be focused first.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.5
        and anthropic/claude-opus-4-8
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "text": SchemaBuilder.string(
                    description: "The text to type. If not specified, can use special key flags instead."),
                "on": SchemaBuilder.string(
                    description: "Optional. Element ID to type into (from `see` or `inspect_ui`). " +
                        "If not specified, types at current focus."),
                "snapshot": SchemaBuilder.string(
                    description: "Optional. Snapshot ID from `see` or `inspect_ui`. " +
                        "Uses latest snapshot if not specified."),
                "delay": SchemaBuilder.number(
                    description: "Optional. Delay between keystrokes in milliseconds (linear profile). Default: 5.",
                    default: 5),
                "profile": SchemaBuilder.string(
                    description: "Optional. Typing profile: human (default) or linear."),
                "wpm": SchemaBuilder.number(
                    description: "Optional. Human typing speed (80-220 WPM). Overrides delay when set."),
                "clear": SchemaBuilder.boolean(
                    description: "Optional. Clear the field before typing (Cmd+A, Delete).",
                    default: false),
                "press_return": SchemaBuilder.boolean(
                    description: "Optional. Press return/enter after typing.",
                    default: false),
                "tab": SchemaBuilder.number(
                    description: "Optional. Press tab N times."),
                "escape": SchemaBuilder.boolean(
                    description: "Optional. Press escape key.",
                    default: false),
                "delete": SchemaBuilder.boolean(
                    description: "Optional. Press delete/backspace key.",
                    default: false),
                "foreground": SchemaBuilder.boolean(
                    description: "Optional. Focus target and send foreground/global keyboard input.",
                    default: false),
                "app": SchemaBuilder.string(
                    description: "Optional. Target app name/bundle ID, or 'PID:<n>' for background typing."),
                "pid": SchemaBuilder.number(
                    description: "Optional. Target process ID for background typing when no element snapshot is used."),
                "window_id": SchemaBuilder.number(description: "Optional. Window ID for background typing."),
                "window_title": SchemaBuilder.string(description: "Optional. Window title (substring match)."),
                "window_index": SchemaBuilder
                    .number(description: "Optional. Window index (0-based); requires app/pid."),
            ],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        do {
            let request = try self.parseRequest(arguments: arguments)
            return try await self.performType(request: request)
        } catch let error as TypeToolValidationError {
            return ToolResponse.error(error.message)
        } catch let error as MCPInteractionTargetError {
            return ToolResponse.error(error.localizedDescription)
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
        let profile = try self.parseProfile(arguments.getString("profile"))
        let target = MCPInteractionTarget(
            app: arguments.getString("app"),
            pid: arguments.getInt("pid"),
            windowTitle: arguments.getString("window_title"),
            windowIndex: arguments.getInt("window_index"),
            windowId: arguments.getInt("window_id"))

        let request = TypeRequest(
            text: arguments.getString("text"),
            elementId: arguments.getString("on"),
            snapshotId: arguments.getString("snapshot"),
            delay: Int(arguments.getNumber("delay") ?? 5),
            profile: profile,
            wordsPerMinute: arguments.getNumber("wpm").map { Int($0) },
            clearField: arguments.getBool("clear") ?? false,
            pressReturn: arguments.getBool("press_return") ?? false,
            tabCount: arguments.getNumber("tab").map { Int($0) },
            pressEscape: arguments.getBool("escape") ?? false,
            pressDelete: arguments.getBool("delete") ?? false,
            foreground: arguments.getBool("foreground") ?? false,
            target: target)

        guard request.hasActions else {
            throw TypeToolValidationError("Must specify text to type or special key actions")
        }

        if let wpm = request.wordsPerMinute, !(80...220).contains(wpm) {
            throw TypeToolValidationError("wpm must be between 80 and 220")
        }

        if request.wordsPerMinute != nil, request.profile != .human {
            throw TypeToolValidationError("wpm is only supported with the human profile")
        }

        return request
    }

    private func parseProfile(_ raw: String?) throws -> TypingProfile {
        guard let raw else { return .human }
        guard let profile = TypingProfile(rawValue: raw.lowercased()) else {
            throw TypeToolValidationError("profile must be 'human' or 'linear'")
        }
        return profile
    }

    @MainActor
    private func performType(request: TypeRequest) async throws -> ToolResponse {
        let automation = self.context.automation
        let startTime = Date()

        let targetContext = try await self.resolveTargetContext(for: request)

        let targetProcessIdentifier = try await self.backgroundProcessIdentifier(
            request: request,
            targetContext: targetContext)

        try await self.focusIfNeeded(
            targetContext: targetContext,
            request: request,
            automation: automation,
            targetProcessIdentifier: targetProcessIdentifier)
        let actions = try self.buildActions(for: request)
        let effectiveSnapshotId = targetContext?.snapshot.id ?? request.snapshotId
        let typeResult: TypeResult = if let targetProcessIdentifier {
            try await self.performBackgroundType(
                actions: actions,
                cadence: request.cadence,
                snapshotId: effectiveSnapshotId,
                targetProcessIdentifier: targetProcessIdentifier,
                automation: automation)
        } else {
            try await automation.typeActions(
                actions,
                cadence: request.cadence,
                snapshotId: effectiveSnapshotId)
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
        targetProcessIdentifier: Int?) async throws
    {
        guard let context = targetContext else {
            if targetProcessIdentifier == nil {
                _ = try await request.target.focusIfRequested(
                    windows: self.context.windows,
                    onlyWhenTargeted: true)
            }
            return
        }

        let element = context.element
        if let targetProcessIdentifier, !request.foreground {
            guard let automation = automation as? any TargetedClickServiceProtocol,
                  automation.supportsTargetedClicks
            else {
                throw TypeToolValidationError("This automation host does not support background element focus.")
            }
            try await automation.click(
                target: .elementId(element.id),
                clickType: .single,
                snapshotId: context.snapshot.id,
                targetProcessIdentifier: pid_t(targetProcessIdentifier))
        } else {
            try await automation.click(
                target: .elementId(element.id),
                clickType: .single,
                snapshotId: context.snapshot.id)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private func backgroundProcessIdentifier(
        request: TypeRequest,
        targetContext: TargetElementContext?) async throws -> Int?
    {
        guard !request.foreground else { return nil }

        if let processIdentifier = try await request.target.targetProcessIdentifierValue(
            applications: self.context.applications,
            windows: self.context.windows),
            processIdentifier > 0
        {
            return processIdentifier
        }
        if let processIdentifier = targetContext?.snapshot.applicationProcessId, processIdentifier > 0 {
            return Int(processIdentifier)
        }
        return nil
    }

    @MainActor
    private func performBackgroundType(
        actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: Int,
        automation: any UIAutomationServiceProtocol) async throws -> TypeResult
    {
        guard let automation = automation as? any TargetedTypeServiceProtocol,
              automation.supportsTargetedTypeActions
        else {
            throw TypeToolValidationError("This automation host does not support background typing.")
        }
        return try await automation.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: pid_t(targetProcessIdentifier))
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

        return TargetElementContext(snapshot: snapshot, element: element)
    }
}
