import Foundation
import PeekabooCore
import PeekabooFoundation
import Tachikoma

@available(macOS 14.0, *)
extension AgentCommand {
    @MainActor
    func parseModelString(
        _ modelString: String,
        configuration: PeekabooCore.ConfigurationManager? = nil
    ) -> LanguageModel? {
        let trimmed = modelString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let explicitProvider = trimmed
            .split(separator: "/", maxSplits: 1)
            .first
            .map { String($0).lowercased() }

        if trimmed.caseInsensitiveCompare("claude") == .orderedSame ||
            trimmed.caseInsensitiveCompare("anthropic") == .orderedSame {
            return .anthropic(.opus48)
        }
        if trimmed.caseInsensitiveCompare("sonnet") == .orderedSame {
            return .anthropic(.sonnet5)
        }

        if let configuration {
            switch self.parseConfiguredCustomModel(
                trimmed,
                explicitProvider: explicitProvider,
                configuration: configuration
            ) {
            case let .resolved(model):
                return model
            case .unresolved:
                break
            }
        }

        guard let parsed = LanguageModel.parse(from: trimmed) else {
            return nil
        }

        return self.supportedParsedModel(parsed, explicitProvider: explicitProvider)
    }

    @MainActor
    private func supportedParsedModel(_ parsed: LanguageModel, explicitProvider: String?) -> LanguageModel? {
        switch parsed {
        case let .openai(model):
            if Self.supportedOpenAIInputs.contains(model) {
                if Self.gpt56Models.contains(model) {
                    return .openai(model)
                }
                return .openai(.gpt55)
            }
        case let .anthropic(model):
            if Self.supportedAnthropicInputs.contains(model) {
                return .anthropic(model)
            }
        case let .google(model):
            if Self.supportedGoogleInputs.contains(model) {
                return .google(model)
            }
        case .grok:
            return parsed.supportsTools ? parsed : nil
        case let .minimax(model):
            if Self.supportedMiniMaxInputs.contains(model) {
                return .minimax(model)
            }
        case let .minimaxCN(model):
            if Self.supportedMiniMaxInputs.contains(model) {
                return .minimaxCN(model)
            }
        case let .kimi(model):
            if Self.supportedKimiInputs.contains(model) {
                return .kimi(model)
            }
        case .ollama, .lmstudio:
            return parsed.supportsTools ? parsed : nil
        case .openRouter:
            if let explicitProvider, Self.reservedProviderInputs.contains(explicitProvider) {
                return nil
            }
            return parsed.supportsTools ? parsed : nil
        default:
            break
        }

        return nil
    }

    @MainActor
    private func parseConfiguredCustomModel(
        _ modelString: String,
        explicitProvider: String?,
        configuration: PeekabooCore.ConfigurationManager
    ) -> ConfiguredModelResolution {
        if let configuredModel = PeekabooAIService(configuration: configuration).resolveConfiguredModel(modelString),
           case .custom = configuredModel {
            return .resolved(configuredModel.supportsTools ? configuredModel : nil)
        }

        if let explicitProvider,
           configuration.listCustomProviders().contains(where: { providerID, provider in
               provider.enabled && providerID.caseInsensitiveCompare(explicitProvider) == .orderedSame
           }) {
            return .resolved(nil)
        }

        return .unresolved
    }

    private enum ConfiguredModelResolution {
        case resolved(LanguageModel?)
        case unresolved
    }

    @MainActor
    func validatedModelSelection(configuration: PeekabooCore.ConfigurationManager? = nil) throws -> LanguageModel? {
        guard let modelString = self.model else { return nil }
        guard let parsed = self.parseModelString(modelString, configuration: configuration) else {
            throw PeekabooError.invalidInput(
                "Unsupported model '\(modelString)'. Allowed values: \(Self.allowedModelList)"
            )
        }
        return parsed
    }

    private static let supportedOpenAIInputs: Set<LanguageModel.OpenAI> = [
        .gpt56Sol,
        .gpt56Terra,
        .gpt56Luna,
        .gpt55,
        .gpt54,
        .gpt54Mini,
        .gpt54Nano,
        .gpt5,
        .gpt5Pro,
        .gpt5Mini,
        .gpt5Nano,
    ]

    private static let gpt56Models: Set<LanguageModel.OpenAI> = [
        .gpt56Sol,
        .gpt56Terra,
        .gpt56Luna,
    ]

    private static let supportedAnthropicInputs: Set<LanguageModel.Anthropic> = [
        .fable5,
        .sonnet5,
        .opus48,
        .opus47,
        .opus45,
        .opus4,
        .sonnet46,
        .sonnet45,
        .haiku45,
    ]

    private static let supportedGoogleInputs: Set<LanguageModel.Google> = [
        .gemini35Flash,
        .gemini31ProPreview,
        .gemini31FlashLite,
        .gemini3Flash,
        .gemini25Pro,
        .gemini25Flash,
        .gemini25FlashLite,
    ]

    private static let supportedMiniMaxInputs: Set<LanguageModel.MiniMax> = [
        .m27,
        .m27Highspeed,
        .m3,
    ]

