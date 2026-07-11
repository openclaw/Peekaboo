import Foundation
import PeekabooFoundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized, .tags(.safe))
struct PeekabooAgentSessionSafetyTests {
    @Test
    @MainActor
    func `Continuation dry run does not resolve a provider or expose a legacy model name`() async throws {
        let previousConfiguration = TachikomaConfiguration.default
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        let probe = SessionSafetyProviderFactoryProbe()
        configuration.setProviderFactoryOverride { _, _ in
            probe.recordCall()
            throw SessionSafetyTestError.unexpectedProviderResolution
        }
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let sessionStore = try IsolatedAgentSessionStore()
        defer { sessionStore.cleanup() }
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            sessionManager: sessionStore.manager)
        let session = Self.session(
            modelName: "OpenAI-Compatible/private@https://alice:secret@example.test/v1?token=hidden")
        try service.sessionManager.saveSession(session)

        let result = try await service.continueSession(
            sessionId: session.id,
            userMessage: "Continue safely",
            dryRun: true,
            enhancementOptions: nil)

        #expect(result.metadata.modelName == "Saved session model")
        #expect(!result.metadata.modelName.contains("alice"))
        #expect(!result.metadata.modelName.contains("secret"))
        #expect(probe.callCount == 0)
    }

    @Test
    @MainActor
    func `Continuation validation errors omit persisted model descriptions`() throws {
        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = TachikomaConfiguration(loadFromEnvironment: false)
        defer { TachikomaConfiguration.default = previousConfiguration }

        let sessionStore = try IsolatedAgentSessionStore()
        defer { sessionStore.cleanup() }
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            sessionManager: sessionStore.manager)
        let sensitiveName = "OpenAI-Compatible/private@https://alice:secret@example.test/v1?token=hidden"
        let legacySession = Self.session(modelName: sensitiveName)
        let legacyError = #expect(throws: PeekabooError.self) {
            _ = try service.resolveContinuationModel(explicitModel: nil, session: legacySession)
        }
        Self.expectNoSensitiveModelDescription(in: legacyError?.localizedDescription)

        let model = LanguageModel.ollama(.custom("qwen3.5:9b"))
        let identity = service.persistedModelIdentity(for: model)
        let mismatchedSession = Self.session(
            modelName: sensitiveName,
            modelSelection: identity.selection,
            modelEndpointIdentity: identity.endpointIdentity,
            modelProviderIdentity: identity.providerIdentity)
        let mismatchError = #expect(throws: PeekabooError.self) {
            _ = try service.resolveContinuationModel(explicitModel: nil, session: mismatchedSession)
        }
        Self.expectNoSensitiveModelDescription(in: mismatchError?.localizedDescription)
    }

    @Test
    @MainActor
    func `Real continuation activates its resolved model`() async throws {
        let previousConfiguration = TachikomaConfiguration.default
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        let provider = SessionSafetyTerminalProvider()
        configuration.setProviderFactoryOverride { _, _ in provider }
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let sessionStore = try IsolatedAgentSessionStore()
        defer { sessionStore.cleanup() }
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.opus48),
            sessionManager: sessionStore.manager)
        let session = Self.session(modelName: "Legacy model")
        try service.sessionManager.saveSession(session)

        _ = try await service.continueSession(
            sessionId: session.id,
            userMessage: "Finish",
            model: .openai(.gpt55),
            maxSteps: 1,
            enhancementOptions: nil)

        #expect(service.currentModel == .openai(.gpt55))
    }

    @Test
    func `Endpoint identity preserves URL principal and query routing without persisting passwords`() throws {
        let withoutPrincipal = try #require(PeekabooAgentService.canonicalEndpointIdentity(
            "https://example.test/v1"))
        let alicePrincipal = try #require(PeekabooAgentService.canonicalEndpointIdentity(
            "https://alice@example.test/v1"))
        let aliceWithPassword = try #require(PeekabooAgentService.canonicalEndpointIdentity(
            "https://alice:secret@example.test/v1#private"))
        let aliceTenantA = try #require(PeekabooAgentService.canonicalEndpointIdentity(
            "https://alice:secret@example.test/v1?tenant=a"))
        let aliceTenantB = try #require(PeekabooAgentService.canonicalEndpointIdentity(
            "https://alice:other@example.test/v1?tenant=b"))
        let bobPrincipal = try #require(PeekabooAgentService.canonicalEndpointIdentity(
            "https://bob@example.test/v1"))

        #expect(aliceWithPassword == alicePrincipal)
        #expect(aliceTenantA != alicePrincipal)
        #expect(aliceTenantA != aliceTenantB)
        #expect(alicePrincipal != bobPrincipal)
        #expect(alicePrincipal != withoutPrincipal)
        #expect(PeekabooAgentService.canonicalEndpointIdentity("https://other.test/v1") != withoutPrincipal)
        #expect(PeekabooAgentService.canonicalEndpointIdentity("https://example.test/v2") != withoutPrincipal)
    }

    private static func expectNoSensitiveModelDescription(in message: String?) {
        #expect(message?.contains("OpenAI-Compatible/private") == false)
        #expect(message?.contains("alice") == false)
        #expect(message?.contains("secret") == false)
        #expect(message?.contains("hidden") == false)
        #expect(message?.contains("example.test") == false)
    }

    private static func session(
        modelName: String,
        modelSelection: String? = nil,
        modelEndpointIdentity: String? = nil,
        modelProviderIdentity: String? = nil) -> AgentSession
    {
        let now = Date()
        return AgentSession(
            id: "session-safety-\(UUID().uuidString)",
            modelName: modelName,
            modelSelection: modelSelection,
            modelEndpointIdentity: modelEndpointIdentity,
            modelProviderIdentity: modelProviderIdentity,
            messages: [.system("Test system prompt"), .user("Test task")],
            metadata: SessionMetadata(),
            createdAt: now,
            updatedAt: now)
    }
}

private enum SessionSafetyTestError: Error {
    case unexpectedProviderResolution
}

private final class SessionSafetyProviderFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        self.lock.withLock { self.calls }
    }

    func recordCall() {
        self.lock.withLock { self.calls += 1 }
    }
}

private final class SessionSafetyTerminalProvider: ModelProvider, @unchecked Sendable {
    let modelId = "session-safety-terminal"
    let baseURL: String? = "https://example.test/v1"
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(
            text: "",
            finishReason: .toolCalls,
            toolCalls: [
                AgentToolCall(
                    id: "done-call",
                    name: "done",
                    arguments: ["message": AnyAgentToolValue(string: "Finished")]),
            ])
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.done(finishReason: .toolCalls))
            continuation.finish()
        }
    }
}
