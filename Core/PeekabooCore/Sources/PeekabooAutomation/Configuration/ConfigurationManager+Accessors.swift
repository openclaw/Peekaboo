import Foundation
import PeekabooAutomationKit
import Tachikoma

extension ConfigurationManager {
    /// Get a configuration value with proper precedence: CLI args > env vars > config file > defaults
    public func getValue<T>(
        cliValue: T?,
        envVar: String?,
        configValue: T?,
        defaultValue: T) -> T
    {
        if let cliValue {
            return cliValue
        }

        if let envVar,
           let envValue = self.environmentValue(for: envVar),
           let converted: T = self.convertEnvValue(envValue, as: T.self)
        {
            return converted
        }

        if let configValue {
            return configValue
        }

        return defaultValue
    }

    /// Get AI providers with proper precedence
    public func getAIProviders(cliValue: String? = nil) -> String {
        self.getValue(
            cliValue: cliValue,
            envVar: "PEEKABOO_AI_PROVIDERS",
            configValue: self.configuration?.aiProviders?.providers,
            defaultValue: "openai/gpt-5.5,anthropic/claude-opus-4-7")
    }

    /// Get OpenAI API key with proper precedence
    public func getOpenAIAPIKey() -> String? {
        if let envValue = self.environmentValue(for: "OPENAI_API_KEY") {
            return envValue
        }

        if let token = self.validOAuthAccessToken(prefix: "OPENAI") {
            return token
        }

        if let credValue = credentials["OPENAI_API_KEY"] {
            return credValue
        }

        if let configValue = configuration?.aiProviders?.openaiApiKey {
            return configValue
        }

        return nil
    }

    /// Get Anthropic API key with proper precedence
    public func getAnthropicAPIKey() -> String? {
        if let envValue = self.environmentValue(for: "ANTHROPIC_API_KEY") {
            return envValue
        }

        if let token = self.validOAuthAccessToken(prefix: "ANTHROPIC") {
            return token
        }

        if let credValue = credentials["ANTHROPIC_API_KEY"] {
            return credValue
        }

        if let configValue = configuration?.aiProviders?.anthropicApiKey {
            return configValue
        }

        return nil
    }

    /// Get Gemini API key with proper precedence
    public func getGeminiAPIKey() -> String? {
        for key in ["GEMINI_API_KEY", "GOOGLE_API_KEY"] {
            if let envValue = self.environmentValue(for: key) {
                return envValue
            }
        }

        for key in ["GEMINI_API_KEY", "GOOGLE_API_KEY"] {
            if let credValue = credentials[key] {
                return credValue
            }
        }

        return nil
    }

    /// Get MiniMax API key with proper precedence
    public func getMiniMaxAPIKey() -> String? {
        if let envValue = self.environmentValue(for: "MINIMAX_API_KEY") {
            return envValue
        }

        if let credValue = credentials["MINIMAX_API_KEY"] {
            return credValue
        }

        if let configValue = configuration?.aiProviders?.minimaxApiKey {
            return configValue
        }

        return nil
    }

    /// Get OpenRouter API key with proper precedence.
    public func getOpenRouterAPIKey() -> String? {
        if let envValue = self.environmentValue(for: "OPENROUTER_API_KEY") {
            return envValue
        }

        if let credValue = credentials["OPENROUTER_API_KEY"] {
            return credValue
        }

        return nil
    }

    /// Apply Peekaboo-managed provider keys to Tachikoma.
    public func applyAIProviderKeys(to configuration: TachikomaConfiguration = .current) {
        if let key = self.getOpenAIAPIKey(), !key.isEmpty {
            configuration.setAPIKey(key, for: .openai)
        }
        if let key = self.getAnthropicAPIKey(), !key.isEmpty {
            configuration.setAPIKey(key, for: .anthropic)
        }
        if let key = self.getGeminiAPIKey(), !key.isEmpty {
            configuration.setAPIKey(key, for: .google)
        }
        if let key = self.getMiniMaxAPIKey(), !key.isEmpty {
            configuration.setAPIKey(key, for: .minimax)
        }
        if let key = self.getOpenRouterAPIKey(), !key.isEmpty {
            configuration.setAPIKey(key, for: .openrouter)
        }
        let ollamaBaseURL = self.getOllamaBaseURL()
        if !ollamaBaseURL.isEmpty {
            configuration.setBaseURL(ollamaBaseURL, for: .ollama)
        }
    }

    /// Get Ollama base URL with proper precedence
    public func getOllamaBaseURL() -> String {
        if let envValue = self.environmentValue(for: "PEEKABOO_OLLAMA_BASE_URL") {
            return envValue
        }
        if let envValue = self.environmentValue(for: "OLLAMA_BASE_URL") {
            return envValue
        }
        return self.configuration?.aiProviders?.ollamaBaseUrl ?? "http://localhost:11434"
    }

