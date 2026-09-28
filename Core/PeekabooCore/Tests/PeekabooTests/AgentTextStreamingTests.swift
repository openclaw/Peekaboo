import Foundation
import PeekabooAutomationKitTestSupport
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct AgentTextStreamingTests {
    @Test(arguments: [false, true])
    func `Public streaming callback receives exact text chunks without reasoning or duplicated completion`(
        buffered: Bool) async throws
    {
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let provider = TextCallbackProvider(deltas: [
            .text("Let me explain."),
            .reasoning("synthetic reasoning must stay separate", signature: "fixture", type: "thinking"),
            .reasoning("synthetic redacted block", type: "redacted_thinking"),
            .text(""),
            .text(" "),
            .text("Finished."),
            .done(finishReason: .stop),
        ])
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }
        let previous = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previous }
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: buffered ? .openai(.gpt55) : .custom(provider: provider),
            sessionManager: store.manager)
        let chunks = AutomationTestLockedValue<[String]>([])

        let result = try await service.executeTaskStreaming("synthetic") { chunk in
            chunks.withValue { $0.append(chunk) }
        }

        #expect(provider.calls.value == ["stream"])
        #expect(result.content == "Let me explain. Finished.")
        #expect(chunks.value == ["Let me explain.", "", " ", "Finished."])
        #expect(chunks.value.joined() == result.content)
    }

    @Test
    func `Nonstreaming fallback still invokes the callback once`() async throws {
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let provider = TextCallbackProvider(deltas: [], streaming: false)
        let service = try PeekabooAgentService(
            services: PeekabooServices(), defaultModel: .custom(provider: provider), sessionManager: store.manager)
        let chunks = AutomationTestLockedValue<[String]>([])
        let result = try await service.executeTaskStreaming("synthetic") { chunk in
            chunks.withValue { $0.append(chunk) }
        }
        #expect(provider.calls.value == ["generate"])
        #expect(chunks.value == ["Fallback."])
        #expect(result.content == "Fallback.")
    }

    private enum InvalidEnding: CaseIterable {
        case missing, late, truncated, refused, error, cancelled, other

        var tail: [TextStreamDelta] {
            switch self {
            case .missing: []
            case .late: [.done(finishReason: .toolCalls), .text("late")]
            case .truncated: [.done(finishReason: .length)]
            case .refused: [.done(finishReason: .contentFilter)]
            case .error: [.done(finishReason: .error)]
            case .cancelled: [.done(finishReason: .cancelled)]
            case .other: [.done(finishReason: .other)]
            }
        }
    }

    @Test(arguments: InvalidEnding.allCases)
    private func `Buffered stream failures emit no text and dispatch no tools`(ending: InvalidEnding) async throws {
        let executions = AutomationTestLockedValue(0)
        let chunks = AutomationTestLockedValue<[String]>([])
        await #expect(throws: (any Error).self) {
            _ = try await self.runLoop(
                deltas: [.text("prefix"), .tool(Self.toolCall)] + ending.tail,
                buffered: true,
                executions: executions)
            { text in chunks.withValue { $0.append(text) } }
        }
        #expect(chunks.value.isEmpty)
        #expect(executions.value == 0)
    }

    @Test(arguments: [false, true])
    func `Callback cancellation prevents later text and tool dispatch`(buffered: Bool) async throws {
        let executions = AutomationTestLockedValue(0)
        let chunks = AutomationTestLockedValue<[String]>([])
        let task = Task { @MainActor in
            try await self.runLoop(
                deltas: [.text("first"), .text("second"), .tool(Self.toolCall), .done(finishReason: .toolCalls)],
                buffered: buffered,
                executions: executions)
            { text in
                chunks.withValue { $0.append(text) }
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(chunks.value == ["first"])
        #expect(executions.value == 0)
    }

    @Test(arguments: [false, true])
    func `Text callbacks follow buffering policy and are awaited sequentially`(buffered: Bool) async throws {
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let provider = TextCallbackProvider(deltas: [])
        let model: LanguageModel = buffered ? .openai(.gpt55) : .custom(provider: provider)
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: model,
            sessionManager: store.manager)
        let nextChunkRequested = AsyncTestLatch()
        let releaseTerminal = AsyncTestLatch()
        let callbackEntered = AsyncTestLatch()
        let releaseCallback = AsyncTestLatch()
        let completed = AutomationTestLockedValue(false)
        let chunks = AutomationTestLockedValue<[String]>([])
        let index = AutomationTestLockedValue(0)
        let stream = AsyncThrowingStream<TextStreamDelta, any Error>(unfolding: {
            let current = index.withValue { value in
                let previous = value
                value += 1
                return previous
            }
            switch current {
            case 0: return .text("first")
            case 1:
                await nextChunkRequested.open()
                await releaseTerminal.wait()
                return .text("second")
            case 2: return .done(finishReason: .stop)
            default: return nil
            }
        })
        #expect(service.buffersAgentTextStreamUntilDone(for: model) == buffered)
        let task = Task { @MainActor in
            let result = try await service.collectStreamOutput(
                from: StreamTextResult(stream: stream, model: model, settings: GenerationSettings()),
                model: model,
                eventHandler: nil,
                textHandler: { text in
                    chunks.withValue { $0.append(text) }
                    if text == "first" {
                        await callbackEntered.open()
                        await releaseCallback.wait()
                    }
                },
                stepIndex: 0)
            completed.withValue { $0 = true }
            return result
        }
        if buffered {
            #expect(await nextChunkRequested.opensWithin(.seconds(2)))
            #expect(chunks.value.isEmpty)
            await releaseTerminal.open()
        }
        #expect(await callbackEntered.opensWithin(.seconds(2)))
        #expect(chunks.value == ["first"])
        #expect(!completed.value)
        await releaseCallback.open()
        await releaseTerminal.open()
        let result = try await task.value
        #expect(chunks.value == ["first", "second"])
        #expect(result.text == "firstsecond")
        #expect(completed.value)
    }

    private static let toolCall = AgentToolCall(id: "probe", name: "text_callback_probe", arguments: [:])

    private func runLoop(
        deltas: [TextStreamDelta],
        buffered: Bool,
        executions: AutomationTestLockedValue<Int>,
        textHandler: @escaping PeekabooAgentService.TextStreamHandler) async throws
        -> PeekabooAgentService.StreamingLoopOutcome
    {
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let provider = TextCallbackProvider(deltas: deltas)
        let model: LanguageModel = buffered ? .openai(.gpt55) : .custom(provider: provider)
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: model,
            sessionManager: store.manager)
        let tool = AgentTool(
            name: Self.toolCall.name,
            description: "Must never execute",
            parameters: AgentToolParameters(properties: [:], required: []),
            execute: { _ in
                executions.withValue { $0 += 1 }
                return AnyAgentToolValue(string: "unexpected")
            })
        let configuration = PeekabooAgentService.StreamingLoopConfiguration(
            model: model,
            provider: provider,
            tools: [tool],
            sessionId: "text-callback-fixture",
            eventHandler: nil,
            textHandler: textHandler,
            enhancementOptions: nil)
        return try await service.runStreamingLoop(
            configuration: configuration, maxSteps: 1, initialMessages: [.user("Do not execute tools.")])
    }
}

private final class TextCallbackProvider: ModelProvider, Sendable {
    let modelId = "text-callback-fixture"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities: ModelCapabilities
    let calls = AutomationTestLockedValue<[String]>([])
    let deltas: [TextStreamDelta]

    init(deltas: [TextStreamDelta], streaming: Bool = true) {
        self.deltas = deltas
        self.capabilities = ModelCapabilities(supportsStreaming: streaming)
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        self.calls.withValue { $0.append("generate") }
        return ProviderResponse(text: "Fallback.", finishReason: .stop)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        self.calls.withValue { $0.append("stream") }
        return AsyncThrowingStream { continuation in
            for delta in self.deltas {
                continuation.yield(delta)
            }
            continuation.finish()
        }
    }
}
