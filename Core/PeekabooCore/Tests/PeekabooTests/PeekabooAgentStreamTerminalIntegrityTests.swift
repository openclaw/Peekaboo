import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized, .tags(.safe))
@MainActor
struct PeekabooAgentStreamTerminalIntegrityTests {
    @Test
    func `Tool call after terminal event is rejected without execution or lifecycle events`() async throws {
        let model = LanguageModel.anthropic(.opus47)
        let toolCall = AgentToolCall(id: "late-call", name: "late-tool", arguments: [:])
        let provider = PostTerminalDeltaProvider(toolCall: toolCall)
        let probe = PostTerminalToolProbe()
        let sessionStore = try IsolatedAgentSessionStore()
        defer { sessionStore.cleanup() }
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: model,
            sessionManager: sessionStore.manager)
        let tool = AgentTool(
            name: toolCall.name,
            description: "Must not execute",
            parameters: AgentToolParameters(properties: [:], required: []),
            execute: { _ in
                await probe.recordExecution()
                return AnyAgentToolValue(string: "unexpected")
            })
        let configuration = PeekabooAgentService.StreamingLoopConfiguration(
            model: model,
            provider: provider,
            tools: [tool],
            sessionId: "post-terminal-stream-test",
            eventHandler: EventHandler { event in await probe.record(event) },
            enhancementOptions: nil)

        let error = await #expect(throws: TachikomaError.self) {
            _ = try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 1,
                initialMessages: [.user("Do not run a post-terminal tool call.")])
        }

        #expect(error?.localizedDescription.contains("after its terminal event") == true)
        let snapshot = await probe.snapshot()
        #expect(snapshot.executionCount == 0)
        #expect(snapshot.toolEventCount == 0)
    }
}

private final class PostTerminalDeltaProvider: ModelProvider, @unchecked Sendable {
    let modelId = "post-terminal-delta-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let toolCall: AgentToolCall

    init(toolCall: AgentToolCall) {
        self.toolCall = toolCall
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(text: "unused", finishReason: .stop)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.done(finishReason: .stop))
            continuation.yield(.tool(self.toolCall))
            continuation.finish()
        }
    }
}

private actor PostTerminalToolProbe {
    private var executionCount = 0
    private var toolEventCount = 0

    func recordExecution() {
        self.executionCount += 1
    }

    func record(_ event: AgentEvent) {
        switch event {
        case .toolCallStarted, .toolCallUpdated, .toolCallCompleted:
            self.toolEventCount += 1
        default:
            break
        }
    }

    func snapshot() -> (executionCount: Int, toolEventCount: Int) {
        (self.executionCount, self.toolEventCount)
    }
}
