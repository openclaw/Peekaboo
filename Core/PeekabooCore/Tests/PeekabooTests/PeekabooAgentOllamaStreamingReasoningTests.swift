import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooAgentOllamaStreamingReasoningTests {
    @Test(arguments: [false, true])
    @MainActor
    func `Ollama thinking replay follows the provider authentication boundary`(_ authenticated: Bool) throws {
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setBaseURL("http://127.0.0.1:11434", for: .ollama)
        if authenticated {
            configuration.setAPIKey("test-key", for: .ollama)
        }

        let model = LanguageModel.ollama(.custom("qwen3:8b"))
        let provider = try OllamaProvider(model: .custom("qwen3:8b"), configuration: configuration)
        let sessionStore = try IsolatedAgentSessionStore()
        defer { sessionStore.cleanup() }
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: model,
            sessionManager: sessionStore.manager)
        var messages: [ModelMessage] = []

        agentService.appendReasoningBlock(
            ProviderReasoningBlock(text: "private thinking", type: "ollama_thinking"),
            model: model,
            configuration: configuration,
            provider: provider,
            to: &messages)

        let customData = try #require(messages.first?.metadata?.customData)
        let sanitized = messages.sanitizedForProviderContext(
            model: model,
            configuration: configuration,
            provider: provider)
        if authenticated {
            #expect(provider.reasoningReplayIdentity == nil)
            #expect(customData["ollama.thinking"] == nil)
            #expect(sanitized.isEmpty)
        } else {
            #expect(customData["ollama.thinking"] == "private thinking")
            #expect(customData["tachikoma.reasoning.base_url"] == provider.reasoningReplayIdentity)
            #expect(sanitized.count == 1)
        }
    }

    @Test
    @MainActor
    func `Streaming Ollama thinking is not replayed to an injected provider`() async throws {
        let provider = StreamingOllamaReasoningReplayProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setBaseURL("http://localhost:11434", for: .ollama)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let model = LanguageModel.ollama(.custom("qwen3:8b"))
        let sessionStore = try IsolatedAgentSessionStore()
        defer { sessionStore.cleanup() }
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: model,
            sessionManager: sessionStore.manager)

        _ = try await agentService.executeTask(
            "Use a tool, then continue.",
            maxSteps: 2,
            model: model,
            eventDelegate: OllamaNoopAgentEventDelegate(),
            enhancementOptions: nil)

        let secondRequestMessages = try #require(provider.secondRequestMessages)
        #expect(!secondRequestMessages.contains { $0.channel == .thinking })
    }
}

private final class StreamingOllamaReasoningReplayProvider: ModelProvider, @unchecked Sendable {
    let modelId = "qwen3:8b"
    let baseURL: String? = "http://localhost:11434"
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let lock = NSLock()
    private var requestCount = 0
    private var capturedSecondRequestMessages: [ModelMessage]?

    var secondRequestMessages: [ModelMessage]? {
        self.lock.withLock { self.capturedSecondRequestMessages }
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(text: "done", finishReason: .stop)
    }

    func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let requestNumber = self.lock.withLock {
            self.requestCount += 1
            if self.requestCount == 2 {
                self.capturedSecondRequestMessages = request.messages
            }
            return self.requestCount
        }

        return AsyncThrowingStream { continuation in
            if requestNumber == 1 {
                continuation.yield(.reasoning("streamed Ollama thinking", type: "ollama_thinking"))
                continuation.yield(.tool(AgentToolCall(
                    id: "missing-tool",
                    name: "missing_test_tool",
                    arguments: [:])))
                continuation.yield(.done(finishReason: .toolCalls))
            } else {
                continuation.yield(.text("done"))
                continuation.yield(.done(finishReason: .stop))
            }
            continuation.finish()
        }
    }
}

@MainActor
private final class OllamaNoopAgentEventDelegate: AgentEventDelegate {
    func agentDidEmitEvent(_: AgentEvent) {}
}
