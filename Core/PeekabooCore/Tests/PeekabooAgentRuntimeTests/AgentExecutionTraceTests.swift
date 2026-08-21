import Foundation
import MCP
import PeekabooCore
import Tachikoma
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct AgentExecutionTraceTests {
    @Test
    func `Trace distinguishes dispatched mutations from boundary skips until fresh see`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let recorder = AgentExecutionTraceRecorder()
        let tools = ["see", "click", "type", "set_value"].map { name in
            AgentTool(
                name: name,
                description: name,
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in
                    await recorder.record(name)
                    return try AnyAgentToolValue.fromJSON(["success": true, "error": NSNull()])
                })
        }
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "trace-test",
            executionPolicy: .unrestricted)
        var messages: [ModelMessage] = []

        _ = try await service.handleToolCalls(
            stepText: "",
            toolCalls: [
                AgentToolCall(id: "see-1", name: "see", arguments: [:]),
                AgentToolCall(
                    id: "click-1",
                    name: "click",
                    arguments: ["window_id": AnyAgentToolValue(int: 42)]),
                AgentToolCall(id: "type-1", name: "type", arguments: [:]),
                AgentToolCall(id: "set-1", name: "set_value", arguments: [:]),
            ],
            context: context,
            currentMessages: &messages,
            stepIndex: 0)
        _ = try await service.handleToolCalls(
            stepText: "",
            toolCalls: [
                AgentToolCall(id: "type-replay", name: "type", arguments: [:]),
                AgentToolCall(id: "see-2", name: "see", arguments: [:]),
                AgentToolCall(id: "type-2", name: "type", arguments: [:]),
            ],
            context: context,
            currentMessages: &messages,
            stepIndex: 1)

        let result = AgentExecutionResult(
            content: "done",
            messages: messages,
            metadata: AgentMetadata(
                executionTime: 0,
                toolCallCount: 7,
                modelName: "test",
                startTime: Date(),
                endTime: Date()))
        let trace = result.executionTrace()

        #expect(await recorder.snapshot() == ["see", "click", "see", "type"])
        #expect(trace.entries.map(\.id) == [
            "see-1", "click-1", "type-1", "set-1", "type-replay", "see-2", "type-2",
        ])
        #expect(trace.entries.map(\.disposition) == [
            .executedSucceeded,
            .executedSucceeded,
            .skippedBeforeDispatch,
            .skippedBeforeDispatch,
            .skippedBeforeDispatch,
            .executedSucceeded,
            .executedSucceeded,
        ])
        #expect(trace.entries.map(\.isError) == [false, false, true, true, true, false, false])
        #expect(trace.entries[1].arguments["window_id"]?.intValue == 42)
        #expect(trace.entries[1].mutationDispatch == .possiblyDispatched)
        #expect(trace.entries[1].result?.objectValue?["mutation_dispatched"] == nil)
        #expect(trace.entries[1].result?.objectValue?["mutation_dispatch"]?.stringValue == "possibly_dispatched")
        #expect(trace.entries[1].result?.objectValue?["retry_safe"]?.boolValue == false)
        #expect(trace.entries[2].result?.objectValue?["skipped"]?.boolValue == true)
        #expect(trace.entries[2].result?.objectValue?["mutation_dispatched"]?.boolValue == false)
        #expect(trace.entries[2].mutationDispatch == .notDispatched)
        #expect(trace.entries[4].result?.objectValue?["perception_required"]?.boolValue == true)
        #expect(trace.entries[4].result?.objectValue?["mutation_dispatched"]?.boolValue == false)
        #expect(trace.entries[6].mutationDispatch == .possiblyDispatched)
        #expect(trace.entries[6].result?.objectValue?["mutation_dispatched"] == nil)
        #expect(trace.entries[6].result?.objectValue?["retry_safe"]?.boolValue == false)
        #expect(!trace.truncated)
        #expect(trace.totalCallCount == 7)
    }

    @Test
    func `Explicit false mutation dispatch survives failed result summarization`() throws {
        let call = AgentToolCall(id: "rejected-click", name: "click", arguments: [:])
        let messages = [
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(role: .tool, content: [.toolResult(AgentToolResult(
                toolCallId: call.id,
                result: AnyAgentToolValue(object: [
                    "error": AnyAgentToolValue(string: "Target validation failed"),
                    "mutation_dispatched": AnyAgentToolValue(bool: false),
                    "retry_safe": AnyAgentToolValue(bool: true),
                    "success": AnyAgentToolValue(bool: false),
                ]),
                isError: true))]),
        ]
        let result = AgentExecutionResult(
            content: "",
            messages: messages,
            metadata: AgentMetadata(
                executionTime: 0,
                toolCallCount: 1,
                modelName: "test",
                startTime: Date(),
                endTime: Date()))

        let entry = try #require(result.executionTrace().entries.first)
        let summary = try #require(entry.result?.objectValue)

        #expect(entry.disposition == .executedFailed)
        #expect(entry.isError == true)
        #expect(summary["mutation_dispatched"]?.boolValue == false)
        #expect(entry.mutationDispatch == .notDispatched)
        #expect(summary["mutation_dispatch"]?.stringValue == "not_dispatched")
        #expect(summary["retry_safe"]?.boolValue == true)
        #expect(summary["error_present"]?.boolValue == true)
    }

    @Test
    func `Capture and image traces classify only focus-capable requests as mutations`() {
        let calls = [
            AgentToolCall(
                id: "capture-background",
                name: "capture",
                arguments: ["capture_focus": AnyAgentToolValue(string: "background")]),
            AgentToolCall(
                id: "capture-foreground",
                name: "capture",
                arguments: ["capture_focus": AnyAgentToolValue(string: "foreground")]),
            AgentToolCall(
                id: "image-auto",
                name: "image",
                arguments: ["capture_focus": AnyAgentToolValue(string: "auto")]),
        ]
        let messages = [
            ModelMessage(role: .assistant, content: calls.map(ModelMessage.ContentPart.toolCall)),
            ModelMessage(role: .tool, content: calls.map { call in
                .toolResult(AgentToolResult(
                    toolCallId: call.id,
                    result: AnyAgentToolValue(object: [
                        "mutation_dispatched": AnyAgentToolValue(bool: call.id != "capture-background"),
                        "success": AnyAgentToolValue(bool: true),
                    ]),
                    isError: false))
            }),
        ]
        let result = AgentExecutionResult(
            content: "",
            messages: messages,
            metadata: AgentMetadata(
                executionTime: 0,
                toolCallCount: calls.count,
                modelName: "test",
                startTime: Date(),
                endTime: Date()))

        let trace = result.executionTrace()
        #expect(trace.entries[0].mutationDispatch == nil)
        #expect(trace.entries[1].mutationDispatch == .dispatched)
        #expect(trace.entries[2].mutationDispatch == .dispatched)
    }

    @Test
    func `Native capture success receipt reaches execution trace through the real agent bridge`() throws {
        let call = AgentToolCall(
            id: "capture-focused",
            name: "capture",
            arguments: ["capture_focus": AnyAgentToolValue(string: "foreground")])
        let bridged = convertToolResponseToAgentToolResult(ToolResponse.text(
            "captured",
            meta: .object([
                "mutation_dispatched": .bool(true),
                "retry_safe": .bool(false),
            ])))
        let messages = [
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(role: .tool, content: [.toolResult(AgentToolResult(
                toolCallId: call.id,
                result: bridged,
                isError: false))]),
        ]
        let result = AgentExecutionResult(
            content: "",
            messages: messages,
            metadata: AgentMetadata(
                executionTime: 0,
                toolCallCount: 1,
                modelName: "test",
                startTime: Date(),
                endTime: Date()))

        let entry = try #require(result.executionTrace().entries.first)
        #expect(entry.mutationDispatch == .dispatched)
        #expect(entry.result?.objectValue?["mutation_dispatched"]?.boolValue == true)
        #expect(entry.result?.objectValue?["retry_safe"]?.boolValue == false)
    }

    @Test
    func `Trace allowlists audit fields and omits all content-bearing values`() throws {
        let png = "iVBORw0KGgo" + String(repeating: "A", count: 2000)
        let secret = "sk-testSECRET123456789"
        let localPath = "/Users/example/private/capture.png"
        let privateMessage = "meet me behind the greenhouse at eleven"
        let ordinaryPassword = "violet-elephant-porch"
        let privateURL = "https://private.example.test/invite/ordinary-token"
        let completedCall = AgentToolCall(
            id: "safe-call",
            name: "see",
            arguments: [
                "app": AnyAgentToolValue(string: "TextEdit"),
                "app_target": AnyAgentToolValue(string: "com.apple.TextEdit"),
                "foreground": AnyAgentToolValue(bool: false),
                "mode": AnyAgentToolValue(string: "background"),
                "snapshot": AnyAgentToolValue(string: "snapshot-123"),
                "window_id": AnyAgentToolValue(int: 42),
                "api_key": AnyAgentToolValue(string: secret),
                "path": AnyAgentToolValue(string: localPath),
                "image": AnyAgentToolValue(string: png),
                "text": AnyAgentToolValue(string: privateMessage),
                "value": AnyAgentToolValue(string: ordinaryPassword),
                "url": AnyAgentToolValue(string: privateURL),
                "query": AnyAgentToolValue(string: "ordinary private search terms"),
                "custom_string": AnyAgentToolValue(string: "ordinary unclassified private value"),
                "custom_number": AnyAgentToolValue(int: 731_991),
                "custom_boolean": AnyAgentToolValue(bool: true),
                "custom_array": AnyAgentToolValue(array: [
                    AnyAgentToolValue(string: privateMessage),
                    AnyAgentToolValue(string: ordinaryPassword),
                ]),
                "predicates": AnyAgentToolValue(array: [AnyAgentToolValue(object: [
                    "expected": AnyAgentToolValue(bool: true),
                    "expected_value": AnyAgentToolValue(string: privateMessage),
                    "kind": AnyAgentToolValue(string: "element_value"),
                    "selector": AnyAgentToolValue(object: [
                        "identifier": AnyAgentToolValue(string: "First Text View"),
                        "label": AnyAgentToolValue(string: "Private diary entry"),
                        "role": AnyAgentToolValue(string: "AXTextArea"),
                    ]),
                ])]),
            ])
        let missingCall = AgentToolCall(id: "missing-call", name: "click", arguments: [:])
        let messages = [
            ModelMessage(role: .assistant, content: [
                .toolCall(completedCall),
                .image(.init(data: png)),
                .toolCall(missingCall),
            ]),
            ModelMessage(role: .tool, content: [.toolResult(AgentToolResult(
                toolCallId: completedCall.id,
                result: AnyAgentToolValue(object: [
                    "image": AnyAgentToolValue(string: png),
                    "path": AnyAgentToolValue(string: localPath),
                    "secret": AnyAgentToolValue(string: secret),
                    "success": AnyAgentToolValue(bool: true),
                ]),
                isError: false))]),
        ]
        let result = AgentExecutionResult(
            content: "complete",
            messages: messages,
            metadata: AgentMetadata(
                executionTime: 0,
                toolCallCount: 1,
                modelName: "test",
                startTime: Date(),
                endTime: Date()))

        let trace = result.executionTrace(maxEntries: 1)
        let data = try JSONEncoder().encode(trace)
        let text = try #require(String(data: data, encoding: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(object["entries"] as? [[String: Any]])
        let arguments = try #require(entries[0]["arguments"] as? [String: Any])
        let resultSummary = try #require(entries[0]["result"] as? [String: Any])
        let predicates = try #require(arguments["predicates"] as? [[String: Any]])
        let selector = try #require(predicates[0]["selector"] as? [String: Any])

        #expect(trace.entries.count == 1)
        #expect(trace.totalCallCount == 2)
        #expect(trace.truncated)
        #expect(arguments["app"] as? String == "TextEdit")
        #expect(arguments["app_target"] as? String == "com.apple.TextEdit")
        #expect(arguments["foreground"] as? Bool == false)
        #expect(arguments["mode"] as? String == "background")
        #expect(arguments["snapshot"] as? String == "snapshot-123")
        #expect(arguments["window_id"] as? Int == 42)
        for key in ["api_key", "path", "image", "text", "value", "url", "query"] {
            #expect((arguments[key] as? [String: Any])?["redacted"] as? Bool == true)
        }
        let unknownFields = (1...4).map { arguments["__peekaboo_trace_unknown_field_\($0)"] }
        #expect((unknownFields[0] as? [String: Any])?["item_count"] as? Int == 2)
        #expect((unknownFields[1] as? [String: Any])?["value_type"] as? String == "boolean")
        #expect((unknownFields[2] as? [String: Any])?["value_type"] as? String == "integer")
        #expect((unknownFields[3] as? [String: Any])?["value_type"] as? String == "string")
        #expect(predicates[0]["kind"] as? String == "element_value")
        #expect(predicates[0]["expected"] as? Bool == true)
        #expect((predicates[0]["expected_value"] as? [String: Any])?["redacted"] as? Bool == true)
        #expect(selector["identifier"] as? String == "First Text View")
        #expect(selector["role"] as? String == "AXTextArea")
        #expect((selector["label"] as? [String: Any])?["redacted"] as? Bool == true)
        #expect(resultSummary["success"] as? Bool == true)
        #expect(resultSummary["payload_omitted"] as? Bool == true)
        #expect(!text.contains(png))
        #expect(!text.contains(secret))
        #expect(!text.contains(localPath))
        #expect(!text.contains(privateMessage))
        #expect(!text.contains(ordinaryPassword))
        #expect(!text.contains(privateURL))
        #expect(!text.contains("ordinary private search terms"))
        #expect(!text.contains("ordinary unclassified private value"))
        #expect(!text.contains("731991"))
        #expect(!text.contains("Private diary entry"))
        for key in ["custom_array", "custom_boolean", "custom_number", "custom_string"] {
            #expect(!text.contains(key))
        }

        let fullTraceData = try JSONEncoder().encode(result.executionTrace())
        let fullTrace = try #require(JSONSerialization.jsonObject(with: fullTraceData) as? [String: Any])
        let fullEntries = try #require(fullTrace["entries"] as? [[String: Any]])
        #expect(fullEntries[1]["disposition"] as? String == "missing-result")
        #expect(fullEntries[1]["isError"] is NSNull)
        #expect(fullEntries[1]["result"] is NSNull)
    }

    @Test
    func `Trace replaces arbitrary field names with stable ordinals at every object depth`() throws {
        let topStringKey = "alpha meet me behind the greenhouse at eleven"
        let topNumberKey = "beta violet elephant porch"
        let nestedStringKey = "alpha https private example invite"
        let nestedBooleanKey = "beta private diary toggle"
        let privateString = "top-level provider content must not survive"
        let nestedPrivateString = "nested provider content must not survive"

        let selectorForward = AnyAgentToolValue(object: [
            "identifier": AnyAgentToolValue(string: "basic-text-field"),
            nestedStringKey: AnyAgentToolValue(string: nestedPrivateString),
            nestedBooleanKey: AnyAgentToolValue(bool: true),
        ])
        var selectorReverseObject: [String: AnyAgentToolValue] = [:]
        selectorReverseObject[nestedBooleanKey] = AnyAgentToolValue(bool: true)
        selectorReverseObject[nestedStringKey] = AnyAgentToolValue(string: nestedPrivateString)
        selectorReverseObject["identifier"] = AnyAgentToolValue(string: "basic-text-field")

        var forward: [String: AnyAgentToolValue] = [:]
        forward["app"] = AnyAgentToolValue(string: "TextEdit")
        forward[topStringKey] = AnyAgentToolValue(string: privateString)
        forward[topNumberKey] = AnyAgentToolValue(int: 731_991)
        forward["selector"] = selectorForward
        forward["window_id"] = AnyAgentToolValue(int: 42)
        var reverse: [String: AnyAgentToolValue] = [:]
        reverse["window_id"] = AnyAgentToolValue(int: 42)
        reverse["selector"] = AnyAgentToolValue(object: selectorReverseObject)
        reverse[topNumberKey] = AnyAgentToolValue(int: 731_991)
        reverse[topStringKey] = AnyAgentToolValue(string: privateString)
        reverse["app"] = AnyAgentToolValue(string: "TextEdit")

        let calls = [
            AgentToolCall(id: "preserved-forward", name: "verify_state", arguments: forward),
            AgentToolCall(id: "preserved-reverse", name: "verify_state", arguments: reverse),
        ]
        let result = AgentExecutionResult(
            content: "",
            messages: [ModelMessage(role: .assistant, content: calls.map(ModelMessage.ContentPart.toolCall))],
            metadata: AgentMetadata(
                executionTime: 0,
                toolCallCount: calls.count,
                modelName: "test",
                startTime: Date(),
                endTime: Date()))

        let trace = result.executionTrace()
        let first = try #require(trace.entries.first)
        let second = try #require(trace.entries.last)
        let selector = try #require(first.arguments["selector"]?.objectValue)
        let data = try JSONEncoder().encode(trace)
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(first.id == "preserved-forward")
        #expect(second.id == "preserved-reverse")
        #expect(first.name == "verify_state")
        #expect(second.name == "verify_state")
        #expect(first.arguments == second.arguments)
        #expect(first.arguments["app"]?.stringValue == "TextEdit")
        #expect(first.arguments["window_id"]?.intValue == 42)
        #expect(first.arguments["__peekaboo_trace_unknown_field_1"]?.objectValue?["value_type"]?.stringValue ==
            "string")
        #expect(first.arguments["__peekaboo_trace_unknown_field_2"]?.objectValue?["value_type"]?.stringValue ==
            "integer")
        #expect(selector["identifier"]?.stringValue == "basic-text-field")
        #expect(selector["__peekaboo_trace_unknown_field_1"]?.objectValue?["value_type"]?.stringValue == "string")
        #expect(selector["__peekaboo_trace_unknown_field_2"]?.objectValue?["value_type"]?.stringValue == "boolean")
        for privateContent in [
            topStringKey,
            topNumberKey,
            nestedStringKey,
            nestedBooleanKey,
            privateString,
            nestedPrivateString,
            "731991",
        ] {
            #expect(!text.contains(privateContent))
        }
    }
}

private actor AgentExecutionTraceRecorder {
    private var names: [String] = []

    func record(_ name: String) {
        self.names.append(name)
    }

    func snapshot() -> [String] {
        self.names
    }
}
