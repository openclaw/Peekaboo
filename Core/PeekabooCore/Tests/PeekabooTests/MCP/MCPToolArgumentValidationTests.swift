import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct MCPToolArgumentValidationTests {
    @Test
    func `unsafe numeric arguments are refused before tool dispatch`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
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
            guard case let .object(meta) = response.meta else {
                Issue.record("Expected refusal metadata for \(sourceTool.name).\(key)")
                continue
            }
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
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
        let context = await MCPToolTestHelpers.makeContext()
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
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
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
        ]

        for (tool, values) in cases {
            let response = try await context.execute(
                tool: tool,
                arguments: ToolArguments(value: .object(values)))
            #expect(response.isError)
        }

        #expect(automation.lastTypeActions == nil)
        #expect(automation.targetedTypeActionsCalls.isEmpty)
        #expect(automation.scrollRequests.isEmpty)
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
