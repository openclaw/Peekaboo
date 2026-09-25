import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct SnapshotInvalidationMetadataTests {
    @Test(arguments: [false, true])
    func `Cleanup metadata survives Agent conversion without changing tool failure`(toolExecuted: Bool) throws {
        let invalidation = Self.invalidation(toolExecuted: toolExecuted)
        let metadata = Value.object([
            "snapshot_invalidation": invalidation,
            "internal_diagnostics": .string("private diagnostic"),
        ])
        let response = toolExecuted
            ? ToolResponse.text("Mutation completed; do not repeat it.", meta: metadata)
            : ToolResponse.error("Observation was not executed; retry this request later.", meta: metadata)
        let converted = convertToolResponseToAgentToolResult(response)
        let payload = try #require(try converted.toJSON() as? [String: Any])
        let cleanup = try #require(payload["snapshot_invalidation"] as? [String: Any])

        #expect(cleanup["status"] as? String == "pending_retry")
        #expect(cleanup["tool_executed"] as? Bool == toolExecuted)
        #expect(cleanup["retry_tool"] as? Bool == !toolExecuted)
        #expect(payload["internal_diagnostics"] == nil)
        if toolExecuted {
            #expect(payload["error"] == nil)
        } else {
            #expect(payload["success"] as? Bool == false)
            #expect(payload["error"] as? String == "Observation was not executed; retry this request later.")
        }
    }

    @Test
    func `External MCP metadata preserves the same cleanup receipt`() {
        let invalidation = Self.invalidation(toolExecuted: false)
        let fields = MCPToolResponseMetadataProjector.externalFields(
            from: .object([
                "snapshot_invalidation": invalidation,
                "internal_diagnostics": .string("private diagnostic"),
            ]),
            toolName: "inspect_ui")

        #expect(fields == ["snapshot_invalidation": invalidation])
    }

    @Test
    func `Provider metadata cannot assert Peekaboo snapshot cleanup state`() {
        let fields = MCPToolResponseMetadataProjector.providerFields(from: .object([
            "snapshot_invalidation": Self.invalidation(toolExecuted: false),
            "provider_note": .string("kept"),
        ]))

        #expect(fields == ["provider_meta": .object(["provider_note": .string("kept")])])
    }

    private static func invalidation(toolExecuted: Bool) -> Value {
        .object([
            "status": .string("pending_retry"),
            "tool_executed": .bool(toolExecuted),
            "retry_tool": .bool(!toolExecuted),
        ])
    }
}
