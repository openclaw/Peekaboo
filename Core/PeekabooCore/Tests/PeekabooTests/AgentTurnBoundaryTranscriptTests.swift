import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@MainActor
struct AgentTurnBoundaryTranscriptTests {
    @Test
    func `turn boundary appends tool results for all advertised tool calls`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        var messages: [ModelMessage] = []
        let toolCalls = [
            AgentToolCall(id: "see-call", name: "see", arguments: [:]),
            AgentToolCall(id: "click-call", name: "click", arguments: [:]),
            AgentToolCall(id: "type-call", name: "type", arguments: [:]),
        ]
        let tools = ["see", "click", "type"].map { name in
            AgentTool(
                name: name,
                description: name,
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in AnyAgentToolValue(string: "\(name)-ok") })
        }
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "test-session")

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: toolCalls,
            context: context,
            currentMessages: &messages,
            stepIndex: 0)

        #expect(step.toolResults.map(\.toolCallId) == ["see-call", "click-call", "type-call"])
        #expect(step.toolResults.count == toolCalls.count)
        #expect(step.toolResults[2].isError)

        let toolMessages = messages.filter { $0.role == .tool }
        #expect(toolMessages.count == toolCalls.count)

        guard let skippedJSON = try? step.toolResults[2].result.toJSON() as? [String: Any] else {
            Issue.record("Expected skipped result to encode as an object")
            return
        }
        #expect(skippedJSON["skipped"] as? Bool == true)
        #expect((skippedJSON["reason"] as? String)?.contains("click") == true)
    }

    @Test
    func `unavailable advertised tool calls still receive tool results`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        var messages: [ModelMessage] = []
        let toolCalls = [
            AgentToolCall(id: "known-call", name: "known", arguments: [:]),
            AgentToolCall(id: "missing-call", name: "missing", arguments: [:]),
        ]
        let tools = [
            AgentTool(
                name: "known",
                description: "known",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in AnyAgentToolValue(string: "known-ok") }),
        ]
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "test-session")

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: toolCalls,
            context: context,
            currentMessages: &messages,
            stepIndex: 0)

        #expect(step.toolResults.map(\.toolCallId) == ["known-call", "missing-call"])
        #expect(step.toolResults[1].isError)
        #expect(messages.count(where: { $0.role == .tool }) == toolCalls.count)
    }

    @Test
    func `tool execution cancellation escapes tool handling`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        var messages: [ModelMessage] = []
        let toolCalls = [
            AgentToolCall(id: "click-call", name: "click", arguments: [:]),
        ]
        let tools = [
            AgentTool(
                name: "click",
                description: "click",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in throw CancellationError() }),
        ]
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "test-session")

        var cancelled = false
        do {
            _ = try await service.handleToolCalls(
                stepText: "",
                toolCalls: toolCalls,
                context: context,
                currentMessages: &messages,
                stepIndex: 0)
        } catch is CancellationError {
            cancelled = true
        }

        #expect(cancelled)
    }
}
