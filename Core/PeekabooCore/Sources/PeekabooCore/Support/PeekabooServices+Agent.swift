import Darwin
import Foundation
import os.log
import PeekabooAgentRuntime
import PeekabooFoundation
import Tachikoma

extension PeekabooServices {
    /// Refresh the agent service when API keys change
    @MainActor
    public func refreshAgentService() {
        self.logger.info("🔄 Refreshing agent service with updated configuration")

        // Reload configuration to get latest API keys
        _ = self.configuration.loadConfiguration()
        self.configuration.applyAIProviderKeys()

        let providers = self.configuration.getAIProviders()
        let agentConfig = self.configuration.getConfiguration()
        let aiService = PeekabooAIService(configuration: self.configuration)
        let configuredCustomDefaultModel = Self.configuredCustomDefaultModel(
            agentConfig?.agent?.defaultModel,
            providers: providers,
            aiService: aiService)
        let configuredDefault = configuredCustomDefaultModel?.modelId ?? agentConfig?.agent?.defaultModel

        // Check for available providers (API key or OAuth access token)
        let hasOpenAI = self.configuration.hasOpenAIAuth()
        let hasAnthropic = self.configuration.hasAnthropicAuth()
        let hasGemini = self.configuration.getGeminiAPIKey() != nil && !self.configuration.getGeminiAPIKey()!.isEmpty
        let hasMiniMax = self.configuration.getMiniMaxAPIKey() != nil && !self.configuration.getMiniMaxAPIKey()!.isEmpty
        let hasMiniMaxChina = self.configuration.getMiniMaxChinaAPIKey()?.isEmpty == false
        let hasMiniMaxChinaSpecific = self.configuration.getMiniMaxChinaAPIKey(fallbackToSharedKey: false)?
            .isEmpty == false
        let hasKimi = self.configuration.getKimiAPIKey()?.isEmpty == false
        let hasOpenRouter = self.configuration.getOpenRouterAPIKey()?.isEmpty == false
        let hasGrok = self.configuration.getGrokAPIKey()?.isEmpty == false
        let hasOllama = Self.providerList(providers, containsToolCapableLocalProvider: "ollama")
        let hasLMStudio = Self.providerList(providers, containsToolCapableLocalProvider: "lmstudio") ||
            Self.providerList(providers, containsToolCapableLocalProvider: "lm-studio")
        let customDefaultModel = configuredCustomDefaultModel ?? aiService
            .availableModels()
            .compactMap { model -> LanguageModel? in
                if case .custom = model, model.supportsTools, aiService.isModelAvailable(model) {
                    return model
                }
                return nil
            }
            .first
        let hasCustomProvider = customDefaultModel != nil

        if hasOpenAI || hasAnthropic || hasGemini || hasMiniMax || hasMiniMaxChina || hasKimi || hasOpenRouter ||
            hasGrok || hasOllama || hasLMStudio || hasCustomProvider
        {
            let environmentProviders = EnvironmentVariables.value(for: "PEEKABOO_AI_PROVIDERS")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hasEnvironmentProviders = environmentProviders?.isEmpty == false

            let sources = ModelSources(
                providers: providers,
                hasOpenAI: hasOpenAI,
                hasAnthropic: hasAnthropic,
                hasGemini: hasGemini,
                hasMiniMax: hasMiniMax,
                hasMiniMaxChina: hasMiniMaxChina,
                hasMiniMaxChinaSpecific: hasMiniMaxChinaSpecific,
                hasKimi: hasKimi,
                hasOpenRouter: hasOpenRouter,
                hasGrok: hasGrok,
                hasOllama: hasOllama,
                hasLMStudio: hasLMStudio,
                customDefaultModel: customDefaultModel,
                configuredDefault: configuredDefault,
                aiService: aiService,
                isProviderListExplicit: Self.isExplicitProviderList(
                    providers,
                    configuredDefault: configuredDefault,
                    isEnvironmentProvided: hasEnvironmentProviders,
                    hasConfiguredProviderList: agentConfig?.aiProviders?.providers?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty == false),
                isEnvironmentProvided: hasEnvironmentProviders)

            let determination = self.determineDefaultModelWithConflict(sources)
            if determination.hasConflict {
                Self.logModelConflict(determination, logger: self.logger)
            }

            self.agentLock.lock()
            defer { agentLock.unlock() }

            do {
                guard let model = determination.model else {
                    self.agent = nil
                    self.logger.warning(
                        """
                        \(AgentDisplayTokens.Status.warning) Configured AI providers are not available - \
                        agent service disabled
                        """)
                    return
                }
                let languageModel = determination.resolvedModel ??
                    Self.parseModelStringForAgent(model, configuration: self.configuration)
                self.agent = try PeekabooAgentService(
                    services: self,
                    defaultModel: languageModel)
            } catch {
                self.logger.error("Failed to refresh PeekabooAgentService: \(error)")
                self.agent = nil
            }
            self.logger
                .info("\(AgentDisplayTokens.Status.success) Agent service refreshed with providers: \(providers)")
        } else {
            self.agentLock.lock()
            defer { agentLock.unlock() }

            self.agent = nil
            self.logger.warning("\(AgentDisplayTokens.Status.warning) No API keys available - agent service disabled")
        }
    }

