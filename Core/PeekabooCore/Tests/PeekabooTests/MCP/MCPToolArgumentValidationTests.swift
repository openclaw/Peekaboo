import MCP
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct MCPToolArgumentValidationTests {
    @Test
    func `generic numeric validation probes remain ordinary errors`() async throws {
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let counter = MCPNumericDispatchCounter()
        let typeTool = TypeTool(context: context)
        let cases: [(any MCPTool, String, Value)] = [
            (SleepTool(), "duration", .double(1e20)),
            (typeTool, "pid", .double(1234.9)),
            (typeTool, "window_id", .string("1234.9")),
            (typeTool, "delay", .double(.infinity)),
            (MoveTool(context: context), "duration", .double(.nan)),
            (DragTool(context: context), "steps", .string("100000000000000000000")),
            (ScrollTool(context: context), "amount", .double(3.5)),
            (SpaceTool(context: context), "to", .string("1e20")),
            (PressTool(context: context), "count", .double(.infinity)),
            (AppTool(context: context), "wait", .double(.infinity)),
            (DialogTool(context: context), "field_index", .double(1.5)),
            (PasteTool(context: context), "pid", .double(1234.9)),
            (PasteTool(context: context), "restore_delay_ms", .double(1e20)),
            (WindowTool(context: context), "window_id", .string("1234.9")),
            (BrowserTool(context: context), "timeout", .double(1.5)),
            (SeeTool(context: context), "max_depth", .double(1.5)),
            (InspectUITool(context: context), "max_children", .string("1e20")),
            (CaptureTool(context: context), "pid", .double(1234.9)),
            (CaptureTool(context: context), "quiet_ms", .double(0.5)),
        ]

        for (index, testCase) in cases.enumerated() {
            let (sourceTool, key, value) = testCase
            let probe = MCPNumericSchemaProbeTool(
                name: "numeric-probe-\(index)",
                inputSchema: sourceTool.inputSchema,
                counter: counter)
            let response = try await context.execute(
                tool: probe,
                arguments: ToolArguments(value: .object([key: value])))

            #expect(response.isError, "Expected \(sourceTool.name).\(key) to be rejected")
            #expect(response.meta == nil, "Generic probe gained desktop-action metadata for \(sourceTool.name).\(key)")
        }

        #expect(await counter.value == 0)
    }

    @Test
    func `Sleep tool rejects unsafe durations without conversion traps`() async throws {
        let tool = SleepTool()
        let invalidValues: [Value] = [
            .double(0.5),
            .double(1e20),
            .double(.nan),
            .double(.infinity),
            .string("100000000000000000000"),
        ]

        for value in invalidValues {
            let response = try await tool.execute(
                arguments: ToolArguments(value: .object(["duration": value])))
            #expect(response.isError)
        }
    }

    @Test
    func `exact whole numeric representations remain accepted`() async throws {
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let counter = MCPNumericDispatchCounter()
        let probe = MCPNumericSchemaProbeTool(
            name: "numeric-probe-valid",
            inputSchema: TypeTool(context: context).inputSchema,
            counter: counter)

        for value: Value in [.int(42), .double(42.0), .string("42")] {
            let response = try await context.execute(
                tool: probe,
                arguments: ToolArguments(value: .object(["delay": value])))
            #expect(!response.isError)
        }

        #expect(await counter.value == 3)
    }

    @Test
    func `unsafe interaction numerics dispatch no automation service calls`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            executionPolicy: .unrestricted)
        let cases: [(any MCPTool, [String: Value])] = [
            (TypeTool(context: context), [
                "text": .string("must-not-type"),
                "foreground": .bool(true),
                "delay": .double(1e20),
            ]),
            (TypeTool(context: context), [
                "text": .string("must-not-type"),
                "pid": .double(1234.9),
            ]),
            (ScrollTool(context: context), [
                "direction": .string("down"),
                "foreground": .bool(true),
                "amount": .double(.nan),
            ]),
            (PasteTool(context: context), [
                "text": .string("must-not-type"),
                "pid": .double(1234.9),
            ]),
        ]

        for (tool, values) in cases {
            let response = try await context.execute(
                tool: tool,
                arguments: ToolArguments(value: .object(values)))
            #expect(response.isError)
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["state"] == .string(DesktopActionOutcome.State.refused.rawValue))
            #expect(meta["effect"] == .string(DesktopActionOutcome.Effect.refused.rawValue))
            #expect(meta["refusal_reason"] == .string(DesktopActionOutcome.RefusalReason.invalidRequest.rawValue))
            #expect(meta["dispatch_state"] == .string("none"))
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
            #expect(meta["requires_fresh_observation"] == .bool(false))
            #expect(meta["error_code"] == .string("VALIDATION_ERROR"))
        }

        #expect(automation.lastTypeActions == nil)
        #expect(automation.targetedTypeActionsCalls.isEmpty)
        #expect(automation.scrollRequests.isEmpty)
    }

    @Test
    func `invalid read-only numerics omit desktop-action metadata`() async throws {
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let counter = MCPNumericDispatchCounter()
        let cases: [(name: String, schema: Value, arguments: [String: Value])] = [
            (
                "sleep",
                SleepTool().inputSchema,
                ["duration": .double(.infinity)]),
            (
                "see",
                SeeTool(context: context).inputSchema,
                ["max_depth": .double(1.5)]),
        ]

        for testCase in cases {
            let response = try await context.execute(
                tool: MCPNumericSchemaProbeTool(
                    name: testCase.name,
                    inputSchema: testCase.schema,
                    counter: counter),
                arguments: ToolArguments(value: .object(testCase.arguments)))

            #expect(response.isError)
            #expect(response.meta == nil)
        }

        #expect(await counter.value == 0)
    }

    @Test
    func `every closed catalog schema rejects unknown top-level properties before dispatch`() async throws {
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let counter = MCPUnknownPropertyDispatchCounter()
        let tools = MCPToolCatalog.unfilteredTools(context: context)
        let probeValues: [Value] = [
            .bool(true),
            .string("unexpected"),
            .int(17),
            .array([.string("nested")]),
            .object(["nested": .bool(false)]),
        ]

        #expect(tools.count == 26)
        for (index, sourceTool) in tools.enumerated() {
            guard case let .object(schema) = sourceTool.inputSchema else {
                Issue.record("Expected \(sourceTool.name) to advertise an object schema")
                continue
            }
            #expect(schema["additionalProperties"] == .bool(false))

            let unknownKey = "__unexpected_\(index)"
            let response = try await context.execute(
                tool: MCPUnknownPropertySchemaProbeTool(
                    name: sourceTool.name,
                    inputSchema: sourceTool.inputSchema,
                    counter: counter),
                arguments: ToolArguments(value: .object([
                    unknownKey: probeValues[index % probeValues.count],
                ])))

            #expect(response.isError, "Expected \(sourceTool.name) to reject \(unknownKey)")
        }

        #expect(await counter.value == 0)
    }

    @Test
    func `closed nested schemas reject unknown properties and accept declared properties`() async throws {
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let counter = MCPUnknownPropertyDispatchCounter()
        let cases: [(name: String, schema: Value, invalid: [String: Value], valid: [String: Value])] = [
            (
                "analyze",
                AnalyzeTool().inputSchema,
                [
                    "question": .string("What is shown?"),
                    "provider_config": .object(["bogus": .bool(true)]),
                ],
                [
                    "question": .string("What is shown?"),
                    "provider_config": .object(["type": .string("auto")]),
                ]),
            (
                "verify_state",
                VerifyStateTool(context: context).inputSchema,
                [
                    "predicates": .array([.object([
                        "kind": .string("window_exists"),
                        "expected": .bool(true),
                        "bogus": .int(1),
                    ])]),
                ],
                [
                    "predicates": .array([.object([
                        "kind": .string("window_exists"),
                        "expected": .bool(true),
                    ])]),
                ]),
            (
                "verify_state",
                VerifyStateTool(context: context).inputSchema,
                [
                    "predicates": .array([.object([
                        "kind": .string("element_exists"),
                        "selector": .object([
                            "identifier": .string("save-button"),
                            "bogus": .string("nested"),
                        ]),
                        "expected": .bool(true),
                    ])]),
                ],
                [
                    "predicates": .array([.object([
                        "kind": .string("element_exists"),
                        "selector": .object(["identifier": .string("save-button")]),
                        "expected": .bool(true),
                    ])]),
                ]),
        ]

        for testCase in cases {
            let probe = MCPUnknownPropertySchemaProbeTool(
                name: testCase.name,
                inputSchema: testCase.schema,
                counter: counter)
            let rejected = try await context.execute(
                tool: probe,
                arguments: ToolArguments(value: .object(testCase.invalid)))
            #expect(rejected.isError)

            let accepted = try await context.execute(
                tool: probe,
                arguments: ToolArguments(value: .object(testCase.valid)))
            #expect(!accepted.isError)
        }

        #expect(await counter.value == cases.count)
    }
}

private actor MCPUnknownPropertyDispatchCounter {
    private(set) var value = 0

    func increment() {
        self.value += 1
    }
}

private struct MCPUnknownPropertySchemaProbeTool: MCPTool {
    let name: String
    let description = "Unknown-property schema validation probe"
    let inputSchema: Value
    let counter: MCPUnknownPropertyDispatchCounter

    func execute(arguments _: ToolArguments) async throws -> ToolResponse {
        await self.counter.increment()
        return .text("dispatched")
    }
}

private actor MCPNumericDispatchCounter {
    private(set) var value = 0

    func increment() {
        self.value += 1
    }
}

private struct MCPNumericSchemaProbeTool: MCPTool {
    let name: String
    let description = "Numeric schema validation probe"
    let inputSchema: Value
    let counter: MCPNumericDispatchCounter

    func execute(arguments _: ToolArguments) async throws -> ToolResponse {
        await self.counter.increment()
        return .text("dispatched")
    }
}
