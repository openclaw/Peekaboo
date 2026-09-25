import Foundation
import PeekabooAgentRuntime
import PeekabooFoundation
import Tachikoma
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct AgentRecordedOutcomeOutputTests {
    @Test
    func `JSON keeps narrative success and original outcomes beside the diagnostic`() throws {
        let result = try Self.result()
        let command = try AgentCommand.parse(["fixture", "--json"])
        let response = command.makeAgentJSONResponse(result)
        let payload = try #require(response["result"] as? [String: Any])
        let trace = try #require(payload["executionTrace"] as? [String: Any])
        let entries = try #require(trace["entries"] as? [[String: Any]])
        let outcome = try #require(entries[0]["actionOutcome"] as? [String: Any])

        #expect(response["success"] as? Bool == true)
        #expect(payload["content"] as? String == result.content)
        #expect(payload["recordedOutcomeNotice"] as? String == result.executionTrace().recordedOutcomeNotice)
        #expect(outcome["state"] as? String == "dispatched_unverified")
        #expect(entries[0]["disposition"] as? String == "executed/failed")
    }

    @Test
    func `quiet stdout remains exactly model content plus its existing newline`() async throws {
        let result = try Self.result()
        let command = try AgentCommand.parse(["fixture", "--quiet"])
        let output = try await captureStandardOutputText { command.displayResult(result) }

        #expect(output == result.content + "\n")
    }

    @Test(arguments: [false, true])
    func `normal output emits one notice with or without a streamed completion`(
        streamedCompletion: Bool
    ) async throws {
        let result = try Self.result()
        let command = try AgentCommand.parse(["fixture", "--simple"])
        let delegate = AgentOutputDelegate(outputMode: .minimal, jsonOutput: false, task: "fixture")
        let output = try await captureStandardOutputText {
            if streamedCompletion {
                delegate.agentDidEmitEvent(.completed(summary: result.content, usage: nil))
            }
            command.displayResult(result, delegate: delegate)
        }
        let notice = try #require(result.executionTrace().recordedOutcomeNotice)

        #expect(output.components(separatedBy: notice).count == 2)
        #expect(output.contains("Task completed"))
    }

    private static func result() throws -> AgentExecutionResult {
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        let value = try JSONDecoder().decode(
            AnyAgentToolValue.self, from: JSONEncoder().encode(outcome.projection)
        )
        return AgentExecutionResult(
            content: "Effect observed. No outcomes remain unverified.\n",
            messages: [
                ModelMessage(role: .assistant, content: [.toolCall(AgentToolCall(
                    id: "click", name: "click", arguments: [:]
                ))]),
                ModelMessage(role: .tool, content: [.toolResult(AgentToolResult(
                    toolCallId: "click", result: value
                ))]),
            ],
            metadata: AgentMetadata(
                executionTime: 0,
                toolCallCount: 1,
                modelName: "fixture",
                startTime: Date(timeIntervalSince1970: 0),
                endTime: Date(timeIntervalSince1970: 0)
            )
        )
    }
}