    private static func configuredCustomDefaultModel(
        _ configuredDefault: String?,
        providers: String,
        aiService: PeekabooAIService) -> LanguageModel?
    {
        guard let configuredDefault = configuredDefault?.trimmingCharacters(in: .whitespacesAndNewlines),
              !configuredDefault.isEmpty
        else {
            return nil
        }

        let providerCandidates = providers
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { entry in
                guard let model = entry.split(separator: "/", maxSplits: 1).last.map(String.init) else {
                    return false
                }
                return model == configuredDefault || entry == configuredDefault
            }

        for candidate in [configuredDefault] + providerCandidates {
            guard let model = aiService.resolveConfiguredModel(candidate),
                  case .custom = model,
                  model.supportsTools,
                  aiService.isModelAvailable(model)
            else {
                continue
            }
            return model
        }

        return nil
    }

    /// Parse model string to LanguageModel enum.
    @MainActor
    private static func parseModelStringForAgent(_ modelString: String, configuration: ConfigurationManager)
        -> LanguageModel
    {
        if let configuredModel = PeekabooAIService(configuration: configuration).resolveConfiguredModel(modelString) {
            return configuredModel
        }
        return LanguageModel.parse(from: modelString) ?? .openai(.gpt55)
    }

    private static func logModelConflict(_ determination: ModelDetermination, logger: SystemLogger) {
        logger.warning("\(AgentDisplayTokens.Status.warning) Model configuration conflict detected.")
        logger.warning("   Config file specifies: \(determination.configModel ?? "none")")
        logger.warning("   Environment variable specifies: \(determination.environmentModel ?? "none")")
        logger.warning("   Using environment variable: \(determination.model ?? "none")")

        let warningMessage = """
        \(AgentDisplayTokens.Status.warning)  Model configuration conflict:
           Config (~/.peekaboo/config.json) specifies: \(determination.configModel ?? "none")
           PEEKABOO_AI_PROVIDERS environment variable specifies: \(determination.environmentModel ?? "none")
           → Using environment variable: \(determination.model ?? "none")
        """
        print(warningMessage)
    }

