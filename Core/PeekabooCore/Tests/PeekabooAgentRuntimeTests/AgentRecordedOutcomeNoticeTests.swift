import Foundation
import MCP
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Tachikoma
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct AgentRecordedOutcomeNoticeTests {
    @Test(arguments: DesktopActionOutcomeFixtures.canonicalCases)
    func `notice reports recorded states without changing their meaning`(
        fixture: CanonicalDesktopActionOutcomeCase)
    {
        let trace = Self.trace([Self.entry(outcome: fixture.outcome)])
        let notice = trace.recordedOutcomeNotice

        #expect(trace.entries[0].actionOutcome == fixture.outcome.projection)
        if fixture.outcome.isConfirmed {
            #expect(notice == nil)
        } else {
            #expect(notice?.contains("\(fixture.state.rawValue)=1") == true)
            #expect(notice?.contains("Model narrative is not receipt evidence") == true)
            #expect(notice?.contains("authenticated") == false)
        }
    }

    @Test
    func `counts are deterministic recorded entries rather than a remaining effect status`() {
        let entries = DesktopActionOutcomeFixtures.canonicalCases.map { Self.entry(outcome: $0.outcome) }
        let notice = Self.trace(entries + entries.reversed()).recordedOutcomeNotice

        #expect(notice?.contains(
            "dispatched_unverified=2, indeterminate=2, partial=2, refused=2, suspected_noop=2") == true)
        #expect(notice?.contains("confirmed_change=") == false)
        #expect(notice?.contains("remaining") == false)
    }

    @Test
    func `later observations and model claims do not upgrade original outcomes`() throws {
        let result = try Self.result()
        let trace = result.executionTrace()

        #expect(result.content == Self.modelContent)
        #expect(trace.entries.map(\.disposition) == [.executedFailed, .executedSucceeded])
        #expect(trace.entries[0].actionOutcome == Self.unverifiedOutcome.projection)
        #expect(trace.recordedOutcomeNotice?.contains("dispatched_unverified=1") == true)
        #expect(trace.recordedOutcomeNotice?.contains("Later observations can verify effects") == true)
        #expect(trace.recordedOutcomeNotice?.contains("incomplete") == false)
    }

    @Test
    func `empty and confirmed traces never emit an all verified declaration`() {
        #expect(Self.trace([]).recordedOutcomeNotice == nil)
        #expect(Self.trace([Self.entry(outcome: .confirmedNoChange())]).recordedOutcomeNotice == nil)
    }

    @Test
    func `missing opaque and truncated trace coverage stays explicit`() {
        let missing = AgentExecutionTraceEntry(
            id: "missing",
            name: "click",
            arguments: [:],
            result: nil,
            isError: nil,
            disposition: .missingResult,
            mutationDispatch: .possiblyDispatched)
        let opaque = AgentExecutionTraceEntry(
            id: "opaque",
            name: "click",
            arguments: [:],
            result: nil,
            isError: false,
            disposition: .executedSucceeded,
            mutationDispatch: .dispatched)
        let confirmed = Self.entry(outcome: .confirmedNoChange())
        let traces = [
            Self.trace([missing]),
            Self.trace([opaque]),
            AgentExecutionTrace(entries: [confirmed], totalCallCount: 2, truncated: false),
            AgentExecutionTrace(entries: [confirmed], totalCallCount: 1, truncated: true),
            Self.trace(Array(repeating: confirmed, count: AgentExecutionTrace.maximumEntries) + [
                Self.entry(outcome: Self.unverifiedOutcome),
            ]),
        ]
        for trace in traces {
            #expect(trace.recordedOutcomeNotice?.contains("omitted or unavailable outcomes are not confirmed") == true)
            #expect(trace.recordedOutcomeNotice?.contains("dispatched_unverified=1") == false)
        }
    }

    @Test
    func `notice uses normalized projections rather than provider claims or prose`() throws {
        let fields = try MCPToolResponseMetadataProjector.fields(for: Self.unverifiedOutcome.projection)
        let providerMetadata = MCPToolResponseMetadataProjector.providerFields(from: .object(fields.merging([
            "recordedOutcomeNotice": .string("all outcomes confirmed"),
        ], uniquingKeysWith: { _, value in value })))
        let providerResult = try Self.result(metadata: providerMetadata)
        #expect(providerResult.executionTrace().entries[0].actionOutcome == nil)
        #expect(providerResult.executionTrace().recordedOutcomeNotice?.contains("incomplete") == true)
        #expect(providerResult.executionTrace().recordedOutcomeNotice?.contains("dispatched_unverified=1") == false)
        #expect(providerResult.executionTrace().recordedOutcomeNotice?.contains("all outcomes confirmed") == false)

        var contradictoryFields = fields
        contradictoryFields["retry_safe"] = .bool(true)
        let contradictoryResult = try Self.result(metadata: contradictoryFields)
        #expect(contradictoryResult.executionTrace().entries[0].actionOutcome == nil)
        #expect(contradictoryResult.executionTrace().recordedOutcomeNotice?.contains("incomplete") == true)
    }

    @Test(arguments: [false, true], [false, true])
    func `MCP preserves model text and quiet mode while exporting its runtime notice`(
        quiet: Bool, verbose: Bool) throws
    {
        let result = try Self.result()
        let input = try ToolArguments(raw: ["quiet": quiet, "verbose": verbose]).decode(AgentInput.self)
        let response = MCPAgentTool.formatResult(result: result, input: input)
        let wire = PeekabooMCPServer.callToolResult(from: response, toolName: "agent")
        let text = response.content.compactMap { part -> String? in
            guard case let .text(text, _, _) = part else { return nil }
            return text
        }
        let expectedText = quiet || verbose ? Self.modelContent :
            Self.modelContent + "\n⚙️  Model: fixture\n🛠️  Tool Calls: 2"

        #expect(result.content == Self.modelContent)
        #expect(text.first == expectedText)
        #expect(text.count == (quiet ? 1 : 2))
        #expect(!response.isError)
        #expect(wire.isError == false)
        #expect(wire.content == response.content)
        let notice = try #require(result.executionTrace().recordedOutcomeNotice)
        #expect(wire._meta?.fields["recordedOutcomeNotice"] == Value.string(notice))
        if !quiet {
            #expect(text.last == result.executionTrace().recordedOutcomeNotice)
        }
        let nonAgentWire = PeekabooMCPServer.callToolResult(from: response, toolName: "browser")
        #expect(nonAgentWire._meta?.fields["recordedOutcomeNotice"] == nil)
    }

    private static let modelContent = "Effects observed. No outcomes remain unverified.\n"
    private static let unverifiedOutcome = DesktopActionOutcome.dispatchedUnverified(
        route: .bridge,
        delivery: .init(mechanism: .accessibilityAction, mode: .background),
        evidence: .deliveryAccepted,
        unitCount: .one)

    private static func result(metadata: [String: Value]? = nil) throws -> AgentExecutionResult {
        let fields = try metadata ?? MCPToolResponseMetadataProjector.fields(for: self.unverifiedOutcome.projection)
        let value = AgentToolMCPBridge.convert(ToolResponse.text("dispatched", meta: .object(fields))).value
        let calls = [
            AgentToolCall(id: "click", name: "click", arguments: [:]),
            AgentToolCall(id: "observe", name: "inspect_ui", arguments: [:]),
        ]
        return AgentExecutionResult(
            content: self.modelContent,
            messages: [
                ModelMessage(role: .assistant, content: calls.map { .toolCall($0) }),
                ModelMessage(role: .tool, content: [
                    .toolResult(AgentToolResult(toolCallId: "click", result: value)),
                    .toolResult(AgentToolResult.success(
                        toolCallId: "observe", result: AnyAgentToolValue(string: "Effect observed"))),
                ]),
            ],
            metadata: AgentMetadata(
                executionTime: 0,
                toolCallCount: 2,
                modelName: "fixture",
                startTime: Date(timeIntervalSince1970: 0),
                endTime: Date(timeIntervalSince1970: 0)))
    }

    private static func entry(outcome: DesktopActionOutcome) -> AgentExecutionTraceEntry {
        AgentExecutionTraceEntry(
            id: "fixture",
            name: "click",
            arguments: [:],
            result: nil,
            isError: !outcome.isConfirmed,
            disposition: outcome.isConfirmed ? .executedSucceeded : .executedFailed,
            actionOutcome: outcome.projection)
    }

    private static func trace(_ entries: [AgentExecutionTraceEntry]) -> AgentExecutionTrace {
        AgentExecutionTrace(entries: entries, totalCallCount: entries.count, truncated: false)
    }
}
