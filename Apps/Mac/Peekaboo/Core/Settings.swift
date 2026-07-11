import Foundation
import KeyboardShortcuts
import Observation
import PeekabooCore
import ServiceManagement
import Tachikoma

/// Application settings and preferences manager.
///
/// Settings are automatically persisted to UserDefaults and synchronized across app launches.
/// This class uses the modern @Observable pattern for SwiftUI integration.
@Observable
@MainActor
final class PeekabooSettings {
    static let defaultVisualizerAnimationSpeed: Double = 1.0
    /// Flag to prevent recursive saves during loading
    private var isLoading = false
    // Reference to ConfigurationManager
    private let configManager = ConfigurationManager.shared
    private weak var services: PeekabooServices?

    /// API Configuration - Now synced with config.json
    var selectedProvider: String = "anthropic" {
        didSet {
            let canonicalProvider = self.canonicalProviderIdentifier(self.selectedProvider)
            if canonicalProvider != self.selectedProvider {
                let wasLoading = self.isLoading
                self.isLoading = true
                self.selectedProvider = canonicalProvider
                self.isLoading = wasLoading
                if !wasLoading {
                    self.save()
                    self.updateConfigFile()
                    self.services?.refreshAgentService()
                }
                return
            }

            self.save()
            self.updateConfigFile()
            if !self.isLoading {
                self.services?.refreshAgentService()
            }
        }
    }

    var openAIAPIKey: String = "" {
        didSet {
            self.save()
            self.saveAPIKeyToCredentials("OPENAI_API_KEY", self.openAIAPIKey)
        }
    }

    var anthropicAPIKey: String = "" {
        didSet {
            self.save()
            self.saveAPIKeyToCredentials("ANTHROPIC_API_KEY", self.anthropicAPIKey)
        }
    }

    var grokAPIKey: String = "" {
        didSet {
            self.save()
            self.saveAPIKeyToCredentials("X_AI_API_KEY", self.grokAPIKey)
        }
    }

    var googleAPIKey: String = "" {
        didSet {
            self.save()
            self.saveAPIKeyToCredentials("GEMINI_API_KEY", self.googleAPIKey)
        }
    }

    var miniMaxAPIKey: String = "" {
        didSet {
            self.save()
            self.saveAPIKeyToCredentials("MINIMAX_API_KEY", self.miniMaxAPIKey)
        }
    }

    var miniMaxChinaAPIKey: String = "" {
        didSet {
            self.save()
            self.saveAPIKeyToCredentials("MINIMAX_CN_API_KEY", self.miniMaxChinaAPIKey)
        }
    }

    var ollamaBaseURL: String = "http://localhost:11434" {
        didSet { self.save() }
    }

    var selectedModel: String = "claude-opus-4-8" {
        didSet {
            self.save()
            self.updateConfigFile()
            if !self.isLoading {
                self.services?.refreshAgentService()
            }
        }
    }