    private func determineDefaultModelWithConflict(_ sources: ModelSources) -> ModelDetermination {
        let providerListModel = self.firstAvailableModel(in: sources)
        let environmentModel = sources.isEnvironmentProvided ? providerListModel : nil

        let hasConflict = sources.isEnvironmentProvided
            && sources.configuredDefault != nil
            && environmentModel != nil
            && !Self.modelSelectionsMatch(sources.configuredDefault, environmentModel)

        let model: String?
        let resolvedModel: LanguageModel?
        if let environmentModel {
            model = environmentModel
            resolvedModel = nil
        } else if sources.isProviderListExplicit {
            model = providerListModel
            resolvedModel = nil
        } else if let configuredDefault = sources.configuredDefault,
                  Self.isConfiguredDefaultAvailable(configuredDefault, sources: sources)
        {
            model = configuredDefault
            resolvedModel = nil
        } else if let providerListModel {
            model = providerListModel
            resolvedModel = nil
        } else if !sources.isProviderListExplicit, self.hasUnavailableCustomProviderSelection(in: sources) {
            model = nil
            resolvedModel = nil
        } else if sources.hasAnthropic {
            model = "claude-opus-4-8"
            resolvedModel = nil
        } else if sources.hasOpenAI {
            model = "gpt-5.5"
            resolvedModel = nil
        } else if sources.hasGemini {
            model = "gemini-3.5-flash"
            resolvedModel = nil
        } else if sources.hasGrok {
            model = "grok-4.3"
            resolvedModel = nil
        } else if sources.hasMiniMaxChinaSpecific {
            model = "minimax-cn/MiniMax-M2.7"
            resolvedModel = nil
        } else if sources.hasMiniMax {
            model = "minimax/MiniMax-M2.7"
            resolvedModel = nil
        } else if sources.hasKimi {
            model = "kimi/kimi-k2.6"
            resolvedModel = nil
        } else if sources.hasOpenRouter {
            model = "openrouter/openai/gpt-oss-120b"
            resolvedModel = nil
        } else if sources.hasOllama {
            model = "ollama/llama3.3"
            resolvedModel = nil
        } else if sources.hasLMStudio {
            model = "lmstudio/openai/gpt-oss-120b"
            resolvedModel = nil
        } else if let customDefaultModel = sources.customDefaultModel {
            model = customDefaultModel.description
            resolvedModel = customDefaultModel
        } else {
            model = "gpt-5.5"
            resolvedModel = nil
        }

        return ModelDetermination(
            model: model,
            resolvedModel: resolvedModel,
            hasConflict: hasConflict,
            configModel: sources.configuredDefault,
            environmentModel: environmentModel)
    }

    private func firstAvailableModel(in sources: ModelSources) -> String? {
        sources.providers
            .split(separator: ",")
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { rawProvider in
                if let model = sources.aiService.resolveConfiguredModel(rawProvider) {
                    if case .custom = model {
                        return model.supportsTools && sources.aiService.isModelAvailable(model) ? rawProvider : nil
                    }
                    if model.supportsTools, sources.aiService.isModelAvailable(model) {
                        return rawProvider
                    }
                }

                let parts = rawProvider.split(separator: "/", maxSplits: 1).map(String.init)
                guard let providerID = parts.first else { return nil }
                if sources.aiService.hasEnabledCustomProvider(matching: providerID) {
                    return nil
                }
                let provider = providerID.lowercased()
                if parts.count == 1 {
                    switch provider {
                    case "ollama" where sources.hasOllama:
                        return LanguageModel.ollama(.llama33).description
                    case "lmstudio" where sources.hasLMStudio,
                         "lm-studio" where sources.hasLMStudio:
                        return LanguageModel.lmstudio(.gptOSS120B).description
                    default:
                        return nil
                    }
                }
                guard parts.count == 2 else { return nil }
                let model = parts[1]

                switch provider {
                case "openai" where sources.hasOpenAI:
                    return model
                case "anthropic" where sources.hasAnthropic:
                    return model
                case "google" where sources.hasGemini:
                    return model
                case "gemini" where sources.hasGemini:
                    return model
                case "minimax" where sources.hasMiniMax:
                    return "minimax/\(model)"
                case "minimax-cn" where sources.hasMiniMaxChina,
                     "minimax_cn" where sources.hasMiniMaxChina,
                     "minimaxi" where sources.hasMiniMaxChina:
                    return "minimax-cn/\(model)"
                case "kimi" where sources.hasKimi,
                     "moonshot" where sources.hasKimi:
                    return "kimi/\(model)"
                case "openrouter" where sources.hasOpenRouter:
                    return "openrouter/\(model)"
                case "ollama" where sources.hasOllama:
                    return Self.toolCapableLocalModel("ollama/\(model)")
                case "lmstudio" where sources.hasLMStudio,
                     "lm-studio" where sources.hasLMStudio:
                    return Self.toolCapableLocalModel("lmstudio/\(model)")
                default:
                    return nil
                }
            }
            .first
    }

    private func hasUnavailableCustomProviderSelection(in sources: ModelSources) -> Bool {
        sources.providers
            .split(separator: ",")
            .contains { entry in
                let selection = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let providerID = selection
                    .split(separator: "/", maxSplits: 1)
                    .first
                    .map(String.init),
                    sources.aiService.hasEnabledCustomProvider(matching: providerID)
                else {
                    return false
                }
                guard let model = sources.aiService.resolveConfiguredModel(selection),
                      case .custom = model
                else {
                    return true
                }
                return !model.supportsTools || !sources.aiService.isModelAvailable(model)
            }
    }

