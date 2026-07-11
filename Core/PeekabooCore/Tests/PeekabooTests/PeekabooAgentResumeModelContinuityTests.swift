import Foundation
import PeekabooFoundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized, .tags(.safe))
struct PeekabooAgentResumeModelContinuityTests {
    @Test
    @MainActor
    func `Resume without override preserves stored Ollama model`() throws {
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))
        let model = LanguageModel.ollama(.custom("qwen3.5:9b"))
        let identity = service.persistedModelIdentity(for: model)
        let session = Self.session(
            modelName: identity.displayName,
            modelSelection: identity.selection,
            modelEndpointIdentity: identity.endpointIdentity,
            modelProviderIdentity: identity.providerIdentity)

        let resolved = try service.resolveContinuationModel(explicitModel: nil, session: session)

        #expect(resolved == .ollama(.custom("qwen3.5:9b")))
    }

    @Test
    @MainActor
    func `Explicit resume model overrides stored selection`() throws {
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))
        let session = Self.session(
            modelName: "Custom/removed-provider/private-model",
            modelSelection: "removed-provider/private-model")

        let resolved = try service.resolveContinuationModel(
            explicitModel: .lmstudio(.gptOSS120B),
            session: session)

        #expect(resolved == .lmstudio(.gptOSS120B))
    }

    @Test
    @MainActor
    func `Legacy Ollama session without endpoint proof fails closed`() throws {
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))
        let session = Self.session(modelName: "Ollama/qwen3.5:9b")

        #expect(throws: PeekabooError.self) {
            _ = try service.resolveContinuationModel(explicitModel: nil, session: session)
        }
    }

    @Test
    @MainActor
    func `Unresolved legacy custom model fails closed`() throws {
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))
        let session = Self.session(modelName: "Custom/removed-provider/private-model")

        let error = #expect(throws: PeekabooError.self) {
            _ = try service.resolveContinuationModel(explicitModel: nil, session: session)
        }

        #expect(error?.localizedDescription.contains("can no longer be verified safely") == true)
        #expect(error?.localizedDescription.contains("explicit model") == true)
    }

    @Test(arguments: [
        LanguageModel.azureOpenAI(
            deployment: "private",
            endpoint: "https://azure.tenant.example"),
        .openaiCompatible(
            modelId: "private",
            baseURL: "https://openai.tenant.example/v1"),
        .anthropicCompatible(
            modelId: "private",
            baseURL: "https://anthropic.tenant.example/v1"),
    ])
    @MainActor
    func `Legacy endpoint-bearing model cannot fall through to current default`(_ legacyModel: LanguageModel) throws {
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))
        let session = Self.session(modelName: legacyModel.description)

        #expect(throws: PeekabooError.self) {
            _ = try service.resolveContinuationModel(explicitModel: nil, session: session)
        }

        let explicit = try service.resolveContinuationModel(
            explicitModel: .ollama(.custom("qwen3.5:9b")),
            session: session)
        #expect(explicit == .ollama(.custom("qwen3.5:9b")))
    }

    @Test
    @MainActor
    func `Unregistered custom model has no implicit persisted selection`() throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let model = LanguageModel.custom(provider: CredentialBearingTestProvider())

        #expect(service.persistedModelSelection(for: model) == nil)
    }

    @Test
    @MainActor
    func `Bare custom model identifier cannot resume as a built in provider`() throws {
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.opus48))
        let customModel = LanguageModel.custom(provider: BareCustomTestProvider())

        #expect(service.persistedModelSelection(for: customModel) == nil)

        let legacySession = Self.session(modelName: "Custom/gpt-5.5")
        #expect(throws: PeekabooError.self) {
            _ = try service.resolveContinuationModel(explicitModel: nil, session: legacySession)
        }

        let invalidPersistedSession = Self.session(
            modelName: "Custom/gpt-5.5",
            modelSelection: "gpt-5.5",
            modelEndpointIdentity: service.currentEndpointIdentity(for: .openai(.gpt55)),
            modelProviderIdentity: "openai")
        #expect(throws: PeekabooError.self) {
            _ = try service.resolveContinuationModel(explicitModel: nil, session: invalidPersistedSession)
        }
    }

    @Test
    @MainActor
    func `Implicit resume rejects Ollama endpoint drift`() throws {
        let originalConfiguration = TachikomaConfiguration.default
        let originalEndpoint = getenv("PEEKABOO_OLLAMA_BASE_URL").map { String(cString: $0) }
        defer {
            TachikomaConfiguration.default = originalConfiguration
            if let originalEndpoint {
                setenv("PEEKABOO_OLLAMA_BASE_URL", originalEndpoint, 1)
            } else {
                unsetenv("PEEKABOO_OLLAMA_BASE_URL")
            }
        }

        let model = LanguageModel.ollama(.custom("qwen3.5:9b"))
        setenv("PEEKABOO_OLLAMA_BASE_URL", "http://127.0.0.1:11434", 1)
        let configurationA = TachikomaConfiguration(loadFromEnvironment: false)
        TachikomaConfiguration.default = configurationA
        let services = PeekabooServices()
        services.configuration.applyAIProviderKeys(to: configurationA)
        let service = try PeekabooAgentService(services: services, defaultModel: model)
        let identity = service.persistedModelIdentity(for: model)
        let session = Self.session(
            modelName: identity.displayName,
            modelSelection: identity.selection,
            modelEndpointIdentity: identity.endpointIdentity,
            modelProviderIdentity: identity.providerIdentity)

        setenv("PEEKABOO_OLLAMA_BASE_URL", "http://127.0.0.1:22434", 1)
        let configurationB = TachikomaConfiguration(loadFromEnvironment: false)
        TachikomaConfiguration.default = configurationB
        services.configuration.applyAIProviderKeys(to: configurationB)
        #expect(identity.endpointIdentity != service.currentEndpointIdentity(for: model))

        #expect(throws: PeekabooError.self) {
            _ = try service.resolveContinuationModel(explicitModel: nil, session: session)
        }
        #expect(try service.resolveContinuationModel(explicitModel: model, session: session) == model)
    }

    @Test
    @MainActor
    func `Prepared session keeps its provider when global configuration changes`() async throws {
        let providerA = CountingContinuityProvider(modelId: "provider-a")
        let providerB = CountingContinuityProvider(modelId: "provider-b")
        let configurationA = TachikomaConfiguration(loadFromEnvironment: false)
        configurationA.setProviderFactoryOverride { _, _ in providerA }
        let configurationB = TachikomaConfiguration(loadFromEnvironment: false)
        configurationB.setProviderFactoryOverride { _, _ in providerB }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configurationA
        defer { TachikomaConfiguration.default = previousConfiguration }

        let model = LanguageModel.openai(.gpt55)
        let service = try PeekabooAgentService(services: PeekabooServices(), defaultModel: model)
        let context = try await service.prepareSession(
            task: "Answer once.",
            model: model,
            label: "provider-continuity-test",
            logBehavior: .verboseOnly)

        TachikomaConfiguration.default = configurationB
        let result = try await service.executeWithoutStreaming(
            context: context,
            model: model,
            maxSteps: 1,
            enhancementOptions: nil)
        try await service.deleteSession(id: context.id)

        #expect(result.content == "provider-a response")
        #expect(providerA.requestCount == 1)
        #expect(providerB.requestCount == 0)
    }

    @Test
    @MainActor
    func `Endpoint credentials never appear in persisted model display`() throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let model = LanguageModel.openaiCompatible(
            modelId: "private-model",
            baseURL: "https://alice:secret@example.test/v1?token=hidden")
        let identity = service.persistedModelIdentity(for: model)
        let session = Self.session(
            modelName: identity.displayName,
            modelSelection: identity.selection,
            modelEndpointIdentity: identity.endpointIdentity,
            modelProviderIdentity: identity.providerIdentity)

        let encoded = try JSONEncoder().encode(session)
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(identity.displayName == "OpenAI-Compatible/private-model")
        #expect(!json.contains("alice"))
        #expect(!json.contains("secret"))
        #expect(!json.contains("hidden"))
        #expect(!json.contains("example.test"))
    }

    @Test
    @MainActor
    func `Nonroundtrippable models have no implicit persisted selection`() throws {
        let service = try PeekabooAgentService(services: PeekabooServices())

        #expect(service.persistedModelSelection(for: .azureOpenAI(deployment: "private")) == nil)
        #expect(service.persistedModelSelection(for: .openaiCompatible(
            modelId: "private",
            baseURL: "https://tenant.example/v1")) == nil)
        #expect(service.persistedModelSelection(for: .anthropicCompatible(
            modelId: "private",
            baseURL: "https://tenant.example/v1")) == nil)
        #expect(service.persistedModelSelection(for: .together(modelId: "private")) == nil)
        #expect(service.persistedModelSelection(for: .replicate(modelId: "private")) == nil)
    }

    @Test
    func `Legacy session JSON decodes without model selection`() throws {
        let session = Self.session(modelName: "Ollama/qwen3.5:9b")
        let encoded = try JSONEncoder().encode(session)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["modelSelection"] == nil)
        #expect(object["modelEndpointIdentity"] == nil)
        #expect(object["modelProviderIdentity"] == nil)

        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)
        #expect(decoded.modelSelection == nil)
        #expect(decoded.modelEndpointIdentity == nil)
        #expect(decoded.modelProviderIdentity == nil)
        #expect(decoded.modelName == session.modelName)
    }

    private static func session(
        modelName: String,
        modelSelection: String? = nil,
        modelEndpointIdentity: String? = nil,
        modelProviderIdentity: String? = nil) -> AgentSession
    {
        let now = Date()
        return AgentSession(
            id: "resume-model-\(UUID().uuidString)",
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

private struct CredentialBearingTestProvider: ModelProvider {
    let modelId = "local-proxy/private-model"
    let baseURL: String? = "http://localhost:1234/v1"
    let apiKey: String? = "test-secret"
    let capabilities = ModelCapabilities()

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(text: "unused", finishReason: .stop)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private struct BareCustomTestProvider: ModelProvider {
    let modelId = "gpt-5.5"
    let baseURL: String? = "http://localhost:1234/v1"
    let apiKey: String? = "test-secret"
    let capabilities = ModelCapabilities()

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(text: "unused", finishReason: .stop)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private final class CountingContinuityProvider: ModelProvider, @unchecked Sendable {
    let modelId: String
    let baseURL: String? = "http://localhost:1234/v1"
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let lock = NSLock()
    private var requests = 0

    init(modelId: String) {
        self.modelId = modelId
    }

    var requestCount: Int {
        self.lock.withLock { self.requests }
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        self.lock.withLock { self.requests += 1 }
        return ProviderResponse(text: "\(self.modelId) response", finishReason: .stop)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
