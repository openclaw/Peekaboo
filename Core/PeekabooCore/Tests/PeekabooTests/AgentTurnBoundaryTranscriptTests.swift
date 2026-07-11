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

    @Test(.timeLimit(.minutes(1)))
    func `parent cancellation checkpoints completed tools and skips remaining dispatch`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let probe = ToolCancellationProbe()
        let transcriptStore = CancellationTranscriptStore()
        let toolCalls = [
            AgentToolCall(id: "first-call", name: "first", arguments: [:]),
            AgentToolCall(id: "second-call", name: "second", arguments: [:]),
            AgentToolCall(id: "third-call", name: "third", arguments: [:]),
        ]
        let tools = [
            AgentTool(
                name: "first",
                description: "first",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in AnyAgentToolValue(string: "first-ok") }),
            AgentTool(
                name: "second",
                description: "second",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in
                    await probe.markSecondStarted()
                    do {
                        try await Task.sleep(for: .seconds(30))
                    } catch is CancellationError {
                        // Simulate a side effect that completed while ignoring cooperative cancellation.
                    }
                    return AnyAgentToolValue(string: "second-ok")
                }),
            AgentTool(
                name: "third",
                description: "third",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in
                    await probe.markThirdExecuted()
                    return AnyAgentToolValue(string: "third-ok")
                }),
        ]
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "test-session")

        let task = Task { @MainActor () -> CancellationWorkerOutcome in
            var messages: [ModelMessage] = []
            var checkpoint: GenerationStep?
            do {
                _ = try await service.handleToolCalls(
                    stepText: "",
                    toolCalls: toolCalls,
                    context: context,
                    currentMessages: &messages,
                    stepIndex: 0,
                    onCancellationCheckpoint: { checkpoint = $0 })
                return .completed
            } catch {
                await transcriptStore.capture(messages: messages, checkpoint: checkpoint)
                return if error is CancellationError {
                    .cancelled
                } else {
                    .failed(error.localizedDescription)
                }
            }
        }
        let taskObserver = Task {
            let outcome = await task.value
            await probe.markWorkerFinished(outcome)
        }
        defer { taskObserver.cancel() }

        guard await probe.waitForSecondStart(timeout: .seconds(5)) else {
            task.cancel()
            guard await probe.waitForWorkerFinish(timeout: .seconds(5)) != nil else {
                Issue.record("Timed out waiting for the canceled worker to stop")
                return
            }
            Issue.record("Timed out waiting for the second tool to start")
            return
        }
        task.cancel()
        guard let workerOutcome = await probe.waitForWorkerFinish(timeout: .seconds(5)) else {
            Issue.record("Timed out waiting for the canceled worker to stop")
            return
        }
        #expect(workerOutcome == .cancelled)

        let snapshot = await transcriptStore.snapshot()
        let checkpoint = try #require(snapshot.checkpoint)
        #expect(checkpoint.toolResults.map(\.toolCallId) == ["first-call", "second-call", "third-call"])
        #expect(checkpoint.toolResults.map(\.isError) == [false, false, true])
        #expect(snapshot.messages.count(where: { $0.role == .tool }) == toolCalls.count)
        #expect(await probe.thirdExecutionCount == 0)

        let skippedPayload = try #require(try checkpoint.toolResults[2].result.toJSON() as? [String: Any])
        #expect(skippedPayload["cancelled"] as? Bool == true)
        #expect(skippedPayload["skipped"] as? Bool == true)
    }

    @Test
    func `URL cancellation is rethrown and remaining tool calls are not dispatched`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let probe = ToolCancellationProbe()
        var messages: [ModelMessage] = []
        var checkpoint: GenerationStep?
        let toolCalls = [
            AgentToolCall(id: "cancelled-call", name: "cancelled", arguments: [:]),
            AgentToolCall(id: "never-call", name: "never", arguments: [:]),
        ]
        let tools = [
            AgentTool(
                name: "cancelled",
                description: "cancelled",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in throw URLError(.cancelled) }),
            AgentTool(
                name: "never",
                description: "never",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in
                    await probe.markThirdExecuted()
                    return AnyAgentToolValue(string: "unexpected")
                }),
        ]
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "test-session")

        await #expect(throws: CancellationError.self) {
            _ = try await service.handleToolCalls(
                stepText: "",
                toolCalls: toolCalls,
                context: context,
                currentMessages: &messages,
                stepIndex: 0,
                onCancellationCheckpoint: { checkpoint = $0 })
        }

        let captured = try #require(checkpoint)
        #expect(captured.toolResults.map(\.toolCallId) == ["cancelled-call", "never-call"])
        #expect(captured.toolResults.map(\.isError) == [true, true])
        #expect(messages.count(where: { $0.role == .tool }) == toolCalls.count)
        #expect(await probe.thirdExecutionCount == 0)
    }
}

private enum CancellationWorkerOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed(String)
}

private actor ToolCancellationProbe {
    private var secondStarted = false
    private var workerOutcome: CancellationWorkerOutcome?
    private(set) var thirdExecutionCount = 0

    func markSecondStarted() {
        self.secondStarted = true
    }

    func waitForSecondStart(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !self.secondStarted {
            guard clock.now < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return true
    }

    func markWorkerFinished(_ outcome: CancellationWorkerOutcome) {
        self.workerOutcome = outcome
    }

    func waitForWorkerFinish(timeout: Duration) async -> CancellationWorkerOutcome? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while self.workerOutcome == nil {
            guard clock.now < deadline else { return nil }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return nil
            }
        }
        return self.workerOutcome
    }

    func markThirdExecuted() {
        self.thirdExecutionCount += 1
    }
}

private actor CancellationTranscriptStore {
    private var messages: [ModelMessage] = []
    private var checkpoint: GenerationStep?

    func capture(messages: [ModelMessage], checkpoint: GenerationStep?) {
        self.messages = messages
        self.checkpoint = checkpoint
    }

    func snapshot() -> (messages: [ModelMessage], checkpoint: GenerationStep?) {
        (self.messages, self.checkpoint)
    }
}
