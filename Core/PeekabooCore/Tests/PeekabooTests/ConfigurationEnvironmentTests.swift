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

    @Test(arguments: ["prefix", "escaped\"quote\\", "\u{0301}//literal/*path*/"])
    func `configuration interpolation preserves JSON strings and scalar quote boundaries`(prefix: String) throws {
        let key = "PEEKABOO_OWNED_QUOTED_FOLDER"
        let missing = "PEEKABOO_OWNED_UNSET_FOLDER_972"
        let folder = "/owned/folder\"quoted\\name\nnext\t🦞e\u{0301}"
        setenv(key, folder, 1)
        unsetenv(missing)
        defer { unsetenv(key); unsetenv(missing) }

        try withIsolatedConfigurationEnvironment { configDir in
            let configPath = configDir.appendingPathComponent("config.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let template = "\(prefix)/${\(key)}${\(key)}/suffix/${\(missing)}"
            let json = try encoder.encode(["defaults": ["savePath": template]])
            try json.write(to: configPath)
            let config = self.manager.loadConfiguration()
            #expect(config?.defaults?.savePath == "\(prefix)/\(folder)\(folder)/suffix/${\(missing)}")
        }
    }

    @Test(arguments: ["\u{0301}leading", "\u{FE0F}variation", "🦞e\u{0301}", ""])
    func `configuration interpolation retains leading environment scalars`(value: String) throws {
        let key = "PEEKABOO_OWNED_LEADING_SCALAR_972"
        let previous = getenv(key).map { String(cString: $0) }
        setenv(key, value, 1)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        try withIsolatedConfigurationEnvironment { configDir in
            let configPath = configDir.appendingPathComponent("config.json")
            let json = try JSONEncoder().encode(["defaults": ["savePath": "${\(key)}"]])
            try json.write(to: configPath)
            #expect(self.manager.loadConfiguration()?.defaults?.savePath == value)
        }
    }

    @Test
    func `configuration interpolation keeps numeric environment substitutions unquoted`() throws {
        let key = "PEEKABOO_OWNED_NUMERIC_LIMIT"
        setenv(key, "42", 1)
        defer { unsetenv(key) }

        try withIsolatedConfigurationEnvironment { configDir in
            let configPath = configDir.appendingPathComponent("config.json")
            try "{\"agent\":{\"maxTokens\":${\(key)}}}"
                .write(to: configPath, atomically: true, encoding: .utf8)
            #expect(self.manager.loadConfiguration()?.agent?.maxTokens == 42)
        }
    }

    @Test(arguments: ["type", "syntax", "number"])
    func `configuration decoding warnings omit expanded credential values`(failure: String) throws {
        let key = "PEEKABOO_OWNED_FAKE_CONFIG_TOKEN"
        let token = "OWNED_NOT_A_REAL_CREDENTIAL"
        setenv(key, token, 1)
        defer { unsetenv(key) }

        try withIsolatedConfigurationEnvironment { configDir in
            let configPath = configDir.appendingPathComponent("config.json")
            let credential = #"{"aiProviders":{"openaiApiKey":"${PEEKABOO_OWNED_FAKE_CONFIG_TOKEN}"}"#
            let suffix = switch failure {
            case "type": #","agent":{"maxTokens":"wrong-shape"}}"#
            case "number": #","agent":{"maxTokens":1e999999}}"#
            default: #","agent":]"#
            }
            let json = credential + suffix
            try json.write(to: configPath, atomically: true, encoding: .utf8)
            var loaded = true
            let warning = try captureConfigurationWarnings(in: configDir) {
                loaded = self.manager.loadConfigurationFromPath(configPath.path) != nil
            }
            #expect(!loaded)
            #expect(warning.contains(failure == "type" ? "agent.maxTokens" : "Data corrupted"))
            #expect(!warning.contains(token))
            #expect(!warning.contains("Cleaned JSON"))
            #expect(!warning.contains("Underlying error"))
        }
    }

    @Test
    func `plain text interpolation does not JSON escape environment values`() {
        let key = "PEEKABOO_OWNED_PLAIN_FOLDER"
        let value = "folder\"quoted\\name\nnext"
        setenv(key, value, 1)
        defer { unsetenv(key) }

        #expect(self.manager.expandEnvironmentVariables(in: "prefix ${\(key)} suffix") == "prefix \(value) suffix")
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
    func `Anthropic custom provider probe uses configured model`() {
        let configured = Configuration.CustomProvider(
            name: "Compatible Endpoint",
            type: .anthropic,
            options: .init(baseURL: "https://api.example.com", apiKey: "test-key"),
            models: [
                "claude-opus-4-8": .init(name: "Claude Opus 4.8"),
            ])
        let unconfigured = Configuration.CustomProvider(
            name: "Compatible Endpoint",
            type: .anthropic,
            options: .init(baseURL: "https://api.example.com", apiKey: "test-key"))

        #expect(ConfigurationManager.anthropicProbeModel(for: configured) == "claude-opus-4-8")
        #expect(ConfigurationManager.anthropicProbeModel(for: unconfigured) == "claude-opus-5")
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

private func captureConfigurationWarnings(in directory: URL, _ body: () throws -> Void) throws -> String {
    let path = directory.appendingPathComponent("owned-warning-output")
    try Data().write(to: path)
    defer { try? FileManager.default.removeItem(at: path) }
    let output = try FileHandle(forUpdating: path)
    defer { try? output.close() }
    func capture() throws {
        let original = dup(STDOUT_FILENO)
        guard original >= 0 else { throw POSIXError(.EIO) }
        defer { close(original) }
        fflush(nil)
        guard dup2(output.fileDescriptor, STDOUT_FILENO) >= 0 else { throw POSIXError(.EIO) }
        defer { fflush(nil); #expect(dup2(original, STDOUT_FILENO) >= 0) }
        try body()
    }
    try capture()
    try output.seek(toOffset: 0)
    return try String(data: output.readToEnd() ?? Data(), encoding: .utf8) ?? ""
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
