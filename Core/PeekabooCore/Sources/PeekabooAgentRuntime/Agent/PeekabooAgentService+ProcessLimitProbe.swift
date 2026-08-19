#if DEBUG
import Foundation
import Tachikoma

final class AgentProcessLimitProbeProvider: ModelProvider, @unchecked Sendable {
    let modelId = "agent-process-limit-probe"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()
    private let lock = NSLock()
    private var nextIndex = 0

    func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        let index = self.lock.withLock {
            defer { self.nextIndex += 1 }
            return self.nextIndex
        }
        if index == 0 {
            return ProviderResponse(
                text: "",
                finishReason: .toolCalls,
                toolCalls: [
                    AgentToolCall(
                        id: "app-list-probe",
                        name: "app",
                        arguments: ["action": AnyAgentToolValue(string: "list")]),
                ])
        }
        return ProviderResponse(
            text: Self.completionContent(request.messages),
            finishReason: .stop)
    }

    func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let response = try await self.generateText(request: request)
        return AsyncThrowingStream { continuation in
            if !response.text.isEmpty {
                continuation.yield(.text(response.text))
            }
            for toolCall in response.toolCalls ?? [] {
                continuation.yield(.tool(toolCall))
            }
            continuation.yield(.done(finishReason: response.finishReason))
            continuation.finish()
        }
    }

    private static func completionContent(_ messages: [ModelMessage]) -> String {
        for message in messages.reversed() {
            for part in message.content.reversed() {
                guard case let .toolResult(result) = part else { continue }
                let payload = (try? result.result.toJSON()).map { String(describing: $0) } ?? "unreadable"
                guard !result.isError, payload.contains("BridgeFixture") else {
                    return "agent-provider-tool-error:\(payload)"
                }
                return "agent-provider-tool-ok"
            }
        }
        return "agent-provider-tool-error:missing-result"
    }
}
#endif
