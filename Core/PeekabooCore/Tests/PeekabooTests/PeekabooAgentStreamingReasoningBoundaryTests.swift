import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooAgentStreamingReasoningBoundaryTests {
    @Test
    @MainActor
    func `Streaming native reasoning only response records assistant boundary`() async throws {
        let provider = StreamingReasoningOnlyProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.opus47))

        let result = try await agentService.executeTaskStreaming(
            "think only",
            model: .anthropic(.opus47)) { _ in }

        let thinkingIndex = try #require(result.messages.firstIndex { $0.channel == .thinking })
        let boundaryMessage = try #require(result.messages.dropFirst(thinkingIndex + 1).first)

        #expect(boundaryMessage.role == .assistant)
        #expect(boundaryMessage.content == [.text("")])
        #expect(boundaryMessage.metadata?.customData?["tachikoma.internal.boundary"] == "reasoning_only")
    }

    @Test
    @MainActor
    func `Streaming reasoning clears signature-first block before next pending block`() async throws {
        let stream = AsyncThrowingStream<TextStreamDelta, any Error> { continuation in
            continuation.yield(.reasoning("", signature: "sig-first", type: "thinking"))
            continuation.yield(.reasoning("first", type: "thinking"))
            continuation.yield(.reasoning("second", type: "thinking"))
            continuation.yield(.reasoning("", signature: "sig-second", type: "thinking"))
            continuation.yield(.done(finishReason: .stop))
            continuation.finish()
        }
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.opus47))

        let output = try await agentService.collectStreamOutput(
            from: StreamTextResult(
                stream: stream,
                model: .anthropic(.opus47),
                settings: GenerationSettings()),
            model: .anthropic(.opus47),
            eventHandler: nil,
            stepIndex: 0)

        #expect(output.reasoningBlocks.count == 2)
        #expect(output.reasoningBlocks.first?.text == "first")
        #expect(output.reasoningBlocks.first?.signature == "sig-first")
        #expect(output.reasoningBlocks.dropFirst().first?.text == "second")
        #expect(output.reasoningBlocks.dropFirst().first?.signature == "sig-second")
    }
}

private final class StreamingReasoningOnlyProvider: ModelProvider, @unchecked Sendable {
    let modelId = "streaming-reasoning-only-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(text: "", finishReason: .stop)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.reasoning("streamed native thinking", signature: "sig-native-stream", type: "thinking"))
            continuation.yield(.done(finishReason: .stop))
            continuation.finish()
        }
    }
}
