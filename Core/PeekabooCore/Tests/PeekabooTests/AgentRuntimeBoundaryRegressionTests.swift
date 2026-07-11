import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct AgentRuntimeBoundaryRegressionTests {
    private let model = LanguageModel.anthropic(.opus47)

    @Test
    func `Unbuffered truncated stream cannot execute decoded tool call`() async throws {
        let toolCall = AgentToolCall(id: "truncated-call", name: "probe", arguments: [:])
        let provider = RuntimeBoundaryProvider(
            text: "",
            toolCalls: [toolCall],
            emitsTerminalEvent: false)
        let executions = RuntimeBoundaryCounter()
        let events = RuntimeBoundaryEventRecorder()
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let configuration = self.configuration(
            provider: provider,
            tools: [self.tool(named: "probe", counter: executions)],
            eventHandler: EventHandler { event in await events.record(event) })

        let error = await #expect(throws: TachikomaError.self) {
            _ = try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 1,
                initialMessages: [.user("Run the probe.")])
        }

        #expect(error?.localizedDescription.contains("without a terminal event") == true)
        #expect(await executions.isEmpty)
        #expect(await events.snapshot().isEmpty)
    }

    @Test
    func `Cancellation after streamed starts emits failed completions for every call`() async throws {
        let toolCalls = [
            AgentToolCall(id: "first-call", name: "first", arguments: [:]),
            AgentToolCall(id: "second-call", name: "second", arguments: [:]),
        ]
        let provider = RuntimeBoundaryProvider(text: "", toolCalls: toolCalls)
        let executions = RuntimeBoundaryCounter()
        let events = RuntimeBoundaryEventRecorder()
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let eventHandler = EventHandler { event in
            await events.record(event)
            if case .toolCallStarted = event {
                withUnsafeCurrentTask { task in task?.cancel() }
            }
        }
        let configuration = self.configuration(
            provider: provider,
            tools: [
                self.tool(named: "first", counter: executions),
                self.tool(named: "second", counter: executions),
            ],
            eventHandler: eventHandler)
        var checkpoint: PeekabooAgentService.StreamingLoopOutcome?

        let task = Task { @MainActor in
            try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 1,
                initialMessages: [.user("Run both tools.")],
                onCheckpoint: { checkpoint = $0 })
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        let snapshot = await events.snapshot()
        #expect(snapshot.startedToolNames == ["first", "second"])
        #expect(snapshot.completedTools.map(\.name) == ["first", "second"])
        #expect(await executions.isEmpty)
        #expect(checkpoint?.steps.last?.toolResults.count == 2)
        #expect(checkpoint?.steps.last?.toolResults.allSatisfy(\.isError) == true)

        for completion in snapshot.completedTools {
            let payload = try #require(Self.decodeObject(completion.result))
            #expect(payload["success"] as? Bool == false)
            #expect(payload["cancelled"] as? Bool == true)
            #expect((payload["error"] as? String)?.isEmpty == false)
        }
    }

    @Test
    func `Cancellation from non-streaming tool start skips execution and balances lifecycle`() async throws {
        let toolCall = AgentToolCall(id: "cancelled-call", name: "side-effect", arguments: [:])
        let provider = RuntimeBoundaryProvider(text: "", toolCalls: [toolCall])
        let executions = RuntimeBoundaryCounter()
        let events = RuntimeBoundaryEventRecorder()
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let eventHandler = EventHandler { event in
            await events.record(event)
            if case .toolCallStarted = event {
                withUnsafeCurrentTask { task in task?.cancel() }
            }
        }
        let configuration = self.configuration(
            provider: provider,
            tools: [self.tool(named: toolCall.name, counter: executions)],
            eventHandler: eventHandler)
        var checkpoint: PeekabooAgentService.StreamingLoopOutcome?

        let task = Task { @MainActor in
            try await service.runGenerationLoop(
                configuration: configuration,
                maxSteps: 1,
                initialMessages: [.user("Run the side effect.")],
                onCheckpoint: { checkpoint = $0 })
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        let snapshot = await events.snapshot()
        #expect(snapshot.startedToolNames == [toolCall.name])
        #expect(snapshot.completedTools.map(\.name) == [toolCall.name])
        #expect(await executions.isEmpty)
        #expect(checkpoint?.steps.last?.toolResults.count == 1)
        #expect(checkpoint?.steps.last?.toolResults.first?.isError == true)

        let completion = try #require(snapshot.completedTools.first)
        let payload = try #require(Self.decodeObject(completion.result))
        #expect(payload["success"] as? Bool == false)
        #expect(payload["cancelled"] as? Bool == true)
        #expect(payload["skipped"] == nil)
        #expect((payload["error"] as? String)?.isEmpty == false)
    }

    @Test(arguments: [false, true])
    func `Terminal done and need info reasons follow prior narration without duplication`(
        _ streaming: Bool) async throws
    {
        let narration = "Preparing the final result."
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }

        for fixture in RuntimeTerminalFixture.allCases {
            let provider = RuntimeBoundaryProvider(text: narration, toolCalls: [fixture.call])
            let configuration = self.configuration(
                provider: provider,
                tools: [self.tool(named: fixture.call.name)],
                eventHandler: nil)
            let outcome = if streaming {
                try await service.runStreamingLoop(
                    configuration: configuration,
                    maxSteps: 1,
                    initialMessages: [.user("Finish the task.")])
            } else {
                try await service.runGenerationLoop(
                    configuration: configuration,
                    maxSteps: 1,
                    initialMessages: [.user("Finish the task.")])
            }
            let expected = "\(narration)\n\n\(fixture.reason)"

            #expect(outcome.content == expected)
            #expect(service.contentByAppendingTurnBoundaryReason(fixture.reason, to: expected) == expected)
        }
    }

    @Test(arguments: [false, true])
    func `Boundary skipped calls receive balanced failed completion events`(_ streaming: Bool) async throws {
        let doneCall = RuntimeTerminalFixture.done.call
        let skippedCall = AgentToolCall(id: "skipped-call", name: "later", arguments: [:])
        let provider = RuntimeBoundaryProvider(text: "", toolCalls: [doneCall, skippedCall])
        let skippedExecutions = RuntimeBoundaryCounter()
        let events = RuntimeBoundaryEventRecorder()
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let configuration = self.configuration(
            provider: provider,
            tools: [
                self.tool(named: doneCall.name),
                self.tool(named: skippedCall.name, counter: skippedExecutions),
            ],
            eventHandler: EventHandler { event in await events.record(event) })

        let outcome = if streaming {
            try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 1,
                initialMessages: [.user("Finish before the later call.")])
        } else {
            try await service.runGenerationLoop(
                configuration: configuration,
                maxSteps: 1,
                initialMessages: [.user("Finish before the later call.")])
        }

        let snapshot = await events.snapshot()
        #expect(snapshot.startedToolNames == ["done", "later"])
        #expect(snapshot.completedTools.map(\.name) == ["done", "later"])
        #expect(await skippedExecutions.isEmpty)
        #expect(outcome.steps.last?.toolResults.map(\.toolCallId) == ["done-call", "skipped-call"])
        #expect(outcome.steps.last?.toolResults.last?.isError == true)

        let skippedCompletion = try #require(snapshot.completedTools.last)
        let payload = try #require(Self.decodeObject(skippedCompletion.result))
        #expect(payload["success"] as? Bool == false)
        #expect(payload["skipped"] as? Bool == true)
        #expect((payload["error"] as? String)?.isEmpty == false)
    }

    private func configuration(
        provider: any ModelProvider,
        tools: [AgentTool],
        eventHandler: EventHandler?) -> PeekabooAgentService.StreamingLoopConfiguration
    {
        PeekabooAgentService.StreamingLoopConfiguration(
            model: self.model,
            provider: provider,
            tools: tools,
            sessionId: "runtime-boundary-test",
            eventHandler: eventHandler,
            enhancementOptions: nil)
    }

    private func tool(named name: String, counter: RuntimeBoundaryCounter? = nil) -> AgentTool {
        AgentTool(
            name: name,
            description: name,
            parameters: AgentToolParameters(properties: [:], required: []),
            execute: { _ in
                await counter?.increment()
                return AnyAgentToolValue(string: "\(name)-ok")
            })
    }

    private func makeAgentService() throws -> (
        service: PeekabooAgentService,
        store: IsolatedAgentSessionStore)
    {
        let store = try IsolatedAgentSessionStore()
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: self.model,
            sessionManager: store.manager)
        return (service, store)
    }

    private static func decodeObject(_ value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private enum RuntimeTerminalFixture: CaseIterable {
    case done
    case needInfo

    var call: AgentToolCall {
        switch self {
        case .done:
            AgentToolCall(
                id: "done-call",
                name: "done",
                arguments: ["message": AnyAgentToolValue(string: "Finished export")])
        case .needInfo:
            AgentToolCall(
                id: "need-info-call",
                name: "need_info",
                arguments: ["question": AnyAgentToolValue(string: "Which account?")])
        }
    }

    var reason: String {
        switch self {
        case .done: "Finished export"
        case .needInfo: "Need more information: Which account?"
        }
    }
}

private final class RuntimeBoundaryProvider: ModelProvider, @unchecked Sendable {
    let modelId = "runtime-boundary-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let text: String
    private let toolCalls: [AgentToolCall]
    private let emitsTerminalEvent: Bool

    init(
        text: String,
        toolCalls: [AgentToolCall],
        emitsTerminalEvent: Bool = true)
    {
        self.text = text
        self.toolCalls = toolCalls
        self.emitsTerminalEvent = emitsTerminalEvent
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(
            text: self.text,
            finishReason: .toolCalls,
            toolCalls: self.toolCalls)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            if !self.text.isEmpty {
                continuation.yield(.text(self.text))
            }
            for toolCall in self.toolCalls {
                continuation.yield(.tool(toolCall))
            }
            if self.emitsTerminalEvent {
                continuation.yield(.done(finishReason: .toolCalls))
            }
            continuation.finish()
        }
    }
}

private actor RuntimeBoundaryCounter {
    private var hasExecuted = false

    var isEmpty: Bool {
        !self.hasExecuted
    }

    func increment() {
        self.hasExecuted = true
    }
}

private actor RuntimeBoundaryEventRecorder {
    private var events: [AgentEvent] = []

    func record(_ event: AgentEvent) {
        self.events.append(event)
    }

    func snapshot() -> [AgentEvent] {
        self.events
    }
}

extension [AgentEvent] {
    var startedToolNames: [String] {
        self.compactMap { event in
            if case let .toolCallStarted(name, _) = event {
                name
            } else {
                nil
            }
        }
    }

    var completedTools: [(name: String, result: String)] {
        self.compactMap { event in
            if case let .toolCallCompleted(name, result) = event {
                (name, result)
            } else {
                nil
            }
        }
    }
}
