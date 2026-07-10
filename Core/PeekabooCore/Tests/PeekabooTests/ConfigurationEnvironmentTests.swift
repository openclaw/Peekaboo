import Darwin
import Foundation
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

@Suite(.serialized)
struct ConfigurationManagerEnvironmentTests {
    private let manager = ConfigurationManager.shared

    @Test
    func `expandEnvironmentVariables uses process environment when ConfigReader unavailable`() {
        let key = "PEEKABOO_ENV_TEST"
        setenv(key, "peekaboo-success", 1)
        defer { unsetenv(key) }

        let expanded = self.manager.expandEnvironmentVariables(in: "${\(key)}")
        #expect(expanded == "peekaboo-success")
    }

    @Test
    func `getValue prefers environment before defaults`() {
        let key = "PEEKABOO_ENV_CHOICE"
        setenv(key, "env-choice", 1)
        defer { unsetenv(key) }

        let resolved: String = self.manager.getValue(
            cliValue: nil,
            envVar: key,
            configValue: nil,
            defaultValue: "fallback")
        #expect(resolved == "env-choice")
    }

    @Test
    func `reloadConfigurationIfChanged picks up out-of-process config edits`() throws {
        try withIsolatedConfigurationEnvironment { configDir in
            let configPath = configDir.appendingPathComponent("config.json")

            func writeConfig(elementBoxes: Bool, modifiedAt: Date? = nil) throws {
                let json = """
                { "visualizer": { "elementDetectionEnabled": \(elementBoxes) } }
                """
                try json.write(to: configPath, atomically: true, encoding: .utf8)
                if let modifiedAt {
                    try FileManager.default.setAttributes(
                        [.modificationDate: modifiedAt],
                        ofItemAtPath: configPath.path)
                }
            }

            // Simulate a long-running process that loaded the config at startup.
            try writeConfig(elementBoxes: false)
            _ = self.manager.loadConfiguration()
            #expect(self.manager.getConfiguration()?.visualizer?.elementDetectionEnabled == false)

            // Another process (the Mac app) flips the toggle in config.json.
            try writeConfig(elementBoxes: true, modifiedAt: Date().addingTimeInterval(5))

            // Without a reload the cached value is stale — this is the bug the fix addresses.
            #expect(self.manager.getConfiguration()?.visualizer?.elementDetectionEnabled == false)

            // The cheap mtime-guarded reload observes the change.
            self.manager.reloadConfigurationIfChanged()
            #expect(self.manager.getConfiguration()?.visualizer?.elementDetectionEnabled == true)
        }
    }

    @Test
    func `getGeminiAPIKey accepts compatibility aliases`() {
        let previousGeminiAPIKey = getenv("GEMINI_API_KEY").map { String(cString: $0) }
        let previousGoogleAPIKey = getenv("GOOGLE_API_KEY").map { String(cString: $0) }
        unsetenv("GEMINI_API_KEY")
        setenv("GOOGLE_API_KEY", "google-api-key", 1)
        defer {
            if let previousGeminiAPIKey {
                setenv("GEMINI_API_KEY", previousGeminiAPIKey, 1)
            } else {
                unsetenv("GEMINI_API_KEY")
            }
            if let previousGoogleAPIKey {
                setenv("GOOGLE_API_KEY", previousGoogleAPIKey, 1)
            } else {
                unsetenv("GOOGLE_API_KEY")
            }
        }

        self.manager.resetForTesting()
        #expect(self.manager.getGeminiAPIKey() == "google-api-key")
    }

    @Test
    func `getGeminiAPIKey ignores ADC credential paths`() {
        let previousGeminiAPIKey = getenv("GEMINI_API_KEY").map { String(cString: $0) }
        let previousGoogleAPIKey = getenv("GOOGLE_API_KEY").map { String(cString: $0) }
        let previousGoogleCredentials = getenv("GOOGLE_APPLICATION_CREDENTIALS").map { String(cString: $0) }
        unsetenv("GEMINI_API_KEY")
        unsetenv("GOOGLE_API_KEY")
        setenv("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/service-account.json", 1)
        defer {
            if let previousGeminiAPIKey {
                setenv("GEMINI_API_KEY", previousGeminiAPIKey, 1)
            } else {
                unsetenv("GEMINI_API_KEY")
            }
            if let previousGoogleAPIKey {
                setenv("GOOGLE_API_KEY", previousGoogleAPIKey, 1)
            } else {
                unsetenv("GOOGLE_API_KEY")
            }
            if let previousGoogleCredentials {
                setenv("GOOGLE_APPLICATION_CREDENTIALS", previousGoogleCredentials, 1)
            } else {
                unsetenv("GOOGLE_APPLICATION_CREDENTIALS")
            }
        }

        self.manager.resetForTesting()
        #expect(self.manager.getGeminiAPIKey() == nil)
    }