    /// Get default save path with proper precedence
    public func getDefaultSavePath(cliValue: String? = nil) -> String {
        let path = self.getValue(
            cliValue: cliValue,
            envVar: "PEEKABOO_DEFAULT_SAVE_PATH",
            configValue: self.configuration?.defaults?.savePath,
            defaultValue: "~/Desktop")
        return NSString(string: path).expandingTildeInPath
    }

    /// Get log level with proper precedence
    public func getLogLevel() -> String {
        self.getValue(
            cliValue: nil as String?,
            envVar: "PEEKABOO_LOG_LEVEL",
            configValue: self.configuration?.logging?.level,
            defaultValue: "info")
    }

    /// Get log path with proper precedence
    public func getLogPath() -> String {
        let path = self.getValue(
            cliValue: nil as String?,
            envVar: "PEEKABOO_LOG_PATH",
            configValue: self.configuration?.logging?.path,
            defaultValue: "~/.peekaboo/logs/peekaboo.log")
        return NSString(string: path).expandingTildeInPath
    }

    /// Get selected AI provider
    public func getSelectedProvider() -> String {
        guard let providers = self.configuration?.aiProviders?.providers,
              let provider = self.parseFirstProvider(providers)
        else {
            return "anthropic"
        }

        switch provider.lowercased() {
        case "gemini", "google":
            return "google"
        case "minimax":
            return "minimax"
        default:
            return Provider.from(identifier: provider).identifier
        }
    }

    /// Get agent model
    public func getAgentModel() -> String? {
        self.configuration?.agent?.defaultModel
    }

    /// Get agent temperature
    public func getAgentTemperature() -> Double {
        self.getValue(
            cliValue: nil as Double?,
            envVar: nil,
            configValue: self.configuration?.agent?.temperature,
            defaultValue: 0.7)
    }

    /// Get agent max tokens
    public func getAgentMaxTokens() -> Int {
        self.getValue(
            cliValue: nil as Int?,
            envVar: nil,
            configValue: self.configuration?.agent?.maxTokens,
            defaultValue: 16384)
    }

    /// Get UI input strategy policy with precedence: CLI args > env vars > config file > defaults.
    public func getUIInputPolicy(cliStrategy: UIInputStrategy? = nil) -> UIInputPolicy {
        let config = self.configuration?.input
        let globalEnvStrategy = self.uiInputStrategyFromEnvironment("PEEKABOO_INPUT_STRATEGY")
        let defaultStrategy = self.resolveUIInputStrategy(
            cliStrategy: cliStrategy,
            envStrategy: globalEnvStrategy,
            configStrategy: config?.defaultStrategy,
            defaultStrategy: .synthFirst)

        let clickStrategy = self.resolveUIInputStrategyOverride(
            cliStrategy: cliStrategy,
            envVar: "PEEKABOO_CLICK_INPUT_STRATEGY",
            globalEnvStrategy: globalEnvStrategy,
            configStrategy: config?.click,
            builtInStrategy: config?.defaultStrategy == nil ? .actionFirst : nil)
        let scrollStrategy = self.resolveUIInputStrategyOverride(
            cliStrategy: cliStrategy,
            envVar: "PEEKABOO_SCROLL_INPUT_STRATEGY",
            globalEnvStrategy: globalEnvStrategy,
            configStrategy: config?.scroll,
            builtInStrategy: config?.defaultStrategy == nil ? .actionFirst : nil)
        let typeStrategy = self.resolveUIInputStrategyOverride(
            cliStrategy: cliStrategy,
            envVar: "PEEKABOO_TYPE_INPUT_STRATEGY",
            globalEnvStrategy: globalEnvStrategy,
            configStrategy: config?.type)
        let hotkeyStrategy = self.resolveUIInputStrategyOverride(
            cliStrategy: cliStrategy,
            envVar: "PEEKABOO_HOTKEY_INPUT_STRATEGY",
            globalEnvStrategy: globalEnvStrategy,
            configStrategy: config?.hotkey)
        let setValueStrategy = self.resolveUIInputStrategy(
            cliStrategy: cliStrategy,
            envStrategy: self.uiInputStrategyFromEnvironment("PEEKABOO_SET_VALUE_INPUT_STRATEGY") ??
                globalEnvStrategy,
            configStrategy: config?.setValue,
            defaultStrategy: .actionOnly)
        let performActionStrategy = self.resolveUIInputStrategy(
            cliStrategy: cliStrategy,
            envStrategy: self.uiInputStrategyFromEnvironment("PEEKABOO_PERFORM_ACTION_INPUT_STRATEGY") ??
                globalEnvStrategy,
            configStrategy: config?.performAction,
            defaultStrategy: .actionOnly)

        let explicitOverrides = self.explicitUIInputOverrides(
            cliStrategy: cliStrategy,
            globalEnvStrategy: globalEnvStrategy)

        return UIInputPolicy(
            defaultStrategy: defaultStrategy,
            click: clickStrategy,
            scroll: scrollStrategy,
            type: typeStrategy,
            hotkey: hotkeyStrategy,
            setValue: setValueStrategy,
            performAction: performActionStrategy,
            perApp: self.resolvedAppInputPolicies(from: config?.perApp, explicitOverrides: explicitOverrides))
    }

