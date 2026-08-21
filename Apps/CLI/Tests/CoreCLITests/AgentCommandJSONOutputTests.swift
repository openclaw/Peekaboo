import Foundation
import PeekabooAgentRuntime
import Tachikoma
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct AgentCommandJSONOutputTests {
    @Test
    func `No cache JSON keeps legacy calls and emits a payload-safe correlated trace`() throws {
        let png = "iVBORw0KGgo" + String(repeating: "A", count: 2000)
        let privateMessage = "meet me behind the greenhouse at eleven"
        let ordinaryPassword = "violet-elephant-porch"
        let privateURL = "https://private.example.test/invite/ordinary-token"
        let call = AgentToolCall(
            id: "call-1",
            name: "type",
            arguments: [
                "app": AnyAgentToolValue(string: "TextEdit"),
                "foreground": AnyAgentToolValue(bool: false),
                "mode": AnyAgentToolValue(string: "background"),
                "snapshot": AnyAgentToolValue(string: "snapshot-123"),
                "window_id": AnyAgentToolValue(int: 42),
                "text": AnyAgentToolValue(string: privateMessage),
                "value": AnyAgentToolValue(string: ordinaryPassword),
                "url": AnyAgentToolValue(string: privateURL),
                "custom_number": AnyAgentToolValue(int: 731_991),
                "custom_boolean": AnyAgentToolValue(bool: true),
            ]
        )
        let messages = [
            ModelMessage(role: .assistant, content: [
                .toolCall(call),
                .image(.init(data: png)),
            ]),
            ModelMessage(role: .tool, content: [.toolResult(AgentToolResult(
                toolCallId: call.id,
                result: AnyAgentToolValue(object: [
                    "path": AnyAgentToolValue(string: "/Users/example/private/capture.png"),
                    "screenshot": AnyAgentToolValue(string: png),
                    "secret": AnyAgentToolValue(string: "sk-testSECRET123456789"),
                    "success": AnyAgentToolValue(bool: true),
                ])
            ))]),
        ]
        let result = AgentExecutionResult(
            content: "complete",
            messages: messages,
            sessionId: nil,
            metadata: AgentMetadata(
                executionTime: 0.25,
                toolCallCount: 1,
                modelName: "test-model",
                startTime: Date(),
                endTime: Date()
            )
        )
        let command = try AgentCommand.parse(["ephemeral task", "--no-cache"])

        let response = command.makeAgentJSONResponse(result)
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        let text = try #require(String(data: data, encoding: .utf8))
        let resultObject = try #require(response["result"] as? [String: Any])
        let legacyCalls = try #require(resultObject["toolCalls"] as? [[String: Any]])
        let trace = try #require(resultObject["executionTrace"] as? [String: Any])
        let traceData = try JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys])
        let traceText = try #require(String(data: traceData, encoding: .utf8))
        let entries = try #require(trace["entries"] as? [[String: Any]])
        let arguments = try #require(entries[0]["arguments"] as? [String: Any])
        let resultSummary = try #require(entries[0]["result"] as? [String: Any])

        #expect(resultObject["sessionId"] is NSNull)
        #expect(legacyCalls.count == 1)
        let legacyArguments = try #require(legacyCalls[0]["arguments"] as? String)
        let legacyArgumentsData = try #require(legacyArguments.data(using: .utf8))
        let legacyArgumentsObject = try #require(
            JSONSerialization.jsonObject(with: legacyArgumentsData) as? [String: Any]
        )
        #expect(legacyArgumentsObject["app"] as? String == "TextEdit")
        #expect(legacyArgumentsObject["foreground"] as? Bool == false)
        #expect(legacyArgumentsObject["mode"] as? String == "background")
        #expect(legacyArgumentsObject["snapshot"] as? String == "snapshot-123")
        #expect(legacyArgumentsObject["window_id"] as? Int == 42)
        for key in ["text", "value", "url"] {
            #expect((legacyArgumentsObject[key] as? [String: Any])?["redacted"] as? Bool == true)
        }
        #expect(
            (legacyArgumentsObject["__peekaboo_trace_unknown_field_1"] as? [String: Any])?["value_type"]
                as? String == "boolean"
        )
        #expect(
            (legacyArgumentsObject["__peekaboo_trace_unknown_field_2"] as? [String: Any])?["value_type"]
                as? String == "integer"
        )
        #expect(!legacyArguments.contains("Tachikoma"))
        #expect(!legacyArguments.contains("AnyAgentToolValue"))
        #expect(!legacyArguments.contains("unknown context"))
        #expect(!legacyArguments.contains("storage:"))
        #expect(entries.count == 1)
        #expect(entries[0]["id"] as? String == call.id)
        #expect(entries[0]["disposition"] as? String == "executed/succeeded")
        #expect(entries[0]["isError"] as? Bool == false)
        #expect(arguments["app"] as? String == "TextEdit")
        #expect(arguments["foreground"] as? Bool == false)
        #expect(arguments["mode"] as? String == "background")
        #expect(arguments["snapshot"] as? String == "snapshot-123")
        #expect(arguments["window_id"] as? Int == 42)
        for key in ["text", "value", "url"] {
            #expect((arguments[key] as? [String: Any])?["redacted"] as? Bool == true)
        }
        #expect(
            (arguments["__peekaboo_trace_unknown_field_1"] as? [String: Any])?["value_type"] as? String ==
                "boolean"
        )
        #expect(
            (arguments["__peekaboo_trace_unknown_field_2"] as? [String: Any])?["value_type"] as? String ==
                "integer"
        )
        #expect(resultSummary["success"] as? Bool == true)
        #expect(entries[0]["mutationDispatch"] as? String == "possibly_dispatched")
        #expect(resultSummary["mutation_dispatched"] == nil)
        #expect(resultSummary["mutation_dispatch"] as? String == "possibly_dispatched")
        #expect(resultSummary["retry_safe"] as? Bool == false)
        #expect(resultSummary["payload_omitted"] as? Bool == true)
        #expect(trace["totalCallCount"] as? Int == 1)
        #expect(trace["truncated"] as? Bool == false)
        #expect(!text.contains("iVBORw0KGgo"))
        #expect(!text.contains("/Users/example/private/capture.png"))
        #expect(!text.contains("sk-testSECRET123456789"))
        #expect(!text.contains(privateMessage))
        #expect(!text.contains(ordinaryPassword))
        #expect(!text.contains(privateURL))
        #expect(!text.contains("731991"))
        #expect(!text.contains("custom_boolean"))
        #expect(!text.contains("custom_number"))
        #expect(!text.contains("AnyAgentToolValue"))
        #expect(!text.contains("unknown context"))
        #expect(!traceText.contains(privateMessage))
        #expect(!traceText.contains(ordinaryPassword))
        #expect(!traceText.contains(privateURL))
        #expect(!traceText.contains("731991"))
    }

    @Test
    func `Legacy calls beyond the bounded trace stay valid and fully redacted`() throws {
        let calls = (0...512).map { index in
            AgentToolCall(
                id: "call-\(index)",
                name: "inspect_ui",
                arguments: [
                    "app_target": AnyAgentToolValue(string: "PID:42"),
                    "window_id": AnyAgentToolValue(int: 99),
                ]
            )
        }
        let result = AgentExecutionResult(
            content: "complete",
            messages: [ModelMessage(role: .assistant, content: calls.map { .toolCall($0) })],
            metadata: AgentMetadata(
                executionTime: 0.1,
                toolCallCount: calls.count,
                modelName: "test-model",
                startTime: Date(),
                endTime: Date()
            )
        )
        let command = try AgentCommand.parse(["ephemeral task", "--no-cache"])

        let response = command.makeAgentJSONResponse(result)
        let resultObject = try #require(response["result"] as? [String: Any])
        let legacyCalls = try #require(resultObject["toolCalls"] as? [[String: Any]])
        let firstArguments = try #require(legacyCalls.first?["arguments"] as? String)
        let lastArguments = try #require(legacyCalls.last?["arguments"] as? String)

        #expect(legacyCalls.count == 513)
        #expect(firstArguments == #"{"app_target":"PID:42","window_id":99}"#)
        #expect(lastArguments == #"{"redacted":true}"#)
    }

    @Test
    func `Legacy argument JSON is stable across dictionary insertion order`() throws {
        var forward: [String: AnyAgentToolValue] = [:]
        forward["app_target"] = AnyAgentToolValue(string: "PID:42")
        forward["foreground"] = AnyAgentToolValue(bool: false)
        forward["window_id"] = AnyAgentToolValue(int: 99)
        var reverse: [String: AnyAgentToolValue] = [:]
        reverse["window_id"] = AnyAgentToolValue(int: 99)
        reverse["foreground"] = AnyAgentToolValue(bool: false)
        reverse["app_target"] = AnyAgentToolValue(string: "PID:42")
        let calls = [
            AgentToolCall(id: "forward", name: "inspect_ui", arguments: forward),
            AgentToolCall(id: "reverse", name: "inspect_ui", arguments: reverse),
        ]
        let result = AgentExecutionResult(
            content: "complete",
            messages: [ModelMessage(role: .assistant, content: calls.map { .toolCall($0) })],
            metadata: AgentMetadata(
                executionTime: 0.1,
                toolCallCount: calls.count,
                modelName: "test-model",
                startTime: Date(),
                endTime: Date()
            )
        )
        let command = try AgentCommand.parse(["ephemeral task", "--no-cache"])

        let response = command.makeAgentJSONResponse(result)
        let resultObject = try #require(response["result"] as? [String: Any])
        let legacyCalls = try #require(resultObject["toolCalls"] as? [[String: Any]])
        let firstArguments = try #require(legacyCalls.first?["arguments"] as? String)
        let lastArguments = try #require(legacyCalls.last?["arguments"] as? String)

        #expect(firstArguments == lastArguments)
        #expect(firstArguments == #"{"app_target":"PID:42","foreground":false,"window_id":99}"#)
    }
}
