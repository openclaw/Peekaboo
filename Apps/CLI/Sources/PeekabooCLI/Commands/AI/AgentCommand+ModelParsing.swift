import Foundation
import PeekabooCore
import PeekabooFoundation
import Tachikoma

@available(macOS 14.0, *)
extension AgentCommand {
    func parseModelString(_ modelString: String) -> LanguageModel? {
        let trimmed = modelString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let explicitProvider = trimmed
            .split(separator: "/", maxSplits: 1)
            .first
            .map { String($0).lowercased() }

        guard let parsed = LanguageModel.parse(from: trimmed) else {
            return nil
        }

        switch parsed {
        case let .openai(model):
            if Self.supportedOpenAIInputs.contains(model) {
                return .openai(.gpt55)
            }
        case let .anthropic(model):
            if Self.supportedAnthropicInputs.contains(model) {
                return .anthropic(.opus47)
            }
        case let .google(model):
            if Self.supportedGoogleInputs.contains(model) {
                return .google(model)
            }
        case let .minimax(model):
            if Self.supportedMiniMaxInputs.contains(model) {
                return .minimax(model)
            }
        case let .minimaxCN(model):
            if Self.supportedMiniMaxInputs.contains(model) {
                return .minimaxCN(model)
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

    func validatedModelSelection() throws -> LanguageModel? {
        guard let modelString = self.model else { return nil }
        guard let parsed = self.parseModelString(modelString) else {
            throw PeekabooError.invalidInput(
                "Unsupported model '\(modelString)'. Allowed values: \(Self.allowedModelList)"
            )
        }
        return parsed
    }

    private static let supportedOpenAIInputs: Set<LanguageModel.OpenAI> = [
        .gpt55,
        .gpt54,
        .gpt54Mini,
        .gpt54Nano,
        .gpt5,
        .gpt5Pro,
        .gpt5Mini,
        .gpt5Nano,
    ]

    private static let supportedAnthropicInputs: Set<LanguageModel.Anthropic> = [
        .opus47,
        .opus45,
        .opus4,
        .sonnet46,
        .sonnet45,
        .haiku45,
    ]

    private static let supportedGoogleInputs: Set<LanguageModel.Google> = [
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
    ]

    private static let reservedProviderInputs: Set<String> = [
        "openai",
        "anthropic",
        "google",
        "gemini",
        "minimax",
        "minimax-cn",
        "minimax_cn",
        "minimaxi",
        "ollama",
        "lmstudio",
        "lm-studio",
    ]

    private static var allowedModelList: String {
        let openAIModels = Self.supportedOpenAIInputs.map(\.modelId)
        let anthropicModels = Self.supportedAnthropicInputs.map(\.modelId)
        let googleModels = Self.supportedGoogleInputs.map(\.userFacingModelId)
        let miniMaxModels = Self.supportedMiniMaxInputs.map(\.modelId)
        return (openAIModels + anthropicModels + googleModels + miniMaxModels + [
            "minimax-cn/<model>",
            "ollama/<model>",
            "lmstudio/<model>",
            "openrouter/<provider>/<model>",
        ])
        .sorted()
        .joined(separator: ", ")
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
        case .openRouter:
            return configuration.getOpenRouterAPIKey()?.isEmpty == false
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
        case .ollama:
            "Ollama"
        case .lmstudio:
            "LM Studio"
        case .openRouter:
            "OpenRouter"
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
        case .ollama:
            "OLLAMA_BASE_URL or PEEKABOO_OLLAMA_BASE_URL"
        case .lmstudio:
            "LM Studio local server URL"
        case .openRouter:
            "OPENROUTER_API_KEY"
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
