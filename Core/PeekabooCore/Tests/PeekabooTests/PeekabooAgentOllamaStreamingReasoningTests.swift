import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooAgentOllamaStreamingReasoningTests {
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
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: model)

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
