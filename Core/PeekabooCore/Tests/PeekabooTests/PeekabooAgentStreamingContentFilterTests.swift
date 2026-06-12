import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooAgentStreamingContentFilterTests {
    @Test
    @MainActor
    func `Buffered provider content filter does not emit blocked reasoning text`() async throws {
        let provider = ReasoningContentFilterProvider(reasoning: "blocked private reasoning")
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let delegate = CapturingReasoningEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        await #expect(throws: (any Error).self) {
            _ = try await agentService.executeTask(
                "trigger filter",
                maxSteps: 1,
                model: .openai(.gpt55),
                eventDelegate: delegate,
                enhancementOptions: nil)
        }

        #expect(!delegate.events.containsThinkingMessage("blocked private reasoning"))
    }

    @Test
    @MainActor
    func `Anthropic buffering is limited to refusal-risk models`() throws {
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.opus48))

        #expect(agentService.buffersAgentTextStreamUntilDone(for: .anthropic(.fable5)))
        #expect(agentService.buffersAgentTextStreamUntilDone(for: .anthropic(.opus48)))
        #expect(!agentService.buffersAgentTextStreamUntilDone(for: .anthropic(.opus47)))
        #expect(!agentService.buffersAgentTextStreamUntilDone(for: .anthropic(.sonnet46)))
    }

    @Test
    @MainActor
    func `Anthropic compatible buffering follows model risk`() throws {
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.opus48))

        #expect(agentService.buffersAgentTextStreamUntilDone(for: .anthropicCompatible(
            modelId: "claude-opus-4-8",
            baseURL: "https://custom.anthropic.example/v1")))
        #expect(!agentService.buffersAgentTextStreamUntilDone(for: .anthropicCompatible(
            modelId: "claude-opus-4-7",
            baseURL: "https://custom.anthropic.example/v1")))
    }

    @Test
    @MainActor
    func `Custom Anthropic buffering follows model risk`() throws {
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.opus48))

        let opus48Provider = ReasoningContentFilterProvider(
            modelId: "claude-opus-4-8",
            reasoning: "blocked custom reasoning")
        let opus47Provider = ReasoningContentFilterProvider(
            modelId: "claude-opus-4-7",
            reasoning: "safe custom reasoning")

        #expect(agentService.buffersAgentTextStreamUntilDone(for: .custom(provider: opus48Provider)))
        #expect(!agentService.buffersAgentTextStreamUntilDone(for: .custom(provider: opus47Provider)))
    }

    @Test
    @MainActor
    func `Buffered provider missing terminal event does not emit partial output`() async throws {
        let provider = TruncatedBufferedProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let delegate = CapturingReasoningEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        await #expect(throws: (any Error).self) {
            _ = try await agentService.executeTask(
                "trigger truncated stream",
                maxSteps: 1,
                model: .openai(.gpt55),
                eventDelegate: delegate,
                enhancementOptions: nil)
        }

        #expect(!delegate.events.containsAssistantMessage("partial assistant text"))
        #expect(delegate.events.firstToolStart(named: "missing_test_tool") == nil)
    }

    @Test
    @MainActor
    func `Buffered provider nil finish reason still flushes terminal stream`() async throws {
        let provider = NilFinishBufferedProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let delegate = CapturingReasoningEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        let response = try await agentService.executeTask(
            "trigger nil finish stream",
            maxSteps: 1,
            model: .openai(.gpt55),
            eventDelegate: delegate,
            enhancementOptions: nil)

        #expect(response.content == "assistant text")
        #expect(delegate.events.containsAssistantMessage("assistant text"))
        #expect(delegate.events.firstToolStart(named: "terminal_test_tool") != nil)
    }
}

private final class ReasoningContentFilterProvider: ModelProvider, @unchecked Sendable {
    let modelId: String
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()
    private let reasoning: String

    init(modelId: String = "reasoning-content-filter-provider", reasoning: String) {
        self.modelId = modelId
        self.reasoning = reasoning
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(
            text: "blocked partial text",
            finishReason: .contentFilter)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.reasoning(self.reasoning))
            continuation.yield(.text("blocked partial text"))
            continuation.yield(.done(finishReason: .contentFilter))
            continuation.finish()
        }
    }
}

private final class TruncatedBufferedProvider: ModelProvider, @unchecked Sendable {
    let modelId = "truncated-buffered-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(text: "partial assistant text", finishReason: nil)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("partial assistant text"))
            continuation.yield(.tool(AgentToolCall(
                id: "truncated-tool",
                name: "missing_test_tool",
                arguments: [:])))
            continuation.finish()
        }
    }
}

private final class NilFinishBufferedProvider: ModelProvider, @unchecked Sendable {
    let modelId = "nil-finish-buffered-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(text: "assistant text", finishReason: nil)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("assistant text"))
            continuation.yield(.tool(AgentToolCall(
                id: "terminal-tool",
                name: "terminal_test_tool",
                arguments: [:])))
            continuation.yield(.done(finishReason: nil))
            continuation.finish()
        }
    }
}

@MainActor
private final class CapturingReasoningEventDelegate: AgentEventDelegate {
    private(set) var events: [AgentEvent] = []

    func agentDidEmitEvent(_ event: AgentEvent) {
        self.events.append(event)
    }
}

extension [AgentEvent] {
    fileprivate func containsAssistantMessage(_ expected: String) -> Bool {
        self.contains { event in
            if case let .assistantMessage(content) = event {
                return content == expected
            }
            return false
        }
    }

    fileprivate func containsThinkingMessage(_ expected: String) -> Bool {
        self.contains { event in
            if case let .thinkingMessage(content) = event {
                return content == expected
            }
            return false
        }
    }

    fileprivate func firstToolStart(named expected: String) -> Int? {
        self.firstIndex { event in
            if case let .toolCallStarted(name, _) = event {
                return name == expected
            }
            return false
        }
    }
}
