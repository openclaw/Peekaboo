import Foundation
import PeekabooCore

/// Re-use the Configuration type from PeekabooCore
typealias Configuration = PeekabooCore.Configuration

/// CLI-specific configuration manager that extends PeekabooCore's ConfigurationManager
/// with additional CLI-specific functionality.
@MainActor
final class ConfigurationManager: @unchecked Sendable {
    static let shared = ConfigurationManager()

    /// Use PeekabooCore's ConfigurationManager for core functionality
    private let coreManager = PeekabooCore.ConfigurationManager.shared

    private init() {}

    // MARK: - Delegate to Core Manager

    /// Base directory for all Peekaboo configuration
    static var baseDir: String {
        PeekabooCore.ConfigurationManager.baseDir
    }

    /// Legacy configuration directory (for migration)
    static var legacyConfigDir: String {
        PeekabooCore.ConfigurationManager.legacyConfigDir
    }

    /// Default configuration file path
    static var configPath: String {
        PeekabooCore.ConfigurationManager.configPath
    }

    /// Legacy configuration file path (for migration)
    static var legacyConfigPath: String {
        PeekabooCore.ConfigurationManager.legacyConfigPath
    }

    /// Credentials file path
    static var credentialsPath: String {
        PeekabooCore.ConfigurationManager.credentialsPath
    }

    /// Migrate from legacy configuration if needed
    func migrateIfNeeded() throws {
        // Migrate from legacy configuration if needed
        try self.coreManager.migrateIfNeeded()
    }

    /// Load configuration from file
    func loadConfiguration() -> Configuration? {
        // Load configuration from file
        self.coreManager.loadConfiguration()
    }

    /// Get cached configuration, loading only if needed.
    func getConfiguration() -> Configuration? {
        self.coreManager.getConfiguration()
    }

    /// Strip comments from JSONC content
    func stripJSONComments(from json: String) -> String {
        // Strip comments from JSONC content
        self.coreManager.stripJSONComments(from: json)
    }

    /// Expand environment variables in the format ${VAR_NAME}
    func expandEnvironmentVariables(in text: String) -> String {
        // Expand environment variables in the format ${VAR_NAME}
        self.coreManager.expandEnvironmentVariables(in: text)
    }

    /// Get AI providers with proper precedence
    func getAIProviders(cliValue: String? = nil) -> String {
        // Get AI providers with proper precedence
        self.coreManager.getAIProviders(cliValue: cliValue)
    }

    /// Get OpenAI API key with proper precedence
    func getOpenAIAPIKey() -> String? {
        // Get OpenAI API key with proper precedence
        self.coreManager.getOpenAIAPIKey()
    }

    /// Get the TypeSafe API key for Jev verdicts with proper precedence
    func getTypeSafeAPIKey() -> String? {
        self.coreManager.getTypeSafeAPIKey()
    }

    /// Get Ollama base URL with proper precedence
    func getOllamaBaseURL() -> String {
        // Get Ollama base URL with proper precedence
        self.coreManager.getOllamaBaseURL()
    }

    /// Get default save path with proper precedence
    func getDefaultSavePath(cliValue: String? = nil) -> String {
        // Get default save path with proper precedence
        self.coreManager.getDefaultSavePath(cliValue: cliValue)
    }

    /// Get log level with proper precedence
    func getLogLevel() -> String {
        // Get log level with proper precedence
        self.coreManager.getLogLevel()
    }

    /// Get log path with proper precedence
    func getLogPath() -> String {
        // Get log path with proper precedence
        self.coreManager.getLogPath()
    }

    /// Create default configuration file
    func createDefaultConfiguration() throws {
        // Create default configuration file
        try self.coreManager.createDefaultConfiguration()
    }

    /// Set or update a credential
    func setCredential(key: String, value: String) throws {
        // Set or update a credential
        try self.coreManager.setCredential(key: key, value: value)
    }

    /// Get configuration value with precedence
    func getValue<T>(
        cliValue: T?,
        envVar: String?,
        configValue: T?,
        defaultValue: T
    ) -> T {
        // Get configuration value with precedence
        self.coreManager.getValue(
            cliValue: cliValue,
            envVar: envVar,
            configValue: configValue,
            defaultValue: defaultValue
        )
    }

    // MARK: - Custom Provider Management

    /// Add a custom AI provider to the configuration
    func addCustomProvider(_ provider: Configuration.CustomProvider, id: String) throws {
        // Add a custom AI provider to the configuration
        try self.coreManager.addCustomProvider(provider, id: id)
    }

    /// Remove a custom provider from the configuration
    func removeCustomProvider(id: String) throws {
        // Remove a custom provider from the configuration
        try self.coreManager.removeCustomProvider(id: id)
    }

    /// Get a specific custom provider by ID
    func getCustomProvider(id: String) -> Configuration.CustomProvider? {
        // Get a specific custom provider by ID
        self.coreManager.getCustomProvider(id: id)
    }

    /// List all configured custom providers
    func listCustomProviders() -> [String: Configuration.CustomProvider] {
        // List all configured custom providers
        self.coreManager.listCustomProviders()
    }

    /// Test connection to a custom provider
    func testCustomProvider(id: String) async -> (success: Bool, error: String?) {
        // Test connection to a custom provider
        await self.coreManager.testCustomProvider(id: id)
    }

    /// Discover available models from a custom provider
    func discoverModelsForCustomProvider(id: String) async -> (models: [String], error: String?) {
        // Discover available models from a custom provider
        await self.coreManager.discoverModelsForCustomProvider(id: id)
    }
}
