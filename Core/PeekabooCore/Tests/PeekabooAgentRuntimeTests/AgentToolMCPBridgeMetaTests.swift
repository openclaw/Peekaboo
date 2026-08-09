import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct AgentToolMCPBridgeMetaTests {
    @Test
    func `Text content preserves summary metadata`() throws {
        let text = "native tool output"
        let response = ToolResponse.text(
            text,
            meta: .object([
                "summary": .object([
                    "command": .string("echo hi"),
                ]),
            ]))

        let converted = convertToolResponseToAgentToolResult(response)
        guard let payload = try converted.toJSON() as? [String: Any] else {
            Issue.record("Converted response is not an object")
            return
        }

        #expect(payload["result"] as? String == text)
        #expect(payload["text"] as? String == text)
        guard let summary = ToolEventSummary.from(resultJSON: payload) else {
            Issue.record("Converted response is missing summary metadata")
            return
        }
        #expect(summary.shortDescription(toolName: "shell") != nil)
    }

    @Test
    func `Text content without metadata keeps legacy string result`() throws {
        let text = "legacy native tool output"
        let converted = convertToolResponseToAgentToolResult(.text(text))

        #expect(try converted.toJSON() as? String == text)
    }

    @Test
    func `Error response ignores metadata`() throws {
        let response = ToolResponse.error(
            "native tool failed",
            meta: .object([
                "summary": .object([
                    "command": .string("false"),
                ]),
            ]))
        let converted = convertToolResponseToAgentToolResult(response)

        #expect(try converted.toJSON() as? String == "Error: native tool failed")
    }

    @Test
    func `Shell tool metadata survives native bridge`() async throws {
        let command = "echo bridge-meta-test"
        let tool = ShellTool()
        let response = try await tool.execute(arguments: ToolArguments(raw: ["command": command]))
        let converted = convertToolResponseToAgentToolResult(response)

        guard let payload = try converted.toJSON() as? [String: Any] else {
            Issue.record("Converted ShellTool response is not an object")
            return
        }
        guard let summary = ToolEventSummary.from(resultJSON: payload) else {
            Issue.record("Converted ShellTool response is missing summary metadata")
            return
        }

        #expect(summary.command == command)
        #expect(summary.shortDescription(toolName: tool.name)?.hasPrefix("Run `\(command)`") == true)
    }
}
