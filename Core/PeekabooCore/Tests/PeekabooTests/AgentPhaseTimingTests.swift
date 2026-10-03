import Foundation
import PeekabooAutomationKitTestSupport
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct AgentPhaseTimingTests {
    private typealias Timing = PeekabooAgentService.AgentPhaseTiming

    @Test(arguments: [false, true])
    func `Provider and tool timings preserve results and omit private content`(_ streaming: Bool) async throws {
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let service = try self.service(store: store)
        var timings: [Timing] = []
        service.phaseTimingObserver = { timings.append($0) }
        let call = AgentToolCall(
            id: "PRIVATE_TIMING_CALL",
            name: "PRIVATE_TIMING_TOOL",
            arguments: ["text": AnyAgentToolValue(string: "PRIVATE_TIMING_ARGUMENT")])
        let response = ProviderResponse(
            text: "PRIVATE_TIMING_RESPONSE",
            usage: Usage(inputTokens: 11, outputTokens: 7),
            finishReason: .toolCalls,
            toolCalls: [call])
        let provider = PhaseTimingProvider(response: response)
        let executions = AutomationTestLockedValue(0)
        let tool = AgentTool(
            name: call.name,
            description: "PRIVATE_TIMING_DESCRIPTION",
            parameters: AgentToolParameters(
                properties: ["text": .init(name: "text", type: .string, description: "Synthetic input")],
                required: ["text"]),
            execute: { arguments in
                #expect(arguments["text"]?.stringValue == "PRIVATE_TIMING_ARGUMENT")
                executions.withValue { $0 += 1 }
                return AnyAgentToolValue(string: "PRIVATE_TIMING_RESULT")
            })
        let outcome = try await self.run(service, provider: provider, tools: [tool], streaming: streaming)

        #expect(provider.calls.value == [streaming ? "stream" : "generate"])
        #expect(executions.value == 1)
        #expect(outcome.content == response.text)
        #expect(outcome.toolCallCount == 1)
        #expect(outcome.usage?.inputTokens == 11)
        #expect(outcome.usage?.outputTokens == 7)
        #expect(outcome.steps.first?.toolResults.first?.result.stringValue == "PRIVATE_TIMING_RESULT")
        #expect(timings.map(\.phase) == [streaming ? .providerStream : .providerGenerate, .tool])
        #expect(timings.map(\.status) == [.success, .success])
        #expect(timings.map(\.stepIndex) == [0, 0])
        for timing in timings {
            #expect(timing.elapsedMilliseconds.isFinite)
            #expect(timing.elapsedMilliseconds >= 0)
            #expect(!timing.logMessage.contains("PRIVATE_TIMING"))
            let fields = timing.logMessage.split(separator: " ")
            #expect(fields.count == 4)
            #expect(fields.map { String($0.prefix(while: { $0 != "=" })) } == [
                "phase", "step", "elapsed_ms", "status",
            ])
        }
    }

    @Test(arguments: [false, true], [false, true])
    func `Provider errors and cancellations finish one phase without changing the error`(
        streaming: Bool,
        cancelled: Bool) async throws
    {
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let service = try self.service(store: store)
        var timings: [Timing] = []
        service.phaseTimingObserver = { timings.append($0) }
        let error = NSError(
            domain: cancelled ? NSURLErrorDomain : "PRIVATE_TIMING_ERROR",
            code: cancelled ? NSURLErrorCancelled : 42,
            userInfo: [NSLocalizedDescriptionKey: "PRIVATE_TIMING_FAILURE_CONTENT"])
        let provider = PhaseTimingProvider(error: error)

        do {
            _ = try await self.run(service, provider: provider, streaming: streaming)
            Issue.record("Expected the provider error")
        } catch let observed as NSError {
            #expect(observed == error)
        }

        #expect(provider.calls.value == [streaming ? "stream" : "generate"])
        #expect(timings.map(\.phase) == [streaming ? .providerStream : .providerGenerate])
        #expect(timings.map(\.status) == [cancelled ? .cancelled : .error])
        #expect(timings.allSatisfy { !$0.logMessage.contains("PRIVATE_TIMING") })
    }

    @Test
    func `A pre-dispatch tool skip has no execution timing`() async throws {
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let service = try self.service(store: store)
        var timings: [Timing] = []
        service.phaseTimingObserver = { timings.append($0) }
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.opus47),
            tools: [],
            eventHandler: nil,
            sessionId: "PRIVATE_TIMING_SESSION",
            executionAuthority: .init(basePolicy: .unrestricted))
        var messages: [ModelMessage] = []
        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: [AgentToolCall(id: "PRIVATE_TIMING_CALL", name: "missing", arguments: [:])],
            context: context,
            currentMessages: &messages,
            stepIndex: 0)

        #expect(step.toolResults.first?.isError == true)
        #expect(timings.isEmpty)
    }

    @Test
    func `Timing preserves a returned value when an operation ignores cancellation`() async throws {
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let service = try self.service(store: store)
        var timings: [Timing] = []
        service.phaseTimingObserver = { timings.append($0) }
        let task = Task { @MainActor in
            await service.withAgentPhaseTiming(.providerGenerate, stepIndex: 0) {
                withUnsafeCurrentTask { $0?.cancel() }
                return "PRIVATE_TIMING_RETURNED_VALUE"
            }
        }

        #expect(await task.value == "PRIVATE_TIMING_RETURNED_VALUE")
        #expect(timings.map(\.status) == [.cancelled])
        #expect(timings.allSatisfy { !$0.logMessage.contains("PRIVATE_TIMING") })
    }

    @Test(arguments: [false, true])
    func `Streaming timing stays open through setup and consumption`(_ failDuringConsumption: Bool) async throws {
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let service = try self.service(store: store)
        var timings: [Timing] = []
        service.phaseTimingObserver = { timings.append($0) }
        let setupStarted = AsyncTestLatch()
        let allowSetup = AsyncTestLatch()
        let textObserved = AsyncTestLatch()
        let (stream, continuation) = AsyncThrowingStream<TextStreamDelta, any Error>.makeStream()
        let provider = PhaseTimingProvider(stream: {
            await setupStarted.open()
            await allowSetup.wait()
            return stream
        })
        let task = Task { @MainActor in
            try await self.run(
                service,
                provider: provider,
                streaming: true,
                eventHandler: EventHandler { event in
                    if case .assistantMessage = event {
                        await textObserved.open()
                    }
                })
        }
        await setupStarted.wait()
        #expect(timings.isEmpty)
        await allowSetup.open()
        continuation.yield(.text("PRIVATE_TIMING_STREAM_TEXT"))
        await textObserved.wait()
        #expect(timings.isEmpty)
        if failDuringConsumption {
            continuation.finish(throwing: PhaseTimingFailure.privateContent)
            await #expect(throws: PhaseTimingFailure.self) { _ = try await task.value }
        } else {
            continuation.yield(.done(finishReason: .stop))
            continuation.finish()
            let outcome = try await task.value
            #expect(outcome.content == "PRIVATE_TIMING_STREAM_TEXT")
        }
        #expect(provider.calls.value == ["stream"])
        #expect(timings.map(\.phase) == [.providerStream])
        #expect(timings.map(\.status) == [failDuringConsumption ? .error : .success])
    }

    @Test(arguments: [ToolOutcome.success, .reportedFailure, .thrownFailure, .cancelled])
    private func `Actual tool execution has one completion timing`(_ outcome: ToolOutcome) async throws {
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let service = try self.service(store: store)
        var timings: [Timing] = []
        service.phaseTimingObserver = { timings.append($0) }
        let executions = AutomationTestLockedValue(0)
        let tool = AgentTool(
            name: "probe",
            description: "Synthetic tool",
            parameters: AgentToolParameters(properties: [:], required: []),
            execute: { _ in
                executions.withValue { $0 += 1 }
                switch outcome {
                case .success: return AnyAgentToolValue(string: "PRIVATE_TIMING_TOOL_RESULT")
                case .reportedFailure: return AnyAgentToolValue(object: ["success": .init(bool: false)])
                case .thrownFailure: throw PhaseTimingFailure.privateContent
                case .cancelled: throw CancellationError()
                }
            })
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.opus47),
            tools: [tool],
            eventHandler: nil,
            sessionId: "PRIVATE_TIMING_SESSION",
            executionAuthority: .init(basePolicy: .unrestricted))
        var messages: [ModelMessage] = []
        do {
            let step = try await service.handleToolCalls(
                stepText: "PRIVATE_TIMING_NARRATION",
                toolCalls: [AgentToolCall(id: "PRIVATE_TIMING_CALL", name: "probe", arguments: [:])],
                context: context,
                currentMessages: &messages,
                stepIndex: 3)
            #expect(outcome != .cancelled)
            #expect(step.toolResults.first?.isError == (outcome != .success))
        } catch is CancellationError {
            #expect(outcome == .cancelled)
        }
        #expect(executions.value == 1)
        #expect(timings.map(\.phase) == [.tool])
        #expect(timings.map(\.stepIndex) == [3])
        #expect(timings.map(\.status) == [outcome.status])
        #expect(timings.allSatisfy { !$0.logMessage.contains("PRIVATE_TIMING") })
    }

    private enum ToolOutcome: Sendable {
        case success, reportedFailure, thrownFailure, cancelled

        var status: Timing.Status {
            switch self {
            case .success: .success
            case .reportedFailure, .thrownFailure: .error
            case .cancelled: .cancelled
            }
        }
    }

    private func service(store: IsolatedAgentSessionStore) throws -> PeekabooAgentService {
        try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.opus47),
            sessionManager: store.manager)
    }

    private func run(
        _ service: PeekabooAgentService,
        provider: any ModelProvider,
        tools: [AgentTool] = [],
        streaming: Bool,
        eventHandler: EventHandler? = nil) async throws -> PeekabooAgentService.StreamingLoopOutcome
    {
        let configuration = PeekabooAgentService.StreamingLoopConfiguration(
            model: .anthropic(.opus47),
            provider: provider,
            tools: tools,
            sessionId: "PRIVATE_TIMING_SESSION",
            eventHandler: eventHandler,
            enhancementOptions: nil,
            executionAuthority: .init(basePolicy: .unrestricted))
        let messages: [ModelMessage] = [.user("PRIVATE_TIMING_PROMPT /Users/example/private")]
        return if streaming {
            try await service.runStreamingLoop(configuration: configuration, maxSteps: 1, initialMessages: messages)
        } else {
            try await service.runGenerationLoop(configuration: configuration, maxSteps: 1, initialMessages: messages)
        }
    }
}

private enum PhaseTimingFailure: Error {
    case privateContent
}

private final class PhaseTimingProvider: ModelProvider, Sendable {
    let modelId = "PRIVATE_TIMING_MODEL"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()
    let calls = AutomationTestLockedValue<[String]>([])
    private let response: ProviderResponse
    private let error: (any Error)?
    private let stream: (@Sendable () async throws -> AsyncThrowingStream<TextStreamDelta, any Error>)?

    init(
        response: ProviderResponse = .init(text: "Finished", finishReason: .stop),
        error: (any Error)? = nil,
        stream: (@Sendable () async throws -> AsyncThrowingStream<TextStreamDelta, any Error>)? = nil)
    {
        self.response = response
        self.error = error
        self.stream = stream
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        self.calls.withValue { $0.append("generate") }
        if let error {
            throw error
        }
        return self.response
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        self.calls.withValue { $0.append("stream") }
        if let error {
            throw error
        }
        if let stream {
            return try await stream()
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(self.response.text))
            for call in self.response.toolCalls ?? [] {
                continuation.yield(.tool(call))
            }
            continuation.yield(.done(usage: self.response.usage, finishReason: self.response.finishReason))
            continuation.finish()
        }
    }
}