    /// Vision model override
    var useCustomVisionModel: Bool = false {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    var customVisionModel: String = "gpt-5.5" {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    var temperature: Double = 0.7 {
        didSet {
            let clamped = max(0, min(1, temperature))
            if self.temperature != clamped {
                self.temperature = clamped
            } else {
                self.save()
                self.updateConfigFile()
            }
        }
    }

    var maxTokens: Int = 16384 {
        didSet {
            let clamped = max(1, min(128_000, maxTokens))
            if self.maxTokens != clamped {
                self.maxTokens = clamped
            } else {
                self.save()
                self.updateConfigFile()
            }
        }
    }

    /// UI Preferences
    var alwaysOnTop: Bool = false {
        didSet { self.save() }
    }

    var showInDock: Bool = true {
        didSet {
            self.save()
            // Update dock visibility when preference changes
            Task { @MainActor in
                DockIconManager.shared.updateDockVisibility()
            }
        }
    }

    var launchAtLogin: Bool = false {
        didSet {
            // Don't save or update during loading to prevent recursion
            if !self.isLoading {
                self.save()

                // Update launch at login status
                do {
                    if self.launchAtLogin {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    print("Failed to update launch at login: \(error)")
                    // Prevent recursion when reverting - temporarily set isLoading
                    self.isLoading = true
                    self.launchAtLogin = !self.launchAtLogin
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - Keyboard Shortcuts

    // Keyboard shortcuts are now managed by sindresorhus/KeyboardShortcuts library
    // See KeyboardShortcutNames.swift for the defined shortcuts

    /// Mac-specific UI Features
    var agentModeEnabled: Bool = false {
        didSet { self.save() }
    }

    var hapticFeedbackEnabled: Bool = true {
        didSet { self.save() }
    }

    var soundEffectsEnabled: Bool = true {
        didSet { self.save() }
    }

    // MARK: - Visualizer Settings

    var visualizerEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    var visualizerAnimationSpeed: Double = PeekabooSettings.defaultVisualizerAnimationSpeed {
        didSet {
            let clamped = max(0.1, min(2.0, visualizerAnimationSpeed))
            if self.visualizerAnimationSpeed != clamped {
                self.visualizerAnimationSpeed = clamped
            } else {
                self.save()
            }
        }
    }

    var visualizerEffectIntensity: Double = 1.0 {
        didSet {
            let clamped = max(0.1, min(2.0, visualizerEffectIntensity))
            if self.visualizerEffectIntensity != clamped {
                self.visualizerEffectIntensity = clamped
            } else {
                self.save()
            }
        }
    }

    var visualizerSoundEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    /// Individual animation toggles
    var screenshotFlashEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    var clickAnimationEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    var typeAnimationEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    var scrollAnimationEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    var mouseTrailEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    var swipePathEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    var hotkeyOverlayEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    var appLifecycleEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    var windowOperationEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    var watchCaptureHUDEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    // MARK: - Realtime Voice Settings

    /// The selected voice for realtime conversations
    var realtimeVoice: String? {
        didSet {
            self.save()
        }
    }

    /// Custom instructions for the realtime assistant
    var realtimeInstructions: String? {
        didSet {
            self.save()
        }
    }

    /// Whether to use voice activity detection
    var realtimeVAD: Bool = true {
        didSet {
            self.save()
        }
    }

    var menuNavigationEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    var dialogInteractionEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    var spaceTransitionEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    /// Easter eggs
    var ghostEasterEggEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    /// Accessibility element bounding boxes during `see`. Off by default —
    /// a box per detected control clutters the screen.
    var elementDetectionEnabled: Bool = false {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    var annotatedScreenshotEnabled: Bool = true {
        didSet {
            self.save()
            self.updateConfigFile()
        }
    }

    /// Custom Providers
    @ObservationIgnored
    var customProviders: [String: Configuration.CustomProvider] {
        self.configManager.listCustomProviders()
    }

    /// Computed Properties
    var hasValidAPIKey: Bool {
        if let customProviderID = self.customProviderIdentifier(matching: self.selectedProvider),
           let customProvider = self.customProviders[customProviderID]
        {
            return self.configManager.resolveCredentialReference(customProvider.options.apiKey)?.isEmpty == false
        }

        switch self.selectedProvider {
        case "openai":
            return !self.openAIAPIKey.isEmpty || self.isUsingOpenAIEnvironment ||
                self.hasCredentialValue(forAny: ["OPENAI_ACCESS_TOKEN", "OPENAI_API_KEY"])
        case "anthropic":
            return !self.anthropicAPIKey.isEmpty || self.isUsingAnthropicEnvironment ||
                self.hasCredentialValue(forAny: ["ANTHROPIC_ACCESS_TOKEN", "ANTHROPIC_API_KEY"])
        case "grok":
            return !self.grokAPIKey.isEmpty || self.isUsingGrokEnvironment ||
                self.hasCredentialValue(forAny: ["X_AI_API_KEY", "XAI_API_KEY", "GROK_API_KEY"])
        case "google":
            return !self.googleAPIKey.isEmpty || self.isUsingGoogleEnvironment ||
                self.hasCredentialValue(forAny: ["GEMINI_API_KEY", "GOOGLE_API_KEY"])
        case "minimax":
            return !self.miniMaxAPIKey.isEmpty || self.isUsingMiniMaxEnvironment ||
                self.hasCredentialValue(forAny: ["MINIMAX_API_KEY"]) ||
                self.configManager.getMiniMaxAPIKey()?.isEmpty == false
        case "minimax-cn", "minimax_cn", "minimaxi":
            return !self.miniMaxChinaAPIKey.isEmpty || !self.miniMaxAPIKey.isEmpty ||
                self.isUsingMiniMaxChinaEnvironment || self.isUsingMiniMaxEnvironment ||
                self.hasCredentialValue(forAny: ["MINIMAX_CN_API_KEY", "MINIMAX_API_KEY"]) ||
                self.configManager.getMiniMaxChinaAPIKey()?.isEmpty == false
        case "openrouter":
            return self.configManager.getOpenRouterAPIKey()?.isEmpty == false
        case "ollama", "lmstudio", "lm-studio":
            return true // Local providers don't require API keys.
        default:
            // Check if it's a custom provider
            if let customProvider = self.customProviders[self.selectedProvider] {
                return !customProvider.options.apiKey.isEmpty
            }
            return false
        }
    }

    /// Check if we're using environment variables
    var isUsingOpenAIEnvironment: Bool {
        self.openAIAPIKey.isEmpty && self.detectedEnvironmentVariable(for: ["OPENAI_API_KEY"]) != nil
    }

    var isUsingAnthropicEnvironment: Bool {
        self.anthropicAPIKey.isEmpty && self.detectedEnvironmentVariable(for: ["ANTHROPIC_API_KEY"]) != nil
    }

    var isUsingGrokEnvironment: Bool {
        self.grokAPIKey.isEmpty && self.detectedEnvironmentVariable(
            for: ["X_AI_API_KEY", "XAI_API_KEY", "GROK_API_KEY"]) != nil
    }

    var isUsingGoogleEnvironment: Bool {
        self.googleAPIKey.isEmpty && self.detectedEnvironmentVariable(
            for: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]) != nil
    }

    var isUsingMiniMaxEnvironment: Bool {
        self.miniMaxAPIKey.isEmpty && self.detectedEnvironmentVariable(for: ["MINIMAX_API_KEY"]) != nil
    }

    var isUsingMiniMaxChinaEnvironment: Bool {
        self.miniMaxChinaAPIKey.isEmpty && self
            .detectedEnvironmentVariable(for: ["MINIMAX_CN_API_KEY", "MINIMAX_API_KEY"]) != nil
    }

    var allAvailableProviders: [String] {
        let builtIn = ["openai", "anthropic", "grok", "google", "minimax", "minimax-cn", "ollama", "lmstudio"]
        let custom = self.customProviders.compactMap { $0.value.enabled ? $0.key : nil }
        let customIDs = Set(custom.map { $0.lowercased() })
        return builtIn.filter { !customIDs.contains($0) } + custom.sorted()
    }

    // Storage
    private let userDefaults = UserDefaults.standard
    private let keyPrefix = "peekaboo."

    init() {
        self.load()
        self.loadFromPeekabooConfig()
        self.migrateSettingsIfNeeded()
    }
}

extension PeekabooSettings {
    private func load() {
        self.isLoading = true
        defer { self.isLoading = false }

        self.loadProviderSettings()
        self.loadUIPreferences()
        self.loadVisualizerSettings()
        self.loadAnimationPreferences()
        self.loadRealtimeVoiceSettings()
    }

    private func loadProviderSettings() {
        self.selectedProvider = self.canonicalProviderIdentifier(
            self.userDefaults.string(forKey: self.namespaced("selectedProvider")) ?? "anthropic")
        self.openAIAPIKey = self.userDefaults.string(forKey: self.namespaced("openAIAPIKey")) ?? ""
        self.anthropicAPIKey = self.userDefaults.string(forKey: self.namespaced("anthropicAPIKey")) ?? ""
        self.grokAPIKey = self.userDefaults.string(forKey: self.namespaced("grokAPIKey")) ?? ""
        self.googleAPIKey = self.userDefaults.string(forKey: self.namespaced("googleAPIKey")) ?? ""
        self.miniMaxAPIKey = self.userDefaults.string(forKey: self.namespaced("miniMaxAPIKey")) ?? ""
        self.miniMaxChinaAPIKey = self.userDefaults.string(forKey: self.namespaced("miniMaxChinaAPIKey")) ?? ""
        self.ollamaBaseURL = self.userDefaults.string(forKey: self.namespaced(
            "ollamaBaseURL")) ?? "http://localhost:11434"

        let defaultModel = self.defaultModel(for: self.selectedProvider)
        self.selectedModel = self.userDefaults.string(forKey: self.namespaced("selectedModel")) ?? defaultModel
        self.useCustomVisionModel = self.userDefaults.bool(forKey: self.namespaced("useCustomVisionModel"))
        self.customVisionModel = self.userDefaults.string(forKey: self.namespaced("customVisionModel")) ?? "gpt-5.5"

        self.temperature = self.nonZeroDouble(forKey: "temperature", fallback: 0.7)
        self.maxTokens = self.nonZeroInt(forKey: "maxTokens", fallback: 16384)
    }

    private func loadUIPreferences() {
        self.alwaysOnTop = self.userDefaults.bool(forKey: self.namespaced("alwaysOnTop"))

        let showInDockKey = self.namespaced("showInDock")
        if self.userDefaults.object(forKey: showInDockKey) == nil {
            self.showInDock = true
            self.userDefaults.set(true, forKey: showInDockKey)
        } else {
            self.showInDock = self.userDefaults.bool(forKey: showInDockKey)
        }

        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.userDefaults.set(self.launchAtLogin, forKey: self.namespaced("launchAtLogin"))

        self.agentModeEnabled = self.valueOrDefault(key: "agentModeEnabled", defaultValue: false)
        self.hapticFeedbackEnabled = self.userDefaults.bool(forKey: self.namespaced("hapticFeedbackEnabled"))
        self.soundEffectsEnabled = self.userDefaults.bool(forKey: self.namespaced("soundEffectsEnabled"))

        self.ensureTrueFlag(markerKey: "hapticFeedbackEnabledSet", value: &self.hapticFeedbackEnabled)
        self.ensureTrueFlag(markerKey: "soundEffectsEnabledSet", value: &self.soundEffectsEnabled)
    }

    private func loadVisualizerSettings() {
        self.visualizerEnabled = self.valueOrDefault(key: "visualizerEnabled", defaultValue: true)

        self.visualizerAnimationSpeed = self.nonZeroDouble(
            forKey: "visualizerAnimationSpeed",
            fallback: PeekabooSettings.defaultVisualizerAnimationSpeed)
        self.visualizerEffectIntensity = self.nonZeroDouble(forKey: "visualizerEffectIntensity", fallback: 1.0)
        self.visualizerSoundEnabled = self.valueOrDefault(key: "visualizerSoundEnabled", defaultValue: true)
    }

    private func loadAnimationPreferences() {
        for key in PeekabooSettings.animationKeys {
            let namespacedKey = self.namespaced(key)
            if self.userDefaults.object(forKey: namespacedKey) == nil {
                self.userDefaults.set(true, forKey: namespacedKey)
            }
        }

        self.screenshotFlashEnabled = self.userDefaults.bool(forKey: self.namespaced("screenshotFlashEnabled"))
        self.clickAnimationEnabled = self.userDefaults.bool(forKey: self.namespaced("clickAnimationEnabled"))
        self.typeAnimationEnabled = self.userDefaults.bool(forKey: self.namespaced("typeAnimationEnabled"))
        self.scrollAnimationEnabled = self.userDefaults.bool(forKey: self.namespaced("scrollAnimationEnabled"))
        self.mouseTrailEnabled = self.userDefaults.bool(forKey: self.namespaced("mouseTrailEnabled"))
        self.swipePathEnabled = self.userDefaults.bool(forKey: self.namespaced("swipePathEnabled"))
        self.hotkeyOverlayEnabled = self.userDefaults.bool(forKey: self.namespaced("hotkeyOverlayEnabled"))
        self.appLifecycleEnabled = self.userDefaults.bool(forKey: self.namespaced("appLifecycleEnabled"))
        self.windowOperationEnabled = self.userDefaults.bool(forKey: self.namespaced("windowOperationEnabled"))
        self.watchCaptureHUDEnabled = self.valueOrDefault(key: "watchCaptureHUDEnabled", defaultValue: true)
        self.menuNavigationEnabled = self.userDefaults.bool(forKey: self.namespaced("menuNavigationEnabled"))
        self.dialogInteractionEnabled = self.userDefaults.bool(forKey: self.namespaced("dialogInteractionEnabled"))
        self.spaceTransitionEnabled = self.userDefaults.bool(forKey: self.namespaced("spaceTransitionEnabled"))
        self.ghostEasterEggEnabled = self.userDefaults.bool(forKey: self.namespaced("ghostEasterEggEnabled"))
        // Not in `animationKeys`: that list force-sets absent keys to true,
        // and element boxes must stay off until the user opts in.
        self.elementDetectionEnabled = self.valueOrDefault(key: "elementDetectionEnabled", defaultValue: false)
        self.annotatedScreenshotEnabled = self.valueOrDefault(key: "annotatedScreenshotEnabled", defaultValue: true)
    }

    private func loadRealtimeVoiceSettings() {
        self.realtimeVoice = self.userDefaults.string(forKey: self.namespaced("realtimeVoice"))
        self.realtimeInstructions = self.userDefaults.string(forKey: self.namespaced("realtimeInstructions"))
        self.realtimeVAD = self.valueOrDefault(key: "realtimeVAD", defaultValue: true)
    }

    private func save() {
        guard !self.isLoading else { return }

        self.userDefaults.set(self.selectedProvider, forKey: "\(self.keyPrefix)selectedProvider")
        self.userDefaults.set(self.openAIAPIKey, forKey: "\(self.keyPrefix)openAIAPIKey")
        self.userDefaults.set(self.anthropicAPIKey, forKey: "\(self.keyPrefix)anthropicAPIKey")
        self.userDefaults.set(self.grokAPIKey, forKey: "\(self.keyPrefix)grokAPIKey")
        self.userDefaults.set(self.googleAPIKey, forKey: "\(self.keyPrefix)googleAPIKey")
        self.userDefaults.set(self.miniMaxAPIKey, forKey: "\(self.keyPrefix)miniMaxAPIKey")
        self.userDefaults.set(self.miniMaxChinaAPIKey, forKey: "\(self.keyPrefix)miniMaxChinaAPIKey")
        self.userDefaults.set(self.ollamaBaseURL, forKey: "\(self.keyPrefix)ollamaBaseURL")
        self.userDefaults.set(self.selectedModel, forKey: "\(self.keyPrefix)selectedModel")
        self.userDefaults.set(self.useCustomVisionModel, forKey: "\(self.keyPrefix)useCustomVisionModel")
        self.userDefaults.set(self.customVisionModel, forKey: "\(self.keyPrefix)customVisionModel")
        self.userDefaults.set(self.temperature, forKey: "\(self.keyPrefix)temperature")
        self.userDefaults.set(self.maxTokens, forKey: "\(self.keyPrefix)maxTokens")

        self.userDefaults.set(self.alwaysOnTop, forKey: "\(self.keyPrefix)alwaysOnTop")
        self.userDefaults.set(self.showInDock, forKey: "\(self.keyPrefix)showInDock")
        self.userDefaults.set(self.launchAtLogin, forKey: "\(self.keyPrefix)launchAtLogin")

        // Keyboard shortcuts are automatically saved by the KeyboardShortcuts library

        self.userDefaults.set(self.agentModeEnabled, forKey: "\(self.keyPrefix)agentModeEnabled")
        self.userDefaults.set(self.hapticFeedbackEnabled, forKey: "\(self.keyPrefix)hapticFeedbackEnabled")
        self.userDefaults.set(self.soundEffectsEnabled, forKey: "\(self.keyPrefix)soundEffectsEnabled")

        // Save visualizer settings
        self.userDefaults.set(self.visualizerEnabled, forKey: "\(self.keyPrefix)visualizerEnabled")
        self.userDefaults.set(self.visualizerAnimationSpeed, forKey: "\(self.keyPrefix)visualizerAnimationSpeed")
        self.userDefaults.set(self.visualizerEffectIntensity, forKey: "\(self.keyPrefix)visualizerEffectIntensity")
        self.userDefaults.set(self.visualizerSoundEnabled, forKey: "\(self.keyPrefix)visualizerSoundEnabled")

        // Save individual animation toggles
        self.userDefaults.set(self.screenshotFlashEnabled, forKey: "\(self.keyPrefix)screenshotFlashEnabled")
        self.userDefaults.set(self.clickAnimationEnabled, forKey: "\(self.keyPrefix)clickAnimationEnabled")
        self.userDefaults.set(self.typeAnimationEnabled, forKey: "\(self.keyPrefix)typeAnimationEnabled")
        self.userDefaults.set(self.scrollAnimationEnabled, forKey: "\(self.keyPrefix)scrollAnimationEnabled")
        self.userDefaults.set(self.mouseTrailEnabled, forKey: "\(self.keyPrefix)mouseTrailEnabled")
        self.userDefaults.set(self.swipePathEnabled, forKey: "\(self.keyPrefix)swipePathEnabled")
        self.userDefaults.set(self.hotkeyOverlayEnabled, forKey: "\(self.keyPrefix)hotkeyOverlayEnabled")
        self.userDefaults.set(self.appLifecycleEnabled, forKey: "\(self.keyPrefix)appLifecycleEnabled")
        self.userDefaults.set(self.windowOperationEnabled, forKey: "\(self.keyPrefix)windowOperationEnabled")
        self.userDefaults.set(self.watchCaptureHUDEnabled, forKey: "\(self.keyPrefix)watchCaptureHUDEnabled")
        self.userDefaults.set(self.menuNavigationEnabled, forKey: "\(self.keyPrefix)menuNavigationEnabled")
        self.userDefaults.set(self.dialogInteractionEnabled, forKey: "\(self.keyPrefix)dialogInteractionEnabled")
        self.userDefaults.set(self.spaceTransitionEnabled, forKey: "\(self.keyPrefix)spaceTransitionEnabled")
        self.userDefaults.set(self.ghostEasterEggEnabled, forKey: "\(self.keyPrefix)ghostEasterEggEnabled")
        self.userDefaults.set(self.elementDetectionEnabled, forKey: "\(self.keyPrefix)elementDetectionEnabled")
        self.userDefaults.set(self.annotatedScreenshotEnabled, forKey: "\(self.keyPrefix)annotatedScreenshotEnabled")

        // Save Realtime Voice settings
        if let voice = self.realtimeVoice {
            self.userDefaults.set(voice, forKey: "\(self.keyPrefix)realtimeVoice")
        } else {
            self.userDefaults.removeObject(forKey: "\(self.keyPrefix)realtimeVoice")
        }
        if let instructions = self.realtimeInstructions {
            self.userDefaults.set(instructions, forKey: "\(self.keyPrefix)realtimeInstructions")
        } else {
            self.userDefaults.removeObject(forKey: "\(self.keyPrefix)realtimeInstructions")
        }
        self.userDefaults.set(self.realtimeVAD, forKey: "\(self.keyPrefix)realtimeVAD")
    }

    private func loadFromPeekabooConfig() {
        let wasLoading = self.isLoading
        self.isLoading = true
        defer { self.isLoading = wasLoading }

        // Use ConfigurationManager to load from config.json
        let config = self.configManager.loadConfiguration()

        // config.json is the cross-process switch for element boxes (the CLI
        // consults the same key before dispatching), so an explicit value there
        // wins over the locally persisted toggle at launch.
        if let elementBoxes = config?.visualizer?.elementDetectionEnabled {
            self.elementDetectionEnabled = elementBoxes
        }

        // Don't copy environment variables into settings!
        // Only load from credentials file if they exist there
        // This allows proper environment variable detection in the UI

        // Load provider and model from config
        let selectedProvider = self.canonicalProviderIdentifier(self.configManager.getSelectedProvider())
        if !selectedProvider.isEmpty {
            self.selectedProvider = selectedProvider
        }

        // Load agent settings from config
        if let model = configManager.getAgentModel() {
            let selection = self.providerQualifiedModelSelection(from: model)
            if let provider = selection.provider {
                self.selectedProvider = provider
            }
            self.selectedModel = selection.model
        } else if let model = self.firstConfiguredModel(
            in: self.configManager.getAIProviders(),
            matching: self.selectedProvider)
        {
            self.selectedModel = model
        }

        let configTemp = self.configManager.getAgentTemperature()
        if configTemp != 0.7 { // Only update if not default
            self.temperature = configTemp
        }

        let configTokens = self.configManager.getAgentMaxTokens()
        if configTokens != 16384 { // Only update if not default
            self.maxTokens = configTokens
        }

        // Load Ollama base URL
        let ollamaURL = self.configManager.getOllamaBaseURL()
        if ollamaURL != "http://localhost:11434" {
            self.ollamaBaseURL = ollamaURL
        }
    }

    private func migrateSettingsIfNeeded() {
        // Check if we've already migrated
        let migrationKey = "\(keyPrefix)migratedToConfigJson"
        guard !self.userDefaults.bool(forKey: migrationKey) else { return }

        if FileManager.default.fileExists(atPath: ConfigurationManager.configPath) {
            self.userDefaults.set(true, forKey: migrationKey)
            return
        }

        // Migrate settings from UserDefaults to config.json
        do {
            try self.configManager.updateConfiguration { config in
                // Ensure structures exist
                if config.agent == nil {
                    config.agent = Configuration.AgentConfig()
                }

                // Migrate agent settings
                config.agent?.defaultModel = self.agentDefaultModel()
                config.agent?.temperature = self.temperature
                config.agent?.maxTokens = self.maxTokens

                // Update AI providers if needed
                if config.aiProviders == nil {
                    config.aiProviders = Configuration.AIProviderConfig()
                }

                // Build providers string based on selected provider and model
                let providerString = switch self.selectedProvider {
                case "openai":
                    "openai/\(self.selectedModel)"
                case "anthropic":
                    "anthropic/\(self.selectedModel)"
                case "grok":
                    "grok/\(self.selectedModel)"
                case "google":
                    "google/\(self.selectedModel)"
                case "minimax":
                    "minimax/\(self.selectedModel)"
                case "minimax-cn", "minimax_cn", "minimaxi":
                    "minimax-cn/\(self.selectedModel)"
                case "ollama":
                    "ollama/\(self.selectedModel)"
                case "lmstudio", "lm-studio":
                    "lmstudio/\(self.selectedModel)"
                case "openrouter":
                    "openrouter/\(self.selectedModel)"
                default:
                    "anthropic/claude-opus-4-8"
                }

                // Set providers string with fallbacks
                config.aiProviders?.providers = "\(providerString),ollama/llava:latest"

                // Set Ollama base URL if custom
                if self.ollamaBaseURL != "http://localhost:11434" {
                    config.aiProviders?.ollamaBaseUrl = self.ollamaBaseURL
                }
            }

            // Mark as migrated
            self.userDefaults.set(true, forKey: migrationKey)

            print("Successfully migrated settings to config.json")
        } catch {
            print("Failed to migrate settings to config.json: \(error)")
        }
    }

    private func updateConfigFile(excludingProvider excludedProvider: String? = nil) {
        guard !self.isLoading else { return }

        do {
            try self.configManager.updateConfiguration { config in
                // Ensure structures exist
                if config.agent == nil {
                    config.agent = Configuration.AgentConfig()
                }

                // Update agent settings
                config.agent?.defaultModel = self.agentDefaultModel()
                config.agent?.temperature = self.temperature
                config.agent?.maxTokens = self.maxTokens

                // Update AI providers
                if config.aiProviders == nil {
                    config.aiProviders = Configuration.AIProviderConfig()
                }

                let providerString = self.selectedProviderString()

                // Update providers string
                if let currentProviders = config.aiProviders?.providers {
                    // Move the selected provider first while keeping every other fallback.
                    let providers = currentProviders.split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                    var newProviders = [providerString]

                    // Add other providers that aren't the same type
                    for provider in providers {
                        let providerType = provider.split(separator: "/").first.map(String.init) ?? ""
                        if let excludedProvider,
                           providerType.caseInsensitiveCompare(excludedProvider) == .orderedSame
                        {
                            continue
                        }
                        if self.canonicalProviderIdentifier(providerType) !=
                            self.canonicalProviderIdentifier(self.selectedProvider)
                        {
                            newProviders.append(provider)
                        }
                    }

                    // Ensure we have a fallback
                    if newProviders.count == 1, !providerString.starts(with: "ollama/") {
                        newProviders.append("ollama/llava:latest")
                    }

                    config.aiProviders?.providers = newProviders.joined(separator: ",")
                } else {
                    config.aiProviders?.providers = "\(providerString),ollama/llava:latest"
                }

                // Update Ollama base URL if custom
                if self.ollamaBaseURL != "http://localhost:11434" {
                    config.aiProviders?.ollamaBaseUrl = self.ollamaBaseURL
                }

                // Mirror the element-box toggle into config.json so the CLI's
                // dispatch gate (SeeTool) follows the app setting.
                if config.visualizer == nil {
                    config.visualizer = Configuration.VisualizerConfig()
                }
                config.visualizer?.elementDetectionEnabled = self.elementDetectionEnabled
            }
        } catch {
            print("Failed to update config.json: \(error)")
        }
    }

    private func selectedProviderString() -> String {
        switch self.selectedProvider {
        case "openai":
            "openai/\(self.selectedModel)"
        case "anthropic":
            "anthropic/\(self.selectedModel)"
        case "grok":
            "grok/\(self.selectedModel)"
        case "google":
            "google/\(self.selectedModel)"
        case "minimax":
            "minimax/\(self.selectedModel)"
        case "minimax-cn", "minimax_cn", "minimaxi":
            "minimax-cn/\(self.selectedModel)"
        case "ollama":
            "ollama/\(self.selectedModel)"
        case "lmstudio", "lm-studio":
            "lmstudio/\(self.selectedModel)"
        case "openrouter":
            "openrouter/\(self.selectedModel)"
        default:
            if self.customProviders[self.selectedProvider] != nil {
                "\(self.selectedProvider)/\(self.selectedModel)"
            } else {
                "anthropic/claude-opus-4-8"
            }
        }
    }

    @MainActor
    private func saveAPIKeyToCredentials(_ key: String, _ value: String) {
        guard !self.isLoading else { return }

        do {
            guard let provider = self.provider(forCredentialKey: key) else { return }

            if value.isEmpty {
                for credentialKey in self.credentialKeys(for: provider) {
                    try self.configManager.removeCredential(key: credentialKey)
                }
                if let environmentValue = self.environmentCredentialValue(for: provider) {
                    TachikomaConfiguration.current.setAPIKey(environmentValue, for: provider)
                } else {
                    TachikomaConfiguration.current.removeAPIKey(for: provider)
                }
                self.services?.refreshAgentService()
                return
            }
            for credentialKey in self.credentialKeys(for: provider) where credentialKey != key {
                try self.configManager.removeCredential(key: credentialKey)
            }
            try self.configManager.setCredential(key: key, value: value)
            TachikomaConfiguration.current.setAPIKey(value, for: provider)

            // Refresh the agent service to pick up new API keys
            self.services?.refreshAgentService()
        } catch {
            print("Failed to save API key to credentials: \(error)")
        }
    }

    func connectServices(_ services: PeekabooServices) {
        self.services = services
    }

    // MARK: - Custom Provider Management

    func addCustomProvider(_ provider: Configuration.CustomProvider, id: String) throws {
        try self.configManager.addCustomProvider(provider, id: id)
        // UI updates automatically with @Observable
    }

    func selectCustomProvider(id: String) {
        guard let provider = self.getCustomProvider(id: id),
              provider.enabled,
              let model = self.configuredModelForCustomProvider(id: id)
        else { return }

        let wasLoading = self.isLoading
        self.isLoading = true
        self.selectedProvider = id
        self.selectedModel = model
        self.isLoading = wasLoading

        guard !wasLoading else { return }
        self.save()
        self.updateConfigFile()
        self.services?.refreshAgentService()
    }

    func replaceCustomProvider(_ provider: Configuration.CustomProvider, id: String) throws {
        let wasSelected = self.customProviderIdentifier(matching: self.selectedProvider) == id
        try self.configManager.addCustomProvider(provider, id: id)

        if wasSelected {
            if let models = provider.models,
               !models.isEmpty,
               models[self.selectedModel] == nil,
               let replacementModel = models.keys.min()
            {
                let wasLoading = self.isLoading
                self.isLoading = true
                self.selectedModel = replacementModel
                self.isLoading = wasLoading
                if !wasLoading {
                    self.save()
                }
            }
        }

        self.updateConfigFile()
        self.services?.refreshAgentService()
    }

    func removeCustomProvider(id: String) throws {
        let wasSelected = self.selectedProvider.caseInsensitiveCompare(id) == .orderedSame
        try self.configManager.removeCustomProvider(id: id)

        if wasSelected {
            let wasLoading = self.isLoading
            self.isLoading = true
            self.selectedProvider = "anthropic"
            self.selectedModel = self.defaultModel(for: "anthropic")
            self.isLoading = wasLoading

            if !wasLoading {
                self.save()
            }
        }

        self.updateConfigFile(excludingProvider: id)
        self.services?.refreshAgentService()
    }

    func getCustomProvider(id: String) -> Configuration.CustomProvider? {
        self.configManager.getCustomProvider(id: id)
    }

    func testCustomProvider(id: String) async -> (success: Bool, error: String?) {
        await self.configManager.testCustomProvider(id: id)
    }

    func discoverModelsForCustomProvider(id: String) async -> (models: [String], error: String?) {
        await self.configManager.discoverModelsForCustomProvider(id: id)
    }

    private func namespaced(_ key: String) -> String {
        "\(self.keyPrefix)\(key)"
    }

    private func nonZeroDouble(forKey key: String, fallback: Double) -> Double {
        let value = self.userDefaults.double(forKey: self.namespaced(key))
        return value == 0 ? fallback : value
    }

    private func nonZeroInt(forKey key: String, fallback: Int) -> Int {
        let value = self.userDefaults.integer(forKey: self.namespaced(key))
        return value == 0 ? fallback : value
    }

    private func valueOrDefault(key: String, defaultValue: Bool) -> Bool {
        let namespacedKey = self.namespaced(key)
        if self.userDefaults.object(forKey: namespacedKey) == nil {
            self.userDefaults.set(defaultValue, forKey: namespacedKey)
            return defaultValue
        }
        return self.userDefaults.bool(forKey: namespacedKey)
    }

    private func ensureTrueFlag(markerKey: String, value: inout Bool) {
        let namespacedKey = self.namespaced(markerKey)
        if !self.userDefaults.bool(forKey: namespacedKey) {
            value = true
            self.userDefaults.set(true, forKey: namespacedKey)
        }
    }

    private func detectedEnvironmentVariable(for keys: [String]) -> String? {
        let environment = ProcessInfo.processInfo.environment
        return keys.first { key in
            guard let value = environment[key] else { return false }
            return !value.isEmpty
        }
    }

    private func hasCredentialValue(forAny keys: [String]) -> Bool {
        keys.contains { key in
            guard let value = self.configManager.credentialValue(for: key) else { return false }
            return !value.isEmpty
        }
    }

    private func firstConfiguredModel(in providers: String, matching selectedProvider: String) -> String? {
        let selectedProvider = self.canonicalProviderIdentifier(selectedProvider)
        for entry in providers.split(separator: ",") {
            let parts = entry.trimmingCharacters(in: .whitespaces).split(separator: "/", maxSplits: 1)
            guard parts.count == 2,
                  self.canonicalProviderIdentifier(String(parts[0])) == selectedProvider
            else { continue }
            return String(parts[1])
        }
        return nil
    }

    private func configuredModelForCustomProvider(id: String) -> String? {
        guard let provider = self.getCustomProvider(id: id), provider.enabled else { return nil }

        if let modelID = provider.models?.keys.min() {
            return modelID
        }

        if let configuredDefault = self.configManager.getAgentModel() {
            let selection = self.providerQualifiedModelSelection(from: configuredDefault)
            let configuredProvider = selection.provider ??
                self.canonicalProviderIdentifier(self.configManager.getSelectedProvider())
            if configuredProvider.caseInsensitiveCompare(id) == .orderedSame, !selection.model.isEmpty {
                return selection.model
            }
        }

        return self.firstConfiguredModel(
            in: self.configManager.getAIProviders(),
            matching: id)
    }

    private func environmentCredentialValue(for provider: Provider) -> String? {
        let keys = self.credentialKeys(for: provider)
        return self.detectedEnvironmentVariable(for: keys).flatMap { ProcessInfo.processInfo.environment[$0] }
    }

    private func defaultModel(for provider: String) -> String {
        if let customProviderID = self.customProviderIdentifier(matching: provider),
           self.customProviders[customProviderID] != nil
        {
            return self.configuredModelForCustomProvider(id: customProviderID) ?? ""
        }

        return switch provider {
        case "openai":
            "gpt-5.5"
        case "anthropic":
            "claude-opus-4-8"
        case "grok":
            "grok-4.3"
        case "google":
            "gemini-3.5-flash"
        case "minimax":
            "MiniMax-M2.7"
        case "minimax-cn", "minimax_cn", "minimaxi":
            "MiniMax-M2.7"
        case "lmstudio", "lm-studio":
            "openai/gpt-oss-120b"
        default:
            "llava:latest"
        }
    }

    private func agentDefaultModel() -> String {
        if let customProviderID = self.customProviderIdentifier(matching: self.selectedProvider) {
            return "\(customProviderID)/\(self.selectedModel)"
        }

        return switch self.selectedProvider {
        case "minimax-cn", "minimax_cn", "minimaxi":
            "minimax-cn/\(self.selectedModel)"
        case "openrouter":
            "openrouter/\(self.selectedModel)"
        default:
            self.selectedModel
        }
    }

    private func provider(forCredentialKey key: String) -> Provider? {
        switch key {
        case "OPENAI_API_KEY":
            .openai
        case "ANTHROPIC_API_KEY":
            .anthropic
        case "X_AI_API_KEY", "XAI_API_KEY", "GROK_API_KEY":
            .grok
        case "GEMINI_API_KEY", "GOOGLE_API_KEY":
            .google
        case "MINIMAX_API_KEY":
            .minimax
        case "MINIMAX_CN_API_KEY":
            .minimaxCN
        default:
            nil
        }
    }

    private func credentialKeys(for provider: Provider) -> [String] {
        switch provider {
        case .openai:
            ["OPENAI_API_KEY"]
        case .anthropic:
            ["ANTHROPIC_API_KEY"]
        case .grok:
            ["X_AI_API_KEY", "XAI_API_KEY", "GROK_API_KEY"]
        case .google:
            ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .minimax:
            ["MINIMAX_API_KEY"]
        case .minimaxCN:
            ["MINIMAX_CN_API_KEY"]
        default:
            []
        }
    }

    private func canonicalProviderIdentifier(_ provider: String) -> String {
        if let customProviderID = self.customProviderIdentifier(matching: provider) {
            return customProviderID
        }
        return Self.canonicalProviderIdentifier(provider)
    }

    private func customProviderIdentifier(matching provider: String) -> String? {
        let matches = self.customProviders.filter {
            $0.value.enabled && $0.key.caseInsensitiveCompare(provider) == .orderedSame
        }
        return matches.count == 1 ? matches.first?.key : nil
    }

    private static func canonicalProviderIdentifier(_ provider: String) -> String {
        switch provider.lowercased() {
        case "openai", "anthropic", "minimax", "ollama", "openrouter":
            provider.lowercased()
        case "gemini", "google":
            "google"
        case "xai", "grok":
            "grok"
        case "minimax-cn", "minimax_cn", "minimaxi":
            "minimax-cn"
        case "lm-studio", "lmstudio":
            "lmstudio"
        default:
            provider
        }
    }

    private func providerQualifiedModelSelection(from rawModel: String) -> (provider: String?, model: String) {
        let parts = rawModel.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return (nil, rawModel)
        }

        if let customProviderID = self.customProviderIdentifier(matching: parts[0]) {
            return (customProviderID, parts[1])
        }

        let provider = Self.canonicalProviderIdentifier(parts[0])
        let configuredProviders = Set(
            self.configManager.getAIProviders()
                .split(separator: ",")
                .compactMap { entry -> String? in
                    let provider = entry
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: "/", maxSplits: 1)
                        .first
                        .map(String.init)
                    return provider.map(self.canonicalProviderIdentifier)
                })
        if configuredProviders.contains(provider) ||
            provider == self.canonicalProviderIdentifier(self.selectedProvider) ||
            (!self.configManager.hasExplicitAIProviderList() && Self.isKnownProviderIdentifier(provider))
        {
            return (provider, parts[1])
        }

        return (nil, rawModel)
    }

    private static func isKnownProviderIdentifier(_ provider: String) -> Bool {
        switch provider {
        case "openai", "anthropic", "grok", "google", "minimax", "minimax-cn", "ollama", "lmstudio", "openrouter":
            true
        default:
            false
        }
    }

    private static let animationKeys: [String] = [
        "screenshotFlashEnabled", "clickAnimationEnabled", "typeAnimationEnabled",
        "scrollAnimationEnabled", "mouseTrailEnabled", "swipePathEnabled",
        "hotkeyOverlayEnabled", "appLifecycleEnabled", "windowOperationEnabled",
        "watchCaptureHUDEnabled", "menuNavigationEnabled", "dialogInteractionEnabled", "spaceTransitionEnabled",
        "ghostEasterEggEnabled",
    ]
}