    private static let supportedKimiInputs: Set<LanguageModel.Kimi> = [
        .k26,
        .k27Code,
        .k27CodeHighspeed,
    ]

    private static let reservedProviderInputs: Set<String> = [
        "openai",
        "anthropic",
        "google",
        "gemini",
        "grok",
        "xai",
        "minimax",
        "minimax-cn",
        "minimax_cn",
        "minimaxi",
        "kimi",
        "moonshot",
        "ollama",
        "lmstudio",
        "lm-studio",
    ]

    private static var allowedModelList: String {
        let openAIModels = Self.supportedOpenAIInputs.map(\.modelId)
        let anthropicModels = Self.supportedAnthropicInputs.map(\.modelId)
        let googleModels = Self.supportedGoogleInputs.map(\.userFacingModelId)
        let miniMaxModels = Self.supportedMiniMaxInputs.map(\.modelId)
        let kimiModels = Self.supportedKimiInputs.map(\.modelId)
        return (openAIModels + anthropicModels + googleModels + miniMaxModels + kimiModels + [
            "grok/<model>",
            "xai/<model>",
            "minimax-cn/<model>",
            "kimi/<model>",
            "ollama/<model>",
            "lmstudio/<model>",
            "openrouter/<provider>/<model>",
            "<custom-provider>/<model>",
        ])
        .sorted()
        .joined(separator: ", ")
    }

    @MainActor
    func firstAvailableToolModel(from service: PeekabooAIService) -> LanguageModel? {
        service.availableModels().first { model in
            model.supportsTools && service.isModelAvailable(model)
        }
    }

    @MainActor
    func configuredDefaultToolModel(
        from service: PeekabooAIService,
        configuration: PeekabooCore.ConfigurationManager
    ) -> LanguageModel? {
        guard let defaultModel = configuration.getAgentModel(),
              let model = service.resolveConfiguredModel(defaultModel),
              model.supportsTools,
              service.isModelAvailable(model)
        else {
            return nil
        }
        return model
    }

    @MainActor
    func implicitToolModel(
        from service: PeekabooAIService,
        configuration: PeekabooCore.ConfigurationManager,
        existingAgentModel: LanguageModel?
    ) -> LanguageModel? {
        if let existingAgentModel {
            return existingAgentModel
        }

        if configuration.hasExplicitAIProviderList() {
            return nil
        }

        return self.configuredDefaultToolModel(from: service, configuration: configuration) ??
            self.firstAvailableToolModel(from: service)
    }

    @MainActor
    func hasCredentials(for model: LanguageModel) -> Bool {
        let configuration = self.services.configuration
        switch model {
        case .ollama, .lmstudio:
            return true
        case .openai:
            return configuration.hasOpenAIAuth()
        case .anthropic:
            return configuration.hasAnthropicAuth()
        case .google:
            return configuration.getGeminiAPIKey()?.isEmpty == false
        case .minimax:
            return configuration.getMiniMaxAPIKey()?.isEmpty == false
        case .minimaxCN:
            return configuration.getMiniMaxChinaAPIKey()?.isEmpty == false
        case .kimi:
            return configuration.getKimiAPIKey()?.isEmpty == false
        case .grok:
            return configuration.getGrokAPIKey()?.isEmpty == false
        case .openRouter:
            return configuration.getOpenRouterAPIKey()?.isEmpty == false
        case let .custom(provider):
            return provider.apiKey?.isEmpty == false
        default:
            return false
        }
    }

    func providerDisplayName(for model: LanguageModel) -> String {
        switch model {
        case .openai:
            "OpenAI"
        case .anthropic:
            "Anthropic"
        case .google:
            "Google"
        case .minimax:
            "MiniMax"
        case .minimaxCN:
            "MiniMax China"
        case .kimi:
            "Kimi"
        case .ollama:
            "Ollama"
        case .lmstudio:
            "LM Studio"
        case .openRouter:
            "OpenRouter"
        case .grok:
            "xAI"
        case let .custom(provider):
            "custom provider \(provider.modelId)"
        default:
            "the selected provider"
        }
    }

    func providerEnvironmentVariable(for model: LanguageModel) -> String {
        switch model {
        case .openai:
            "OPENAI_API_KEY"
        case .anthropic:
            "ANTHROPIC_API_KEY"
        case .google:
            "GEMINI_API_KEY"
        case .minimax:
            "MINIMAX_API_KEY"
        case .minimaxCN:
            "MINIMAX_CN_API_KEY or MINIMAX_API_KEY"
        case .kimi:
            "MOONSHOT_API_KEY or KIMI_API_KEY"
        case .ollama:
            "OLLAMA_BASE_URL or PEEKABOO_OLLAMA_BASE_URL"
        case .lmstudio:
            "LM Studio local server URL"
        case .openRouter:
            "OPENROUTER_API_KEY"
        case .grok:
            "X_AI_API_KEY, XAI_API_KEY, or GROK_API_KEY"
        case .custom:
            "the custom provider API key reference"
        default:
            "provider API key"
        }
    }

    func isLocalModel(_ model: LanguageModel?) -> Bool {
        switch model {
        case .ollama, .lmstudio:
            true
        default:
            false
        }
    }
}
