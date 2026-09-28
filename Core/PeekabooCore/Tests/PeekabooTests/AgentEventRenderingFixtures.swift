import Foundation
import PeekabooAutomationKitTestSupport
import Tachikoma
@testable import PeekabooAgentRuntime

enum EventRenderingTerminal: CaseIterable, Sendable {
    case success, failure, cancellation
}

enum EventRenderingFailure: Error {
    case expected
}

@MainActor
final class EventRenderingDelegate: AgentEventDelegate {
    let interested: Bool
    private(set) var interestReads = 0
    private(set) var events: [AgentEvent] = []

    init(interested: Bool) {
        self.interested = interested
    }

    var receivesAgentEvents: Bool {
        self.interestReads += 1
        return self.interested
    }

    func agentDidEmitEvent(_ event: AgentEvent) {
        self.events.append(event)
    }
}

@MainActor
final class DefaultEventRenderingDelegate: AgentEventDelegate {
    func agentDidEmitEvent(_: AgentEvent) {}
}

struct EventRenderingRequest: Sendable {
    let method: String
    let request: ProviderRequest
}

final class EventRenderingProvider: ModelProvider, Sendable {
    let modelId = "event-rendering-fixture"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities: ModelCapabilities
    let requests = AutomationTestLockedValue<[EventRenderingRequest]>([])
    let terminal = AutomationTestLockedValue(EventRenderingTerminal.success)
    private let usesTool: Bool

    init(streaming: Bool = true, usesTool: Bool = true) {
        self.capabilities = ModelCapabilities(supportsStreaming: streaming)
        self.usesTool = usesTool
    }

    static func call(text: String = "latest-value") -> AgentToolCall {
        AgentToolCall(id: "event-rendering-call", name: "event_rendering_fixture", arguments: [
            "text": AnyAgentToolValue(string: text),
            "password": AnyAgentToolValue(string: "synthetic-preview-secret"),
        ])
    }

    func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        try self.response(request: request, method: "generate")
    }

    func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let response = try self.response(request: request, method: "stream")
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(response.text))
            if let call = response.toolCalls?.first {
                continuation.yield(.reasoning("synthetic reasoning", signature: "fixture-signature", type: "thinking"))
                continuation.yield(.tool(Self.call(text: "earlier-value")))
                continuation.yield(.tool(call))
            }
            continuation.yield(.done(usage: response.usage, finishReason: response.finishReason))
            continuation.finish()
        }
    }

    private func response(request: ProviderRequest, method: String) throws -> ProviderResponse {
        let index = self.requests.withValue { requests in
            let index = requests.count
            requests.append(EventRenderingRequest(method: method, request: request))
            return index
        }
        switch self.terminal.value {
        case .failure: throw EventRenderingFailure.expected
        case .cancellation: throw CancellationError()
        case .success: break
        }
        if self.usesTool, index == 0 {
            return ProviderResponse(
                text: "I'll inspect the synthetic result.",
                usage: Usage(inputTokens: 11, outputTokens: 7),
                finishReason: .toolCalls,
                toolCalls: [Self.call()])
        }
        return ProviderResponse(
            text: "Finished.",
            usage: Usage(inputTokens: 13, outputTokens: 5),
            finishReason: .stop)
    }
}

extension AgentEvent {
    var renderingTestKind: String {
        switch self {
        case .started: "started"
        case .assistantMessage: "assistant"
        case .thinkingMessage: "thinking"
        case .toolCallStarted: "tool-start"
        case .toolCallUpdated: "tool-update"
        case .toolCallCompleted: "tool-completed"
        case .verificationCompleted: "verification"
        case .desktopContextRefreshed: "context"
        case .error: "error"
        case .completed: "completed"
        case .queueDrained: "queue-drained"
        }
    }
}