    @Test
    func `getKimiAPIKey prefers either environment alias over stored credentials`() throws {
        let keys = ["MOONSHOT_API_KEY", "KIMI_API_KEY"]
        let previous = keys.reduce(into: [String: String]()) { values, key in
            if let value = getenv(key) {
                values[key] = String(cString: value)
            }
        }
        keys.forEach { unsetenv($0) }
        defer {
            for key in keys {
                if let value = previous[key] {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        try withIsolatedConfigurationEnvironment { _ in
            try self.manager.saveCredentials(["MOONSHOT_API_KEY": "stored-primary-key"])
            setenv("KIMI_API_KEY", "environment-alias-key", 1)

            #expect(self.manager.getKimiAPIKey() == "environment-alias-key")
        }
    }

    @Test
    func `getSelectedProvider canonicalizes Google aliases from config`() throws {
        try withIsolatedConfigurationEnvironment { configDir in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "gemini/gemini-3-flash,ollama/llava:latest"
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            self.manager.resetForTesting()
            _ = self.manager.loadConfiguration()
            #expect(self.manager.getSelectedProvider() == "google")
        }
    }

    @Test
    func `custom provider apiKey env references stay literal when config is saved`() throws {
        let key = "PEEKABOO_CUSTOM_PROVIDER_KEY"
        setenv(key, "secret-that-must-not-be-written", 1)
        defer { unsetenv(key) }

        try withIsolatedConfigurationEnvironment { configDir in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "customProviders": {
                "openrouter": {
                  "name": "OpenRouter",
                  "type": "openai",
                  "options": {
                    "baseURL": "https://openrouter.ai/api/v1",
                    "apiKey": "${\(key)}"
                  },
                  "enabled": true
                }
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            self.manager.resetForTesting()
            let config = self.manager.loadConfiguration()
            #expect(config?.customProviders?["openrouter"]?.options.apiKey == "${\(key)}")

            let provider = Configuration.CustomProvider(
                name: "Other",
                type: .openai,
                options: .init(baseURL: "https://api.example.com/v1", apiKey: "literal-key"))
            try self.manager.addCustomProvider(provider, id: "other")

            let saved = try String(contentsOf: configPath, encoding: .utf8)
            #expect(saved.contains("${\(key)}"))
            #expect(!saved.contains("secret-that-must-not-be-written"))
        }
    }

    @Test
    func `credential references resolve shell style and legacy env forms`() throws {
        try withIsolatedConfigurationEnvironment { _ in
            unsetenv("PEEKABOO_STORED_PROVIDER_KEY")
            self.manager.resetForTesting()
            try self.manager.saveCredentials(["PEEKABOO_STORED_PROVIDER_KEY": "stored-secret"])

            #expect(self.manager.resolveCredentialReference("${PEEKABOO_STORED_PROVIDER_KEY}") == "stored-secret")
            #expect(self.manager.resolveCredentialReference("{env:PEEKABOO_STORED_PROVIDER_KEY}") == "stored-secret")
            #expect(self.manager.resolveCredentialReference("literal-secret") == "literal-secret")
        }
    }
}

private func withIsolatedConfigurationEnvironment(_ body: (URL) throws -> Void) throws {
    let fileManager = FileManager.default
    let configDir = fileManager.temporaryDirectory
        .appendingPathComponent("peekaboo-config-tests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)

    let previousConfigDir = getenv("PEEKABOO_CONFIG_DIR").map { String(cString: $0) }
    let previousDisableMigration = getenv("PEEKABOO_CONFIG_DISABLE_MIGRATION").map { String(cString: $0) }
    setenv("PEEKABOO_CONFIG_DIR", configDir.path, 1)
    setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
    ConfigurationManager.shared.resetForTesting()

    defer {
        if let previousConfigDir {
            setenv("PEEKABOO_CONFIG_DIR", previousConfigDir, 1)
        } else {
            unsetenv("PEEKABOO_CONFIG_DIR")
        }
        if let previousDisableMigration {
            setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", previousDisableMigration, 1)
        } else {
            unsetenv("PEEKABOO_CONFIG_DISABLE_MIGRATION")
        }
        ConfigurationManager.shared.resetForTesting()
        try? fileManager.removeItem(at: configDir)
    }

    try body(configDir)
}
