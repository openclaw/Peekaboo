import Foundation
import PeekabooFoundation
import Tachikoma

/// Manages configuration loading and precedence resolution.
///
/// `ConfigurationManager` implements a hierarchical configuration system with the following
/// precedence (highest to lowest):
/// 1. Command-line arguments
/// 2. Environment variables
/// 3. Configuration file (`~/.peekaboo/config.json`)
/// 4. Credentials file (`~/.peekaboo/credentials`)
/// 5. Built-in defaults
///
/// The manager supports JSONC format (JSON with Comments) and environment variable
/// expansion using `${VAR_NAME}` syntax. Sensitive credentials are stored separately
/// in a credentials file with restricted permissions.
public final class ConfigurationManager: @unchecked Sendable {
    public static let shared = ConfigurationManager()

    /// Base directory for all Peekaboo configuration
    ///
    /// Can be overridden in tests or automation via `PEEKABOO_CONFIG_DIR`.
    public static var baseDir: String {
        if let override = ProcessInfo.processInfo.environment["PEEKABOO_CONFIG_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return NSString(string: override).expandingTildeInPath
        }
        return NSString(string: "~/.peekaboo").expandingTildeInPath
    }

    /// Legacy configuration directory (for migration)
    public static var legacyConfigDir: String {
        NSString(string: "~/.config/peekaboo").expandingTildeInPath
    }

    /// Default configuration file path
    public static var configPath: String {
        "\(baseDir)/config.json"
    }

    /// Legacy configuration file path (for migration)
    public static var legacyConfigPath: String {
        "\(legacyConfigDir)/config.json"
    }

    /// Credentials file path
    public static var credentialsPath: String {
        "\(baseDir)/credentials"
    }

    public static func configureTachikomaProfileDirectory() {
        TachikomaConfiguration.profileDirectoryName = self.baseDir
    }

    /// Loaded configuration
    var configuration: Configuration?

    /// Modification date of `config.json` when it was last read into `configuration`.
    /// `reloadConfigurationIfChanged()` uses it to detect out-of-process edits (e.g. the
    /// Mac app flipping a visualizer toggle) without re-parsing the file on every call.
    private var configFileModificationDate: Date?

    /// Cached credentials
    var credentials: [String: String] = [:]

    private init() {
        // Load configuration on init, but don't crash if it fails
        Self.configureTachikomaProfileDirectory()
        _ = self.loadConfiguration()
    }

    #if DEBUG
    /// Clear cached configuration/credentials so tests can re-seed with a different base dir.
    public func resetForTesting() {
        self.configuration = nil
        self.configFileModificationDate = nil
        self.credentials = [:]
    }
    #endif

    /// Migrate from legacy configuration if needed
    public func migrateIfNeeded() throws {
        // Allow tests or automation to disable migration to isolate temporary config roots.
        if let disable = ProcessInfo.processInfo.environment["PEEKABOO_CONFIG_DISABLE_MIGRATION"],
           disable.lowercased() == "1" || disable.lowercased() == "true"
        {
            return
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: Self.legacyConfigPath),
              !fileManager.fileExists(atPath: Self.configPath)
        else {
            return
        }

        try fileManager.createDirectory(
            atPath: Self.baseDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        try fileManager.copyItem(
            atPath: Self.legacyConfigPath,
            toPath: Self.configPath)

        if let config = self.loadConfigurationFromPath(Self.configPath) {
            try self.migrateHardcodedCredentials(from: config)
        }

        let migrationMessage =
            "\(AgentDisplayTokens.Status.success) Migrated configuration from \(Self.legacyConfigPath) " +
            "to \(Self.configPath)"
        print(migrationMessage)
    }

    /// Load configuration from file
    public func loadConfiguration() -> Configuration? {
        Self.configureTachikomaProfileDirectory()
        try? self.migrateIfNeeded()
        self.loadCredentials()
        self.configuration = self.loadConfigurationFromPath(Self.configPath)
        self.configFileModificationDate = Self.modificationDate(ofFileAtPath: Self.configPath)
        return self.configuration
    }

    /// Get the current configuration.
    ///
    /// Returns the loaded configuration or loads it if not already loaded.
    public func getConfiguration() -> Configuration? {
        if self.configuration == nil {
            _ = self.loadConfiguration()
        }
        return self.configuration
    }

    private func migrateHardcodedCredentials(from config: Configuration) throws {
        guard let apiKey = config.aiProviders?.openaiApiKey,
              !apiKey.hasPrefix("${"),
              !apiKey.isEmpty
        else {
            return
        }

        try self.saveCredentials(["OPENAI_API_KEY": apiKey])

        var updatedConfig = config
        updatedConfig.aiProviders?.openaiApiKey = nil
        let data = try JSONCoding.encoder.encode(updatedConfig)
        try data.write(to: URL(fileURLWithPath: Self.configPath), options: .atomic)
    }

    /// Reload `config.json` only if it changed on disk since the last load.
    ///
    /// Long-running processes (e.g. an MCP server) cache the configuration at startup,
    /// so a config value flipped in another process — like the Mac app writing
    /// `visualizer.elementDetectionEnabled` — would otherwise be ignored until restart.
    /// The steady-state cost is a single `stat`; the parse only runs when the file's
    /// modification date actually changes, keeping this safe on hot paths like `see`.
    public func reloadConfigurationIfChanged() {
        let currentDate = Self.modificationDate(ofFileAtPath: Self.configPath)
        // Reload when the file appeared, disappeared, or was rewritten.
        guard currentDate != self.configFileModificationDate else { return }
        _ = self.loadConfiguration()
    }

    private static func modificationDate(ofFileAtPath path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
