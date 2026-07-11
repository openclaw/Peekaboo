import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooAgentStreamingReasoningBoundaryTests {
    @Test
    @MainActor
    func `Streaming reasoning only terminal response is rejected`() async throws {
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

        let loopConfiguration = PeekabooAgentService.StreamingLoopConfiguration(
            model: .anthropic(.opus47),
            provider: provider,
            tools: [],
            sessionId: "reasoning-only-stream-test",
            eventHandler: nil,
            enhancementOptions: nil)
        let thrownError = await #expect(throws: TachikomaError.self) {
            _ = try await agentService.runStreamingLoop(
                configuration: loopConfiguration,
                maxSteps: 1,
                initialMessages: [.user("think only")])
        }

        #expect(thrownError?.localizedDescription.contains("empty terminal response") == true)
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