    private static func providerList(_ providers: String, containsToolCapableLocalProvider provider: String) -> Bool {
        providers
            .split(separator: ",")
            .contains { entry in
                let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.split(separator: "/", maxSplits: 1).first?.lowercased() == provider else {
                    return false
                }
                return self.toolCapableLocalModel(trimmed) != nil
            }
    }

    private static func toolCapableLocalModel(_ rawModel: String) -> String? {
        guard let model = LanguageModel.parse(from: rawModel), model.supportsTools else {
            return nil
        }
        return rawModel
    }

    private static func modelSelectionsMatch(_ configuredDefault: String?, _ environmentModel: String?) -> Bool {
        guard let configuredDefault, let environmentModel else {
            return configuredDefault == environmentModel
        }
        if configuredDefault == environmentModel { return true }

        let configured = LanguageModel.parse(from: configuredDefault)
        let environment = LanguageModel.parse(from: environmentModel)
        if configured == environment { return true }

        return Self.model(environment, matchesRawIdentifier: configuredDefault) ||
            Self.model(configured, matchesRawIdentifier: environmentModel)
    }

    private static func model(_ model: LanguageModel?, matchesRawIdentifier rawIdentifier: String) -> Bool {
        guard let model else { return false }
        return rawIdentifier == model.modelId || rawIdentifier == model.description
    }

    private static func isConfiguredDefaultAvailable(_ rawModel: String, sources: ModelSources) -> Bool {
        if let model = sources.aiService.resolveConfiguredModel(rawModel) {
            return model.supportsTools && sources.aiService.isModelAvailable(model)
        }

        let components = rawModel.split(separator: "/", maxSplits: 1)
        if components.count == 2,
           sources.aiService.hasEnabledCustomProvider(matching: String(components[0]))
        {
            return false
        }

        guard let model = LanguageModel.parse(from: rawModel) else { return false }
        switch model {
        case .openai:
            return sources.hasOpenAI
        case .anthropic:
            return sources.hasAnthropic
        case .google:
            return sources.hasGemini
        case .minimax:
            return sources.hasMiniMax
        case .minimaxCN:
            return sources.hasMiniMaxChina
        case .kimi:
            return sources.hasKimi
        case .openRouter:
            return sources.hasOpenRouter
        case .grok:
            return sources.hasGrok
        case .ollama:
            return sources.hasOllama && model.supportsTools
        case .lmstudio:
            return sources.hasLMStudio && model.supportsTools
        default:
            return true
        }
    }

    private static func isExplicitProviderList(
        _ providers: String,
        configuredDefault: String?,
        isEnvironmentProvided: Bool,
        hasConfiguredProviderList: Bool) -> Bool
    {
        if isEnvironmentProvided { return true }
        guard hasConfiguredProviderList else { return false }
        return !self.isGeneratedProviderList(providers, configuredDefault: configuredDefault)
    }

    private static func isGeneratedProviderList(_ providers: String, configuredDefault: String?) -> Bool {
        ConfigurationManager.isGeneratedAIProviderList(providers, configuredDefault: configuredDefault)
    }
}

private enum EnvironmentVariables {
    static func value(for key: String) -> String? {
        guard let raw = getenv(key) else { return nil }
        return String(cString: raw)
    }
}

/// Result of model determination with conflict detection.
private struct ModelDetermination {
    let model: String?
    let resolvedModel: LanguageModel?
    let hasConflict: Bool
    let configModel: String?
    let environmentModel: String?
}

private struct ModelSources {
    let providers: String
    let hasOpenAI: Bool
    let hasAnthropic: Bool
    let hasGemini: Bool
    let hasMiniMax: Bool
    let hasMiniMaxChina: Bool
    let hasMiniMaxChinaSpecific: Bool
    let hasKimi: Bool
    let hasOpenRouter: Bool
    let hasGrok: Bool
    let hasOllama: Bool
    let hasLMStudio: Bool
    let customDefaultModel: LanguageModel?
    let configuredDefault: String?
    let aiService: PeekabooAIService
    let isProviderListExplicit: Bool
    let isEnvironmentProvided: Bool
}
