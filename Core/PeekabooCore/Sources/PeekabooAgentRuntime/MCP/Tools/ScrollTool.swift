import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

private typealias ToolScrollDirection = PeekabooFoundation.ScrollDirection

/// MCP tool for scrolling UI elements or at current mouse position
public struct ScrollTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "ScrollTool")
    private let context: MCPToolContext

    public let name = "scroll"

    public var description: String {
        """
        Scrolls a fresh UI target in the background without interrupting the user. Peekaboo prefers
        Accessibility, then may use exact-window PID-routed wheel events for an opaque visible WebKit target.
        Set foreground=true to focus the target and allow global wheel events at the pointer.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6
        and anthropic/claude-opus-5
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "direction": SchemaBuilder.string(
                    description: "Scroll direction: up (content moves up), down (content moves down), left, or right.",
                    enum: ["up", "down", "left", "right"]),
                "on": SchemaBuilder.string(
                    description: "Element ID from `see` or `inspect_ui`. Required in background mode; " +
                        "omit only with foreground=true to scroll at the current physical pointer."),
                "snapshot": SchemaBuilder.string(
                    description: "Optional. Snapshot ID from `see` or `inspect_ui`. " +
                        "Uses latest snapshot if not specified."),
                "amount": SchemaBuilder.integer(
                    description: "Optional. Number of scroll ticks/lines. Default: 3.",
                    default: 3),
                "delay": SchemaBuilder.integer(
                    description: "Optional. Foreground-only delay between scroll ticks in milliseconds. Default: 0.",
                    default: 0),
                "smooth": SchemaBuilder.boolean(
                    description: "Optional. Use smooth synthetic scrolling; requires foreground=true.",
                    default: false),
                "foreground": SchemaBuilder.boolean(
                    description: "Optional. Focus the target and allow global wheel events. Default: false.",
                    default: false),
            ],
            required: ["direction"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        do {
            let request = try self.parseRequest(arguments: arguments)
            return try await self.performScroll(request: request)
        } catch let error as ScrollToolValidationError {
            return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: error.message,
                reason: error.refusalReason)
        } catch {
            self.logger.error("Scroll execution failed: \(error)")
            return ToolResponse.error("Failed to perform scroll: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func parseScrollDirection(_ direction: String) -> ToolScrollDirection? {
        switch direction.lowercased() {
        case "up":
            .up
        case "down":
            .down
        case "left":
            .left
        case "right":
            .right
        default:
            nil
        }
    }

    private func getSnapshot(id: String?) async -> UISnapshot? {
        await self.context.uiSnapshots.getSnapshot(id: id)
    }

    private func parseRequest(arguments: ToolArguments) throws -> ScrollToolRequest {
        guard let directionString = arguments.getString("direction") else {
            throw ScrollToolValidationError("Direction is required")
        }

        guard let direction = self.parseScrollDirection(directionString) else {
            throw ScrollToolValidationError("Invalid direction. Must be one of: up, down, left, right")
        }

        let amount = try arguments.validatedInt("amount") ?? 3
        guard amount > 0 else {
            throw ScrollToolValidationError("Amount must be greater than 0")
        }
        guard amount <= 50 else {
            throw ScrollToolValidationError("Amount must be 50 or less to prevent excessive scrolling")
        }

        let foreground = arguments.getBool("foreground") ?? false
        let elementId = arguments.getString("on")
        let delay = try arguments.validatedInt("delay") ?? 0
        let smooth = arguments.getBool("smooth") ?? false
        guard delay >= 0 else {
            throw ScrollToolValidationError("Delay must be zero or greater")
        }
        guard foreground || elementId != nil else {
            throw ScrollToolValidationError(
                "Background scroll requires 'on' from a fresh scrollable or exact-window WebKit snapshot; " +
                    "set foreground=true to scroll at the physical pointer.")
        }
        guard foreground || (!smooth && delay == 0) else {
            throw ScrollToolValidationError(
                "smooth scrolling and a nonzero delay require foreground=true because they synthesize wheel events.")
        }

        return ScrollToolRequest(
            direction: direction,
            elementId: elementId,
            snapshotId: arguments.getString("snapshot"),
            amount: amount,
            delay: delay,
            smooth: smooth,
            foreground: foreground)
    }

    @MainActor
    private func performScroll(request: ScrollToolRequest) async throws -> ToolResponse {
        let automation = self.context.automation
        let startTime = Date()

        let target = try await self.resolveTargetDescription(request: request)
        let setupFocusCompleted: Bool = if request.foreground {
            try await self.focusTargetIfNeeded(target)
        } else {
            false
        }
        let serviceRequest = ScrollRequest(
            direction: request.direction,
            amount: request.amount,
            target: target.elementId,
            smooth: request.smooth,
            delay: request.delay,
            snapshotId: target.snapshotId,
            foreground: request.foreground)
        let actionResult: UIAutomationActionResult<Void>
        do {
            if let outcomeAutomation = automation as? any UIAutomationActionOutcomeProviding {
                actionResult = try await outcomeAutomation.scrollWithOutcome(serviceRequest)
            } else {
                actionResult = try await UIAutomationActionResult(
                    payload: automation.scroll(serviceRequest),
                    outcome: nil)
            }
            try DesktopActionFailure.requireConfirmedIfReported(
                actionResult.outcome,
                operation: "Scroll")
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: Self.aggregateFailure(failure, setupFocusCompleted: setupFocusCompleted),
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: target.snapshotId)
        } catch {
            guard setupFocusCompleted else { throw error }
            let failure = DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                unitCount: DesktopActionOutcome.DispatchUnitCount(1),
                message: "Scroll failed after its setup focus completed.",
                hint: "Observe the target before deciding whether to retry scrolling.",
                causeDescription: error.localizedDescription)
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: target.snapshotId)
        }

        // A successful window focus has no native receipt. Keep the leaf receipt only when it is the
        // whole operation; otherwise mirror Press/Type and expose conservative composite semantics.
        let responseOutcome = setupFocusCompleted ? nil : actionResult.outcome
        let mutationDispatched = setupFocusCompleted ||
            (actionResult.outcome?.dispatchState.mutationDispatched ?? true)
        let invalidatedSnapshotId = await MCPDesktopActionSnapshotInvalidator.invalidate(
            uiSnapshots: self.context.uiSnapshots,
            snapshotID: target.snapshotId,
            mutationDispatched: mutationDispatched)
        let executionTime = Date().timeIntervalSince(startTime)
        let scrollDescription = request.smooth ? "smooth scroll" : "scroll"
        let duration = String(format: "%.2f", executionTime) + "s"
        let message = "\(AgentDisplayTokens.Status.success) Performed \(scrollDescription) \(request.direction) " +
            "(\(request.amount) ticks) \(target.description) in \(duration)"

        let summary = ToolEventSummary(
            targetApp: target.appName,
            actionDescription: request.smooth ? "Smooth scroll" : "Scroll",
            scrollDirection: request.direction.rawValue,
            scrollAmount: Double(request.amount),
            notes: target.description)
        var baseMeta: [String: Value] = [:]
        if setupFocusCompleted {
            baseMeta["effect"] = .string("unverifiable")
            baseMeta["mutation_dispatched"] = .bool(true)
            baseMeta["retry_safe"] = .bool(false)
            baseMeta["requires_fresh_observation"] = .bool(true)
        }
        if let invalidatedSnapshotId {
            baseMeta["invalidated_snapshot"] = .string(invalidatedSnapshotId)
        }
        let meta = try MCPToolResponseMetadataProjector.metadata(
            merging: baseMeta,
            outcome: responseOutcome)
        return ToolResponse.text(message, meta: ToolEventSummary.merge(summary: summary, into: meta))
    }

    @MainActor
    private func resolveTargetDescription(request: ScrollToolRequest) async throws -> ScrollTargetDescription {
        guard let elementId = request.elementId else {
            return ScrollTargetDescription(
                elementId: nil,
                description: "at current mouse position",
                appName: nil,
                snapshotId: request.snapshotId,
                windowTitle: nil,
                windowID: nil)
        }

        guard let snapshot = await self.getSnapshot(id: request.snapshotId) else {
            throw ScrollToolValidationError(
                "No active snapshot. Run 'see' or 'inspect_ui' first to capture UI state.",
                refusalReason: .targetUnavailable)
        }

        guard let element = await snapshot.getElement(byId: elementId) else {
            throw ScrollToolValidationError(
                "Element '\(elementId)' not found in current snapshot. Run 'see' or 'inspect_ui' to update UI state.",
                refusalReason: .targetUnavailable)
        }
        guard !element.isOCRSemanticEvidence else {
            throw ScrollToolValidationError(OCRSemanticEvidencePolicy.interactionRefusalMessage)
        }

        let label = element.title ?? element.label ?? "untitled"
        let description = "on \(element.role): \(label)"
        let screenshotMetadata = await snapshot.screenshotMetadata
        return ScrollTargetDescription(
            elementId: elementId,
            description: description,
            appName: snapshot.applicationName,
            snapshotId: snapshot.id,
            windowTitle: snapshot.windowTitle,
            windowID: screenshotMetadata?.windowInfo?.windowID)
    }

    @MainActor
    private func focusTargetIfNeeded(_ target: ScrollTargetDescription) async throws -> Bool {
        if let windowID = target.windowID {
            try await self.context.windows.focusWindow(target: .windowId(windowID))
            return true
        } else if let appName = target.appName, let windowTitle = target.windowTitle {
            try await self.context.windows.focusWindow(target: .applicationAndTitle(app: appName, title: windowTitle))
            return true
        } else if let appName = target.appName {
            try await self.context.windows.focusWindow(target: .application(appName))
            return true
        }
        return false
    }

    private static func aggregateFailure(
        _ failure: DesktopActionFailure,
        setupFocusCompleted: Bool) -> DesktopActionFailure
    {
        guard setupFocusCompleted else { return failure }
        let leafUnits: Int? = if let count = failure.outcome.dispatchState.unitCount?.rawValue {
            count
        } else if failure.outcome.dispatchState.mutationDispatched {
            nil
        } else {
            0
        }
        let unitCount = leafUnits.flatMap { DesktopActionOutcome.DispatchUnitCount(1 + $0) }
        return .indeterminate(
            route: failure.outcome.route,
            delivery: nil,
            evidence: .completionUnknown,
            unitCount: unitCount,
            message: "Scroll failed after its setup focus completed.",
            hint: "Observe the target before deciding whether to retry scrolling.",
            causeDescription: failure.localizedDescription)
    }
}

private struct ScrollToolRequest {
    let direction: ToolScrollDirection
    let elementId: String?
    let snapshotId: String?
    let amount: Int
    let delay: Int
    let smooth: Bool
    let foreground: Bool
}

private struct ScrollTargetDescription {
    let elementId: String?
    let description: String
    let appName: String?
    let snapshotId: String?
    let windowTitle: String?
    let windowID: Int?
}

private struct ScrollToolValidationError: Error {
    let message: String
    let refusalReason: DesktopActionOutcome.RefusalReason

    init(
        _ message: String,
        refusalReason: DesktopActionOutcome.RefusalReason = .invalidRequest)
    {
        self.message = message
        self.refusalReason = refusalReason
    }
}
