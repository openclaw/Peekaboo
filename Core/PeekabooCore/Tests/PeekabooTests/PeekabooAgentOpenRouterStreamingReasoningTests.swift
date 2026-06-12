import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooAgentOpenRouterStreamingReasoningTests {
    @Test
    @MainActor
    func `Streaming OpenRouter reasoning is replayed with OpenRouter metadata`() async throws {
        let provider = StreamingOpenRouterReasoningReplayProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openRouter(modelId: "openai/gpt-oss-120b"))

        _ = try await agentService.executeTask(
            "Use a tool, then continue.",
            maxSteps: 2,
            model: .openRouter(modelId: "openai/gpt-oss-120b"),
            eventDelegate: NoopAgentEventDelegate(),
            enhancementOptions: nil)

        let secondRequestMessages = try #require(provider.secondRequestMessages)
        let reasoningMessage = try #require(secondRequestMessages.first { message in
            message.channel == .thinking
        })
        let customData = reasoningMessage.metadata?.customData ?? [:]

        #expect(reasoningMessage.content == [.text("streamed openrouter thinking")])
        #expect(customData["openrouter.reasoning"] == "streamed openrouter thinking")
        #expect(customData["anthropic.thinking.type"] == nil)
        #expect(customData["tachikoma.reasoning.provider"] == "openrouter")
        #expect(customData["tachikoma.reasoning.model"] == "openai/gpt-oss-120b")
        #expect(customData["tachikoma.reasoning.base_url"] != nil)
    }
}

private final class StreamingOpenRouterReasoningReplayProvider: ModelProvider, @unchecked Sendable {
    let modelId = "streaming-openrouter-reasoning-replay-provider"
    let baseURL: String? = nil
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
                continuation.yield(.reasoning("streamed openrouter thinking", type: "openrouter_reasoning"))
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
private final class NoopAgentEventDelegate: AgentEventDelegate {
    func agentDidEmitEvent(_: AgentEvent) {}
}
