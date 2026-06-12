import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooAutomationKit
import TachikomaMCP

public struct PerformActionTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "PerformActionTool")
    private let context: MCPToolContext

    public let name = "perform_action"

    public var description: String {
        """
        Invokes a named accessibility action on an element, such as AXPress or AXShowMenu.
        Use with element IDs from `see` or `inspect_ui` when a semantic action is available.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.5, anthropic/claude-opus-4-8
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "on": SchemaBuilder.string(
                    description: "Element ID from `see` or `inspect_ui` output, such as B1, or a query string."),
                "action": SchemaBuilder.string(
                    description: "Accessibility action name to invoke, e.g. AXPress, AXShowMenu, AXIncrement."),
                "snapshot": SchemaBuilder.string(
                    description: "Optional. Snapshot ID from `see` or `inspect_ui`. " +
                        "Uses latest snapshot if not specified."),
            ],
            required: ["on", "action"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        do {
            let request = try PerformActionRequest(arguments: arguments)
            guard let automation = self.context.automation as? any ElementActionAutomationServiceProtocol else {
                return ToolResponse.error("perform_action is not supported by this automation host")
            }

            let startTime = Date()
            let effectiveSnapshotId = try await self.effectiveSnapshotId(request.snapshotId)
            let result = try await automation.performAction(
                target: request.target,
                actionName: request.actionName,
                snapshotId: effectiveSnapshotId)
            let invalidatedSnapshotId = await UISnapshotManager.shared.invalidateActiveSnapshot(id: effectiveSnapshotId)
            let elapsed = Date().timeIntervalSince(startTime)
            return self.buildResponse(
                result: result,
                requestedAction: request.actionName,
                executionTime: elapsed,
                invalidatedSnapshotId: invalidatedSnapshotId)
        } catch let error as PerformActionToolError {
            return ToolResponse.error(error.message)
        } catch {
            self.logger.error("perform_action failed: \(error.localizedDescription)")
            return ToolResponse.error("Failed to perform action: \(error.localizedDescription)")
        }
    }

    private func effectiveSnapshotId(_ requestedSnapshotId: String?) async throws -> String? {
        if let requestedSnapshotId {
            guard let snapshot = await UISnapshotManager.shared.getSnapshot(id: requestedSnapshotId) else {
                throw PerformActionToolError(
                    "Snapshot '\(requestedSnapshotId)' not found. Run 'see' or 'inspect_ui' again.")
            }
            return snapshot.id
        }

        return await UISnapshotManager.shared.getSnapshot(id: nil)?.id
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
            meta["anchor"] = .object([
                "x": .double(Double(anchor.x)),
                "y": .double(Double(anchor.y)),
            ])
        }
        if let invalidatedSnapshotId {
            meta["invalidated_snapshot"] = .string(invalidatedSnapshotId)
            meta["requires_fresh_observation"] = .bool(true)
        }

        return ToolResponse.text(message, meta: .object(meta))
    }
}

private struct PerformActionRequest {
    let target: String
    let actionName: String
    let snapshotId: String?

    init(arguments: ToolArguments) throws {
        guard let target = arguments.getString("on")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty
        else {
            throw PerformActionToolError("Element target 'on' is required")
        }
        guard let actionName = arguments.getString("action")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !actionName.isEmpty
        else {
            throw PerformActionToolError("Action name is required")
        }

        self.target = target
        self.actionName = actionName
        self.snapshotId = arguments.getString("snapshot")
    }
}

private struct PerformActionToolError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}
