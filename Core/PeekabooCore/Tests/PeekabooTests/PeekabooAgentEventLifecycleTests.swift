import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooAgentEventLifecycleTests {
    @Test
    @MainActor
    func `Failure drains tool completion before terminal error`() async throws {
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in EventLifecycleToolProvider() }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = EventLifecycleDelegate()
        let sessionStore = try IsolatedAgentSessionStore()
        defer { sessionStore.cleanup() }
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55),
            sessionManager: sessionStore.manager)

        let thrownError = await #expect(throws: PeekabooAgentService.AgentStepLimitExceededError.self) {
            _ = try await agentService.executeTask(
                "Use the unavailable tool.",
                maxSteps: 1,
                model: .openai(.gpt55),
                eventDelegate: delegate,
                enhancementOptions: nil)
        }
        let error = try #require(thrownError)

        let completionIndex = try #require(delegate.events.firstIndex { event in
            if case .toolCallCompleted = event {
                true
            } else {
                false
            }
        })
        let errorIndex = try #require(delegate.events.firstIndex { event in
            if case .error = event {
                true
            } else {
                false
            }
        })
        #expect(completionIndex < errorIndex)
        #expect(delegate.events.contains { event in
            if case let .error(message) = event {
                message.contains("1-step limit")
            } else {
                false
            }
        })
        #expect(!delegate.events.contains { event in
            if case .completed = event {
                true
            } else {
                false
            }
        })

        try await agentService.deleteSession(id: error.sessionId)
    }

    @Test
    @MainActor
    func `Cancellation drains events without emitting a failure`() async throws {
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in EventLifecycleCancellationProvider() }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = EventLifecycleDelegate()
        let sessionStore = try IsolatedAgentSessionStore()
        defer { sessionStore.cleanup() }
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55),
            sessionManager: sessionStore.manager)

        await #expect(throws: CancellationError.self) {
            _ = try await agentService.executeTask(
                "Cancel this run.",
                maxSteps: 1,
                model: .openai(.gpt55),
                eventDelegate: delegate,
                enhancementOptions: nil)
        }

        #expect(delegate.events.contains { event in
            if case .started = event {
                true
            } else {
                false
            }
        })
        #expect(!delegate.events.contains { event in
            if case .error = event {
                true
            } else {
                false
            }
        })
        #expect(!delegate.events.contains { event in
            if case .completed = event {
                true
            } else {
                false
            }
        })
    }
}

private final class EventLifecycleToolProvider: ModelProvider, @unchecked Sendable {
    let modelId = "event-lifecycle-tool-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(text: "", finishReason: .toolCalls, toolCalls: [self.toolCall])
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.tool(self.toolCall))
            continuation.yield(.done(finishReason: .toolCalls))
            continuation.finish()
        }
    }

    private var toolCall: AgentToolCall {
        AgentToolCall(id: "missing-tool-call", name: "missing_event_lifecycle_tool", arguments: [:])
    }
}

private final class EventLifecycleCancellationProvider: ModelProvider, @unchecked Sendable {
    let modelId = "event-lifecycle-cancellation-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        throw CancellationError()
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: CancellationError())
        }
    }
}

@MainActor
private final class EventLifecycleDelegate: AgentEventDelegate {
    private(set) var events: [AgentEvent] = []

    func agentDidEmitEvent(_ event: AgentEvent) {
        self.events.append(event)
    }
}
