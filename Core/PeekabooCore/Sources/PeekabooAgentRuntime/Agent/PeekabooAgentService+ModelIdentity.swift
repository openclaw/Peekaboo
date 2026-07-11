import CryptoKit
import Foundation
import PeekabooAutomation
import PeekabooFoundation
import Tachikoma

@available(macOS 14.0, *)
extension PeekabooAgentService {
    struct PersistedModelIdentity: Equatable {
        let displayName: String
        let selection: String?
        let endpointIdentity: String?
        let providerIdentity: String?
    }

    func persistedModelIdentity(for model: LanguageModel) -> PersistedModelIdentity {
        let configuration = TachikomaConfiguration.resolve(.current)
        guard let provider = try? configuration.makeProvider(for: model) else {
            return PersistedModelIdentity(
                displayName: self.safeModelDisplayName(for: model),
                selection: nil,
                endpointIdentity: nil,
                providerIdentity: nil)
        }
        return self.persistedModelIdentity(for: model, provider: provider)
    }

    func persistedModelIdentity(
        for model: LanguageModel,
        provider: any ModelProvider) -> PersistedModelIdentity
    {
        let displayName = self.safeModelDisplayName(for: model)
        let endpointIdentity = Self.canonicalEndpointIdentity(provider.baseURL)
        let providerIdentity = self.modelProviderIdentity(for: model, provider: provider)
        guard let selection = self.persistedModelSelection(for: model),
              endpointIdentity != nil,
              providerIdentity != nil
        else {
            return PersistedModelIdentity(
                displayName: displayName,
                selection: nil,
                endpointIdentity: endpointIdentity,
                providerIdentity: providerIdentity)
        }

        return PersistedModelIdentity(
            displayName: displayName,
            selection: selection,
            endpointIdentity: endpointIdentity,
            providerIdentity: providerIdentity)
    }

    func currentEndpointIdentity(for model: LanguageModel) -> String? {
        let configuration = TachikomaConfiguration.resolve(.current)
        guard let provider = try? configuration.makeProvider(for: model) else {
            return nil
        }
        return Self.canonicalEndpointIdentity(provider.baseURL)
    }

    func safeModelDisplayName(for model: LanguageModel) -> String {
        switch model {
        case let .azureOpenAI(deployment, _, _, _):
            "AzureOpenAI/\(deployment)"
        case let .openaiCompatible(modelID, _):
            "OpenAI-Compatible/\(modelID)"
        case let .anthropicCompatible(modelID, _):
            "Anthropic-Compatible/\(modelID)"
        default:
            model.description
        }
    }

    func modelProviderIdentity(for model: LanguageModel) -> String? {
        let configuration = TachikomaConfiguration.resolve(.current)
        guard let provider = try? configuration.makeProvider(for: model) else { return nil }
        return self.modelProviderIdentity(for: model, provider: provider)
    }

    func modelProviderIdentity(
        for model: LanguageModel,
        provider: any ModelProvider) -> String?
    {
        guard self.providerMatchesModel(model, provider: provider) else { return nil }

        if case let .custom(configuredModel) = model {
            guard let configuredProvider = configuredModel as? any PeekabooCustomProviderIdentityProviding
            else {
                return nil
            }
            return "custom:\(configuredProvider.providerTypeIdentity)"
        }

        return self.builtInProviderIdentity(for: model, provider: provider)
    }

    private func builtInProviderIdentity(
        for model: LanguageModel,
        provider: any ModelProvider) -> String?
    {
        switch model {
        case .openai where provider is OpenAIResponsesProvider: "openai:responses"
        case .openai: "openai:chat"
        case .anthropic: "anthropic"
        case .google: "google"
        case .mistral: "mistral"
        case .groq: "groq"
        case .grok: "grok"
        case .ollama: "ollama"
        case .lmstudio: "lmstudio"
        case .minimax: "minimax"
        case .minimaxCN: "minimax-cn"
        case .kimi: "kimi"
        case .azureOpenAI: "azure-openai"
        case .openRouter: "openrouter"
        case .together: "together"
        case .replicate: "replicate"
        case .openaiCompatible: "openai-compatible"
        case .anthropicCompatible: "anthropic-compatible"
        case .custom: nil
        }
    }

    private func providerMatchesModel(
        _ model: LanguageModel,
        provider: any ModelProvider) -> Bool
    {
        switch model {
        case .openai:
            return provider is OpenAIProvider || provider is OpenAIResponsesProvider
        case .anthropic: return provider is AnthropicProvider
        case .google: return provider is GoogleProvider
        case .mistral: return provider is MistralProvider
        case .groq: return provider is GroqProvider
        case .grok: return provider is GrokProvider
        case .ollama: return provider is OllamaProvider
        case .lmstudio: return provider is LMStudioProvider
        case .minimax, .minimaxCN: return provider is AnthropicCompatibleProvider
        case .kimi: return provider is KimiProvider
        case .azureOpenAI: return provider is AzureOpenAIProvider
        case .openRouter: return provider is OpenRouterProvider
        case .together: return provider is TogetherProvider
        case .replicate: return provider is ReplicateProvider
        case .openaiCompatible: return provider is OpenAICompatibleProvider
        case .anthropicCompatible: return provider is AnthropicCompatibleProvider
        case let .custom(configuredModel):
            guard
                let expected = configuredModel as? any PeekabooCustomProviderIdentityProviding,
                let actual = provider as? any PeekabooCustomProviderIdentityProviding
            else {
                return false
            }
            return expected.providerID == actual.providerID &&
                expected.resolvedModelID == actual.resolvedModelID &&
                expected.providerTypeIdentity == actual.providerTypeIdentity
        }
    }

    nonisolated static func canonicalEndpointIdentity(_ rawValue: String?) -> String? {
        guard
            let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased()
        else {
            return nil
        }

        components.scheme = scheme
        components.host = host
        components.password = nil
        components.fragment = nil
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        guard let value = components.string, let data = value.data(using: .utf8) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }
}
