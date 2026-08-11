import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooAutomationKit
import TachikomaMCP

public struct ActionTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "ActionTool")
    private let context: MCPToolContext

    public let name = "action"

    public var description: String {
        """
        Invokes a named accessibility action on an element, such as AXPress or AXShowMenu.
        Use with element IDs from `see` or `inspect_ui` when a semantic action is available.
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
        do {
            let request = try ActionRequest(arguments: arguments)
            guard let automation = self.context.automation as? any ElementActionAutomationServiceProtocol else {
                return ToolResponse.error("action is not supported by this automation host")
            }

            let startTime = Date()
            let effectiveSnapshotId = try await self.effectiveSnapshotId(request.snapshotId)
            let result = try await automation.performAction(
                target: request.target,
                actionName: request.actionName,
                snapshotId: effectiveSnapshotId)
            let invalidatedSnapshotId = await UISnapshotManager.shared.invalidateActiveSnapshot(id: effectiveSnapshotId)
            return self.buildResponse(
                result: result,
                requestedAction: request.actionName,
                executionTime: Date().timeIntervalSince(startTime),
                invalidatedSnapshotId: invalidatedSnapshotId)
        } catch let error as ActionToolError {
            return Self.preDispatchErrorResponse(error)
        } catch {
            self.logger.error("action failed: \(error.localizedDescription)")
            return ToolResponse.error("Failed to perform action: \(error.localizedDescription)")
        }
    }

    private func effectiveSnapshotId(_ requestedSnapshotId: String?) async throws -> String {
        if let requestedSnapshotId {
            guard let snapshot = await UISnapshotManager.shared.getSnapshot(id: requestedSnapshotId) else {
                throw ActionToolError(
                    "Snapshot '\(requestedSnapshotId)' not found. Run 'see' or 'inspect_ui' again.",
                    errorCode: "SNAPSHOT_NOT_FOUND")
            }
            return snapshot.id
        }
        guard let snapshot = await UISnapshotManager.shared.getSnapshot(id: nil) else {
            throw ActionToolError(
                "No active UI snapshot is available. Run 'see' or 'inspect_ui' before using action.",
                errorCode: "SNAPSHOT_NOT_FOUND")
        }
        return snapshot.id
    }

    private static func preDispatchErrorResponse(_ error: ActionToolError) -> ToolResponse {
        ToolResponse.error(
            error.message,
            meta: .object([
                "effect": .string("refused"),
                "error_code": .string(error.errorCode),
                "mutation_dispatched": .bool(false),
                "retry_safe": .bool(true),
            ]))
    }

    private func buildResponse(
        result: ElementActionResult,
        requestedAction: String,
        executionTime: TimeInterval,
        invalidatedSnapshotId: String?) -> ToolResponse
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
            meta["requires_fresh_observation"] = .bool(true)
        }
        return ToolResponse.text(message, meta: .object(meta))
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

    init(_ message: String, errorCode: String = "VALIDATION_ERROR") {
        self.message = message
        self.errorCode = errorCode
    }
}