    /// Test method to verify module interface
    public func testMethod() -> String {
        "test"
    }

    private func convertEnvValue<T>(_ value: String, as type: T.Type) -> T? {
        switch type {
        case is String.Type:
            return value as? T
        case is Bool.Type:
            let boolValue = value.lowercased() == "true" || value == "1"
            return boolValue as? T
        case is Int.Type:
            return Int(value) as? T
        case is Double.Type:
            return Double(value) as? T
        default:
            return nil
        }
    }

    private func parseFirstProvider(_ providers: String) -> String? {
        let components = providers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let firstProvider = components.first else { return nil }
        let parts = firstProvider.split(separator: "/")
        return parts.first.map(String.init)
    }

    private func resolveUIInputStrategy(
        cliStrategy: UIInputStrategy?,
        envStrategy: UIInputStrategy?,
        configStrategy: UIInputStrategy?,
        defaultStrategy: UIInputStrategy) -> UIInputStrategy
    {
        cliStrategy ?? envStrategy ?? configStrategy ?? defaultStrategy
    }

    private func resolveUIInputStrategyOverride(
        cliStrategy: UIInputStrategy?,
        envVar: String,
        globalEnvStrategy: UIInputStrategy?,
        configStrategy: UIInputStrategy?,
        builtInStrategy: UIInputStrategy? = nil) -> UIInputStrategy?
    {
        cliStrategy ?? self.uiInputStrategyFromEnvironment(envVar) ?? globalEnvStrategy ?? configStrategy ??
            builtInStrategy
    }

    private func uiInputStrategyFromEnvironment(_ envVar: String) -> UIInputStrategy? {
        guard let value = self.environmentValue(for: envVar) else { return nil }
        return UIInputStrategy(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func explicitUIInputOverrides(
        cliStrategy: UIInputStrategy?,
        globalEnvStrategy: UIInputStrategy?) -> AppUIInputPolicy
    {
        let click = cliStrategy ?? self.uiInputStrategyFromEnvironment("PEEKABOO_CLICK_INPUT_STRATEGY") ??
            globalEnvStrategy
        let scroll = cliStrategy ?? self.uiInputStrategyFromEnvironment("PEEKABOO_SCROLL_INPUT_STRATEGY") ??
            globalEnvStrategy
        let type = cliStrategy ?? self.uiInputStrategyFromEnvironment("PEEKABOO_TYPE_INPUT_STRATEGY") ??
            globalEnvStrategy
        let hotkey = cliStrategy ?? self.uiInputStrategyFromEnvironment("PEEKABOO_HOTKEY_INPUT_STRATEGY") ??
            globalEnvStrategy
        let setValue = cliStrategy ?? self.uiInputStrategyFromEnvironment("PEEKABOO_SET_VALUE_INPUT_STRATEGY") ??
            globalEnvStrategy
        let performAction = cliStrategy ??
            self.uiInputStrategyFromEnvironment("PEEKABOO_PERFORM_ACTION_INPUT_STRATEGY") ??
            globalEnvStrategy

        return AppUIInputPolicy(
            click: click,
            scroll: scroll,
            type: type,
            hotkey: hotkey,
            setValue: setValue,
            performAction: performAction)
    }

    private func resolvedAppInputPolicies(
        from config: [String: Configuration.AppInputConfig]?,
        explicitOverrides: AppUIInputPolicy) -> [String: AppUIInputPolicy]
    {
        guard let config else { return [:] }
        return config.mapValues { appConfig in
            AppUIInputPolicy(
                defaultStrategy: appConfig.defaultStrategy,
                click: explicitOverrides.click ?? appConfig.click,
                scroll: explicitOverrides.scroll ?? appConfig.scroll,
                type: explicitOverrides.type ?? appConfig.type,
                hotkey: explicitOverrides.hotkey ?? appConfig.hotkey,
                setValue: explicitOverrides.setValue ?? appConfig.setValue,
                performAction: explicitOverrides.performAction ?? appConfig.performAction)
        }
    }
}
