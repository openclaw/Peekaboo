import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

public struct ActionTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "ActionTool")
    private let context: MCPToolContext

    public let name = "action"

    public var description: String {
        """
        Invokes a named accessibility action on an element, such as AXPress, AXShowMenu, or AXIncrement.
        Use with element IDs from `see` or `inspect_ui` when a semantic action is available.
        Background-only policy refuses actions that can raise or expose foreground UI, including AXPress and
        AXShowMenu; use a dedicated background semantic tool or a human-authorized foreground-capable session.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6, anthropic/claude-opus-5
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "on": SchemaBuilder.string(
                    description: "Opaque element ID from current `see` or `inspect_ui` output, or a query string."),
                "action": SchemaBuilder.string(
                    description: "Accessibility action name to invoke, e.g. AXPress, AXShowMenu, AXIncrement."),
                "snapshot": SchemaBuilder.string(
                    description: "Optional snapshot ID from `see` or `inspect_ui`; latest is used when omitted."),
            ],
            required: ["on", "action"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        var effectiveSnapshotId: String?
        do {
            let request = try ActionRequest(arguments: arguments)
            guard let automation = self.context.automation as? any ElementActionAutomationServiceProtocol else {
                throw ActionToolError(
                    "action is not supported by this automation host",
                    errorCode: "RUNTIME_INCOMPATIBLE",
                    refusalReason: .runtimeIncompatible)
            }

            let startTime = Date()
            effectiveSnapshotId = try await self.effectiveSnapshotId(request.snapshotId)
            let actionResult: UIAutomationActionResult<ElementActionResult> = if let outcomeAutomation =
                automation as? any UIAutomationActionOutcomeProviding
            {
                try await outcomeAutomation.performActionWithOutcome(
                    target: request.target,
                    actionName: request.actionName,
                    snapshotId: effectiveSnapshotId)
            } else {
                try await UIAutomationActionResult(
                    payload: automation.performAction(
                        target: request.target,
                        actionName: request.actionName,
                        snapshotId: effectiveSnapshotId),
                    outcome: nil)
            }
            try DesktopActionFailure.requireConfirmedIfReported(
                actionResult.outcome,
                operation: "Action")
            let invalidatedSnapshotId = await MCPDesktopActionSnapshotInvalidator.invalidate(
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: effectiveSnapshotId,
                outcome: actionResult.outcome)
            return try self.buildResponse(
                result: actionResult.payload,
                requestedAction: request.actionName,
                executionTime: Date().timeIntervalSince(startTime),
                invalidatedSnapshotId: invalidatedSnapshotId,
                outcome: actionResult.outcome)
        } catch let error as ActionToolError {
            return try Self.preDispatchErrorResponse(error)
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: effectiveSnapshotId)
        } catch {
            self.logger.error("action failed: \(error.localizedDescription)")
            return ToolResponse.error("Failed to perform action: \(error.localizedDescription)")
        }
    }

    private func effectiveSnapshotId(_ requestedSnapshotId: String?) async throws -> String {
        if let requestedSnapshotId {
            guard let snapshot = await self.context.uiSnapshots.getSnapshot(id: requestedSnapshotId) else {
                throw ActionToolError(
                    "Snapshot '\(requestedSnapshotId)' not found. Run 'see' or 'inspect_ui' again.",
                    errorCode: "SNAPSHOT_NOT_FOUND",
                    refusalReason: .targetUnavailable)
            }
            return snapshot.id
        }
        guard let snapshot = await self.context.uiSnapshots.getSnapshot(id: nil) else {
            throw ActionToolError(
                "No active UI snapshot is available. Run 'see' or 'inspect_ui' before using action.",
                errorCode: "SNAPSHOT_NOT_FOUND",
                refusalReason: .targetUnavailable)
        }
        return snapshot.id
    }

    private static func preDispatchErrorResponse(_ error: ActionToolError) throws -> ToolResponse {
        MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
            message: error.message,
            reason: error.refusalReason,
            additionalFields: ["error_code": .string(error.errorCode)])
    }

    private func buildResponse(
        result: ElementActionResult,
        requestedAction: String,
        executionTime: TimeInterval,
        invalidatedSnapshotId: String?,
        outcome: DesktopActionOutcome?) throws -> ToolResponse
    {
        let actionName = result.actionName ?? requestedAction
        let message = "\(AgentDisplayTokens.Status.success) Performed \(actionName) on \(result.target) in " +
            "\(String(format: "%.2f", executionTime))s"
        var meta: [String: Value] = [
            "execution_time": .double(executionTime),
            "target": .string(result.target),
            "action_name": .string(actionName),
        ]
        if let anchor = result.anchorPoint {
            meta["anchor"] = .object(["x": .double(anchor.x), "y": .double(anchor.y)])
        }
        if let invalidatedSnapshotId {
            meta["invalidated_snapshot"] = .string(invalidatedSnapshotId)
        }
        return try ToolResponse.text(
            message,
            meta: MCPToolResponseMetadataProjector.metadata(merging: meta, outcome: outcome))
    }
}

private struct ActionRequest {
    let target: String
    let actionName: String
    let snapshotId: String?

    init(arguments: ToolArguments) throws {
        guard let target = arguments.getString("on")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty
        else {
            throw ActionToolError("Element target 'on' is required")
        }
        guard let actionName = arguments.getString("action")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !actionName.isEmpty
        else {
            throw ActionToolError("Action name is required")
        }
        self.target = target
        self.actionName = actionName
        self.snapshotId = arguments.getString("snapshot")
    }
}

private struct ActionToolError: Error {
    let message: String
    let errorCode: String
    let refusalReason: DesktopActionOutcome.RefusalReason

    init(
        _ message: String,
        errorCode: String = "VALIDATION_ERROR",
        refusalReason: DesktopActionOutcome.RefusalReason = .invalidRequest)
    {
        self.message = message
        self.errorCode = errorCode
        self.refusalReason = refusalReason
    }
}
