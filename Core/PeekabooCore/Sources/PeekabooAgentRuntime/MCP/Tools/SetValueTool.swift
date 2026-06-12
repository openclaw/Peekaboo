import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooAutomationKit
import TachikomaMCP

public struct SetValueTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "SetValueTool")
    private let context: MCPToolContext

    public let name = "set_value"

    public var description: String {
        """
        Sets an accessibility element value directly without synthesizing keystrokes.
        Use for forms and controls after `see` or `inspect_ui` returns an element ID. Requires a settable AX value.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.5, anthropic/claude-opus-4-8
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "on": SchemaBuilder.string(
                    description: "Element ID from `see` or `inspect_ui` output, such as T1, or a query string."),
                "value": SchemaBuilder.anyOf(
                    [
                        SchemaBuilder.string(),
                        SchemaBuilder.boolean(),
                        SchemaBuilder.integer(),
                        SchemaBuilder.number(),
                    ],
                    description: "Value to set. Supported types: string, boolean, integer, or number."),
                "snapshot": SchemaBuilder.string(
                    description: "Optional. Snapshot ID from `see` or `inspect_ui`. " +
                        "Uses latest snapshot if not specified."),
            ],
            required: ["on", "value"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        do {
            let request = try SetValueRequest(arguments: arguments)
            guard let automation = self.context.automation as? any ElementActionAutomationServiceProtocol else {
                return ToolResponse.error("set_value is not supported by this automation host")
            }

            let startTime = Date()
            let effectiveSnapshotId = try await self.effectiveSnapshotId(request.snapshotId)
            let result = try await automation.setValue(
                target: request.target,
                value: request.value,
                snapshotId: effectiveSnapshotId)
            let invalidatedSnapshotId = await UISnapshotManager.shared.invalidateActiveSnapshot(id: effectiveSnapshotId)
            let elapsed = Date().timeIntervalSince(startTime)
            return self.buildResponse(
                result: result,
                value: request.value,
                executionTime: elapsed,
                invalidatedSnapshotId: invalidatedSnapshotId)
        } catch let error as SetValueToolError {
            return ToolResponse.error(error.message)
        } catch {
            self.logger.error("set_value failed: \(error.localizedDescription)")
            return ToolResponse.error("Failed to set value: \(error.localizedDescription)")
        }
    }

    private func effectiveSnapshotId(_ requestedSnapshotId: String?) async throws -> String? {
        if let requestedSnapshotId {
            guard let snapshot = await UISnapshotManager.shared.getSnapshot(id: requestedSnapshotId) else {
                throw SetValueToolError("Snapshot '\(requestedSnapshotId)' not found. Run 'see' or 'inspect_ui' again.")
            }
            return snapshot.id
        }

        return await UISnapshotManager.shared.getSnapshot(id: nil)?.id
    }

    private func buildResponse(
        result: ElementActionResult,
        value: UIElementValue,
        executionTime: TimeInterval,
        invalidatedSnapshotId: String?) -> ToolResponse
    {
        let message = "\(AgentDisplayTokens.Status.success) Set value on \(result.target) in " +
            "\(String(format: "%.2f", executionTime))s"

        var meta: [String: Value] = [
            "execution_time": .double(executionTime),
            "target": .string(result.target),
            "value": Self.valueToMCP(value),
        ]

        if let oldValue = result.oldValue {
            meta["old_value"] = .string(oldValue)
        }
        if let newValue = result.newValue {
            meta["new_value"] = .string(newValue)
        }
        if let actionName = result.actionName {
            meta["action_name"] = .string(actionName)
        }
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

    private static func valueToMCP(_ value: UIElementValue) -> Value {
        switch value {
        case let .bool(raw):
            .bool(raw)
        case let .int(raw):
            .int(raw)
        case let .double(raw):
            .double(raw)
        case let .string(raw):
            .string(raw)
        }
    }
}

private struct SetValueRequest {
    let target: String
    let value: UIElementValue
    let snapshotId: String?

    init(arguments: ToolArguments) throws {
        guard let target = arguments.getString("on")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty
        else {
            throw SetValueToolError("Element target 'on' is required")
        }
        guard let rawValue = arguments.getValue(for: "value") else {
            throw SetValueToolError("Value is required")
        }

        self.target = target
        self.value = try Self.parseValue(rawValue)
        self.snapshotId = arguments.getString("snapshot")
    }

    private static func parseValue(_ value: Value) throws -> UIElementValue {
        switch value {
        case let .string(raw):
            .string(raw)
        case let .bool(raw):
            .bool(raw)
        case let .int(raw):
            .int(raw)
        case let .double(raw):
            .double(raw)
        case .null, .array, .object, .data:
            throw SetValueToolError("Value must be a string, boolean, integer, or number")
        }
    }
}

private struct SetValueToolError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}
