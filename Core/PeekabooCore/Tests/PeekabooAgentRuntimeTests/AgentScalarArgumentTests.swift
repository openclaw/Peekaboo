import Foundation
import MCP
import PeekabooCore
import Tachikoma
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct AgentScalarArgumentTests {
    @Test(arguments: [
        AnyAgentToolValue(string: "42"),
        AnyAgentToolValue(bool: true),
        AnyAgentToolValue(bool: false),
        AnyAgentToolValue(int: 0),
        AnyAgentToolValue(int: Int.max),
        AnyAgentToolValue(double: 1),
        AnyAgentToolValue(double: 1.25),
        AnyAgentToolValue(double: .leastNonzeroMagnitude),
        AnyAgentToolValue(double: .greatestFiniteMagnitude),
    ])
    func `Generated set value schema admits scalars and dispatches them unchanged`(
        _ value: AnyAgentToolValue) async throws
    {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let recorder = ScalarArgumentRecorder()
        let tool = self.probeTool(service: service, recorder: recorder)
        let call = AgentToolCall(id: "scalar", name: tool.name, arguments: self.arguments(value))
        let context = self.context(tool)

        #expect(service.makeToolPreflightResult(for: call, context: context) == nil)
        let result = try await self.execute(call, service: service, context: context)

        #expect(await recorder.values == [value])
        #expect(!result.isError)
        #expect(result.result.objectValue?["mutation_dispatched"]?.boolValue == true)
        #expect(result.result.objectValue?["retry_safe"]?.boolValue == false)
    }

    @Test(arguments: [
        AnyAgentToolValue(null: ()),
        AnyAgentToolValue(array: []),
        AnyAgentToolValue(array: [AnyAgentToolValue(int: 1)]),
        AnyAgentToolValue(object: [:]),
        AnyAgentToolValue(double: .infinity),
        AnyAgentToolValue(double: -.infinity),
        AnyAgentToolValue(double: .nan),
    ])
    func `Generated set value schema rejects non scalars and non finite numbers before dispatch`(
        _ value: AnyAgentToolValue) async throws
    {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let recorder = ScalarArgumentRecorder()
        let tool = self.probeTool(service: service, recorder: recorder)
        let call = AgentToolCall(id: "invalid-scalar", name: tool.name, arguments: self.arguments(value))
        let context = self.context(tool)
        let preflight = try #require(service.makeToolPreflightResult(for: call, context: context))
        self.expectValidationRefusal(preflight)

        try await self.expectValidationRefusal(self.execute(call, service: service, context: context))
        #expect(await recorder.values.isEmpty)
    }

    @Test(arguments: ["missing-on", "missing-value", "unknown", "invalid-on", "invalid-snapshot"])
    func `Scalar union does not relax required fields unknown fields or sibling types`(_ invalid: String) async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let recorder = ScalarArgumentRecorder()
        let tool = self.probeTool(service: service, recorder: recorder)
        var arguments = self.arguments(AnyAgentToolValue(bool: true))
        switch invalid {
        case "missing-on": arguments.removeValue(forKey: "on")
        case "missing-value": arguments.removeValue(forKey: "value")
        case "unknown": arguments["extra"] = AnyAgentToolValue(string: "unexpected")
        case "invalid-on": arguments["on"] = AnyAgentToolValue(bool: true)
        default: arguments["snapshot"] = AnyAgentToolValue(int: 1)
        }
        let call = AgentToolCall(id: invalid, name: tool.name, arguments: arguments)

        try await self.expectValidationRefusal(self.execute(call, service: service, context: self.context(tool)))
        #expect(await recorder.values.isEmpty)
    }

    @Test(arguments: ["oneOf", "enum", "const", "sibling", "nested", "null", "object", "array"])
    func `Scalar fast path does not widen constrained or composed schemas`(_ shape: String) throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        var leaf: [String: Value] = ["type": .string("boolean")]
        var property: [String: Value] = [:]
        switch shape {
        case "enum": leaf["enum"] = .array([.bool(false)])
        case "const": leaf["const"] = .bool(false)
        case "sibling": property["const"] = .string("only-this-string")
        case "nested": leaf = ["anyOf": .array([.object(leaf)])]
        case "null", "object", "array": leaf["type"] = .string(shape)
        default: break
        }
        property[shape == "oneOf" ? "oneOf" : "anyOf"] = .array([
            .object(["type": .string("string")]), .object(leaf),
        ])
        let schema = Value.object([
            "type": .string("object"),
            "properties": .object(["choice": .object(property)]),
            "required": .array([.string("choice")]),
        ])
        let compatibility = service.convertMCPSchemaToAgentSchema(schema)
        #expect(compatibility.sourceSchema == nil)
        // Also guard the validator when an injected tool already carries a complete source schema.
        let parameters = AgentToolParameters(
            properties: compatibility.properties,
            required: compatibility.required,
            sourceSchema: schema.toAnyAgentToolValue())
        let tool = AgentTool(name: "schema_probe", description: "Synthetic schema", parameters: parameters) { _ in
            Issue.record("Schema-only probe must not dispatch")
            return AnyAgentToolValue(null: ())
        }

        #expect(AgentToolArgumentValidator.rejection(
            tool: tool,
            arguments: AgentToolArguments(["choice": AnyAgentToolValue(bool: true)])) != nil)
        // Unsupported schemas retain compatibility validation; native tools own richer semantic checks.
        #expect(AgentToolArgumentValidator.rejection(
            tool: tool,
            arguments: AgentToolArguments(["choice": AnyAgentToolValue(string: "legacy string")])) == nil)
    }

    @Test
    func `Verify state retains structured predicate validation`() throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let tool = service.createVerifyStateTool()
        let predicate = AnyAgentToolValue(object: [
            "kind": AnyAgentToolValue(string: "window_exists"),
            "expected": AnyAgentToolValue(bool: true),
        ])
        #expect(AgentToolArgumentValidator.rejection(
            tool: tool,
            arguments: AgentToolArguments(["predicates": AnyAgentToolValue(array: [predicate])])) == nil)
        #expect(AgentToolArgumentValidator.rejection(
            tool: tool,
            arguments: AgentToolArguments([
                "predicates": AnyAgentToolValue(array: [AnyAgentToolValue(string: "window exists")]),
            ])) != nil)
    }

    @Test
    func `Static completion and injected tools keep their existing argument validation`() throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        for (tool, key) in [(service.createDoneTool(), "message"), (service.createNeedInfoTool(), "question")] {
            #expect(tool.parameters.sourceSchema == nil)
            #expect(AgentToolArgumentValidator.rejection(
                tool: tool,
                arguments: AgentToolArguments([key: AnyAgentToolValue(string: "synthetic")])) == nil)
            #expect(AgentToolArgumentValidator.rejection(
                tool: tool,
                arguments: AgentToolArguments([key: AnyAgentToolValue(bool: true)])) != nil)
        }
        #expect(AgentToolArgumentValidator.rejection(
            tool: service.createDoneTool(), arguments: AgentToolArguments([:])) == nil)
        #expect(AgentToolArgumentValidator.rejection(
            tool: service.createNeedInfoTool(), arguments: AgentToolArguments([:])) != nil)

        let injected = AgentTool(
            name: "injected",
            description: "Open compatibility schema",
            parameters: AgentToolParameters())
        { _ in
            AnyAgentToolValue(null: ())
        }
        #expect(AgentToolArgumentValidator.rejection(
            tool: injected,
            arguments: AgentToolArguments(["custom": AnyAgentToolValue(bool: true)])) == nil)
    }

    private func probeTool(service: PeekabooAgentService, recorder: ScalarArgumentRecorder) -> AgentTool {
        let native = service.createSetValueTool()
        return AgentTool(
            name: native.name,
            description: native.description,
            parameters: native.parameters)
        { arguments in
            await recorder.record(arguments["value"])
            return try AgentToolMCPBridge.convert(ToolResponse.text("Synthetic dispatch", meta: .object([
                "mutation_dispatched": .bool(true),
                "retry_safe": .bool(false),
            ]))).executionValue()
        }
    }

    private func arguments(_ value: AnyAgentToolValue) -> [String: AnyAgentToolValue] {
        [
            "on": AnyAgentToolValue(string: "synthetic-control"),
            "snapshot": AnyAgentToolValue(string: "synthetic-snapshot"),
            "value": value,
        ]
    }

    private func context(_ tool: AgentTool) -> PeekabooAgentService.ToolHandlingContext {
        PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: [tool],
            eventHandler: nil,
            sessionId: "scalar-schema-test",
            executionPolicy: .backgroundOnly)
    }

    private func execute(
        _ call: AgentToolCall,
        service: PeekabooAgentService,
        context: PeekabooAgentService.ToolHandlingContext) async throws -> AgentToolResult
    {
        var messages: [ModelMessage] = []
        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: [call],
            context: context,
            currentMessages: &messages,
            stepIndex: 0)
        return try #require(step.toolResults.first)
    }

    private func expectValidationRefusal(_ result: AgentToolResult) {
        #expect(result.isError)
        let metadata = result.failure?.metadata?.objectValue
        #expect(metadata?["error_code"]?.stringValue == "VALIDATION_ERROR")
        #expect(metadata?["refusal_reason"]?.stringValue == "invalid_request")
        #expect(metadata?["mutation_dispatched"]?.boolValue == false)
        #expect(metadata?["retry_safe"]?.boolValue == true)
        #expect(metadata?["skipped"]?.boolValue == true)
    }
}

private actor ScalarArgumentRecorder {
    private(set) var values: [AnyAgentToolValue] = []

    func record(_ value: AnyAgentToolValue?) {
        if let value {
            self.values.append(value)
        }
    }
}
