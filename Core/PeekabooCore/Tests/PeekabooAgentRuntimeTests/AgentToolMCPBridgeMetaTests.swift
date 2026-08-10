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
    func `Error response becomes a structured failure and ignores arbitrary metadata`() throws {
        let response = ToolResponse.error(
            "native tool failed",
            meta: .object([
                "summary": .object([
                    "command": .string("false"),
                ]),
            ]))
        let converted = convertToolResponseToAgentToolResult(response)
        let payload = try #require(try converted.toJSON() as? [String: Any])

        #expect(payload["success"] as? Bool == false)
        #expect(payload["error"] as? String == "native tool failed")
        #expect(payload["meta"] == nil)
        #expect(ToolEventSummary.from(resultJSON: payload) == nil)
    }

    @Test
    func `Capture error keeps only safe bounded metadata for the agent`() throws {
        let response = ToolResponse.error(
            "no frames",
            meta: .object([
                "decode_failures": .int(2),
                "effect": .string("partial"),
                "error_code": .string("CAPTURE_NO_VALID_FRAMES"),
                "first_decode_error": .string("first"),
                "internal_diagnostics": .string("private"),
                "mutation_dispatched": .bool(true),
                "retry_safe": .bool(false),
                "source": .string("video"),
            ]))

        let converted = convertToolResponseToAgentToolResult(response)
        let payload = try #require(try converted.toJSON() as? [String: Any])

        #expect(payload["error_code"] as? String == "CAPTURE_NO_VALID_FRAMES")
        #expect(payload["effect"] as? String == "partial")
        #expect(payload["decode_failures"] as? Int == 2)
        #expect(payload["mutation_dispatched"] as? Bool == true)
        #expect(payload["retry_safe"] as? Bool == false)
        #expect(payload["internal_diagnostics"] == nil)
    }

    @Test
    func `Successful focus-capable capture promotes dispatch receipt for the agent`() throws {
        let response = ToolResponse.text(
            "captured",
            meta: .object([
                "mutation_dispatched": .bool(true),
                "retry_safe": .bool(false),
                "stats": .object(["frames_kept": .int(2)]),
            ]))

        let converted = convertToolResponseToAgentToolResult(response)
        let payload = try #require(try converted.toJSON() as? [String: Any])

        #expect(payload["mutation_dispatched"] as? Bool == true)
        #expect(payload["retry_safe"] as? Bool == false)
        #expect(payload["stats"] == nil)
        #expect((payload["meta"] as? [String: Any])?["stats"] != nil)
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

    @Test
    func `Multiple text content items preserve metadata and omit text wrapper`() throws {
        let response = ToolResponse(
            content: [
                .text(text: "analysis", annotations: nil, _meta: nil),
                .text(text: "completed in 1.00s", annotations: nil, _meta: nil),
            ],
            meta: .object([
                "summary": .object([
                    "command": .string("analyze image"),
                ]),
            ]))

        let converted = convertToolResponseToAgentToolResult(response)
        guard let payload = try converted.toJSON() as? [String: Any] else {
            Issue.record("Converted response is not an object")
            return
        }

        #expect(payload["result"] as? [String] == ["analysis", "completed in 1.00s"])
        #expect(!payload.keys.contains("text"))
        guard let summary = ToolEventSummary.from(resultJSON: payload) else {
            Issue.record("Converted response is missing summary metadata")
            return
        }
        #expect(summary.shortDescription(toolName: "analyze") != nil)
    }

    @Test
    func `Text and invalid image content preserve text and an explicit omission`() throws {
        let imageData = "AQID"
        let response = ToolResponse(content: [
            .text(text: "annotated screenshot", annotations: nil, _meta: nil),
            .image(data: imageData, mimeType: "image/png", annotations: nil, _meta: nil),
        ])

        let converted = convertToolResponseToAgentToolResult(response)
        guard let content = try converted.toJSON() as? [Any] else {
            Issue.record("Converted response is not an array")
            return
        }

        #expect(content.count == 2)
        #expect(content[0] as? String == "annotated screenshot")
        let omitted = try #require(content[1] as? [String: Any])
        #expect(omitted["type"] as? String == "image")
        #expect(omitted["attached"] as? Bool == false)
        #expect(omitted["reason"] as? String == "invalid or oversized inline data")
    }
}
