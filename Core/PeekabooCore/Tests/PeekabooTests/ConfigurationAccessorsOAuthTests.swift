import Darwin
import Foundation
import Tachikoma
import Testing
@testable import PeekabooAutomation
@testable import PeekabooCore

/// Regression tests for `getOpenAIAPIKey()` / `getAnthropicAPIKey()` and
/// `applyAIProviderKeys()` to guarantee that OAuth access tokens stored in
/// the credentials file (e.g. `ANTHROPIC_ACCESS_TOKEN` written by
/// `peekaboo config login anthropic`) do NOT leak into the API-key code path.
///
/// Before this regression test existed, `getAnthropicAPIKey()` returned any
/// valid `ANTHROPIC_ACCESS_TOKEN` from the credentials file, which then flowed
/// through `applyAIProviderKeys()` → `TachikomaConfiguration.setAPIKey(for:
/// .anthropic)` and ultimately the Anthropic provider sent the OAuth token as
/// `x-api-key`, producing `401 invalid x-api-key`. See openclaw/Peekaboo#44.
@Suite(.serialized)
struct ConfigurationAccessorsOAuthTests {
    private let manager = ConfigurationManager.shared

    /// Hosted CI only: this suite initializes ConfigurationManager.shared before its scoped helper.
    @Test
    func `Refresh clears only managed slots and never persists environment keys`() throws {
        try withIsolatedConfigurationEnvironment { configDir in
            self.unsetAllAnthropicEnv()
            self.unsetAllOpenAIEnv()
            self.unsetAllAliasedProviderEnv()
            unsetenv("MINIMAX_API_KEY")
            unsetenv("MINIMAX_CN_API_KEY")
            self.manager.resetForTesting()
            let configuration = TachikomaConfiguration(loadFromEnvironment: false)
            let managed: [Provider] = [.openai, .anthropic, .google, .grok, .minimax, .minimaxCN]
            for provider in managed {
                configuration.setAPIKey("synthetic-stale", for: provider)
            }
            configuration.setAPIKey("synthetic-unrelated", for: .mistral)
            self.manager.applyAIProviderKeys(to: configuration)
            #expect(managed.allSatisfy { configuration.getAPIKey(for: $0) == nil })
            let unrelatedSurvives = configuration.getAPIKey(for: .mistral) == "synthetic-unrelated"
            #expect(unrelatedSurvives)
            setenv("OPENAI_API_KEY", "synthetic-environment", 1)
            self.manager.applyAIProviderKeys(to: configuration)
            let environmentWins = configuration.getAPIKey(for: .openai) == "synthetic-environment"
            #expect(environmentWins)
            #expect(!FileManager.default.fileExists(atPath: configDir.appendingPathComponent("credentials").path))
        }
    }

    @Test
    func `getAnthropicAPIKey returns nil when only OAuth access token is stored`() throws {
        try withIsolatedConfigurationEnvironment { _ in
            self.unsetAllAnthropicEnv()
            self.manager.resetForTesting()
            try self.manager.saveCredentials([
                "ANTHROPIC_ACCESS_TOKEN": "placeholder-anthropic-oauth-access",
                "ANTHROPIC_REFRESH_TOKEN": "placeholder-anthropic-oauth-refresh",
                "ANTHROPIC_BETA_HEADER": "oauth-2025-04-20,claude-code-20250219",
                "ANTHROPIC_ACCESS_EXPIRES": String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970)),
            ])

            #expect(self.manager.getAnthropicAPIKey() == nil)
        }
    }

    @Test
    func `getAnthropicAPIKey returns API key from credentials when present`() throws {
        try withIsolatedConfigurationEnvironment { _ in
            self.unsetAllAnthropicEnv()
            self.manager.resetForTesting()
            try self.manager.saveCredentials([
                "ANTHROPIC_API_KEY": "placeholder-anthropic-api-key",
                "ANTHROPIC_ACCESS_TOKEN": "placeholder-anthropic-oauth-also-here",
            ])

            #expect(self.manager.getAnthropicAPIKey() == "placeholder-anthropic-api-key")
        }
    }

    @Test
    func `getOpenAIAPIKey returns nil when only OAuth access token is stored`() throws {
        try withIsolatedConfigurationEnvironment { _ in
            self.unsetAllOpenAIEnv()
            self.manager.resetForTesting()
            try self.manager.saveCredentials([
                "OPENAI_ACCESS_TOKEN": "openai-oauth-access-token",
                "OPENAI_REFRESH_TOKEN": "openai-oauth-refresh-token",
                "OPENAI_ACCESS_EXPIRES": String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970)),
            ])

            #expect(self.manager.getOpenAIAPIKey() == nil)
        }
    }

    @Test
    func `getOpenAIAPIKey returns API key from credentials when present`() throws {
        try withIsolatedConfigurationEnvironment { _ in
            self.unsetAllOpenAIEnv()
            self.manager.resetForTesting()
            try self.manager.saveCredentials([
                "OPENAI_API_KEY": "placeholder-openai-api-key",
                "OPENAI_ACCESS_TOKEN": "openai-oauth-token-also-here",
            ])

            #expect(self.manager.getOpenAIAPIKey() == "placeholder-openai-api-key")
        }
    }

    @Test
    func `OpenAI availability accepts an expired access token with a refresh token`() throws {
        try withIsolatedConfigurationEnvironment { _ in
            self.unsetAllOpenAIEnv()
            self.manager.resetForTesting()
            try self.manager.saveCredentials([
                "OPENAI_ACCESS_TOKEN": "expired-openai-oauth-access-token",
                "OPENAI_REFRESH_TOKEN": "openai-oauth-refresh-token",
                "OPENAI_ACCESS_EXPIRES": String(Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)),
            ])

            #expect(self.manager.hasOpenAIAuth())
        }
    }

    @Test
    func `Empty environment refresh token does not mask stored OpenAI refresh token`() throws {
        try withIsolatedConfigurationEnvironment { _ in
            self.unsetAllOpenAIEnv()
            self.manager.resetForTesting()
            try self.manager.saveCredentials([
                "OPENAI_ACCESS_TOKEN": "expired-openai-oauth-access-token",
                "OPENAI_REFRESH_TOKEN": "stored-openai-oauth-refresh-token",
                "OPENAI_ACCESS_EXPIRES": String(Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)),
            ])
            setenv("OPENAI_REFRESH_TOKEN", "", 1)

            #expect(self.manager.hasOpenAIAuth())
        }
    }

    @Test
    func `OAuth access and expiry stay paired by source`() throws {
        try withIsolatedConfigurationEnvironment { _ in
            self.unsetAllOpenAIEnv()
            self.manager.resetForTesting()
            try self.manager.saveCredentials([
                "OPENAI_ACCESS_EXPIRES": String(Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)),
            ])
            setenv("OPENAI_ACCESS_TOKEN", "valid-environment-access-token", 1)

            #expect(self.manager.getOpenAITranscriptionCredential() == "valid-environment-access-token")
            #expect(self.manager.hasOpenAIAuth())
        }
    }

    @Test
    func `getOpenAITranscriptionCredential returns OAuth access token when no API key is stored`() throws {
        try withIsolatedConfigurationEnvironment { _ in
            self.unsetAllOpenAIEnv()
            self.manager.resetForTesting()
            try self.manager.saveCredentials([
                "OPENAI_ACCESS_TOKEN": "openai-oauth-access-token",
                "OPENAI_ACCESS_EXPIRES": String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970)),
            ])

            #expect(self.manager.getOpenAITranscriptionCredential() == "openai-oauth-access-token")
        }
    }

    @Test
    func `getOpenAITranscriptionCredential prefers API key over OAuth access token`() throws {
        try withIsolatedConfigurationEnvironment { _ in
            self.unsetAllOpenAIEnv()
            self.manager.resetForTesting()
            try self.manager.saveCredentials([
                "OPENAI_API_KEY": "placeholder-openai-api-key",
                "OPENAI_ACCESS_TOKEN": "openai-oauth-access-token",
                "OPENAI_ACCESS_EXPIRES": String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970)),
            ])

            #expect(self.manager.getOpenAITranscriptionCredential() == "placeholder-openai-api-key")
        }
    }

    @Test
    func `OAuth availability uses same overridden config root as Tachikoma auth`() throws {
        try withIsolatedConfigurationEnvironment { configDir in
            self.unsetAllAnthropicEnv()
            self.manager.resetForTesting()
            try self.manager.saveCredentials([
                "ANTHROPIC_ACCESS_TOKEN": "placeholder-anthropic-oauth-access",
                "ANTHROPIC_BETA_HEADER": "oauth-2025-04-20",
                "ANTHROPIC_ACCESS_EXPIRES": String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970)),
            ])
            _ = self.manager.loadConfiguration()

            #expect(TachikomaConfiguration.profileDirectoryPath == configDir.path)
            #expect(self.manager.hasAnthropicAuth())
            if case let .bearer(token, betaHeader)? = TKAuthManager.shared.resolveAuth(for: .anthropic) {
                #expect(token == "placeholder-anthropic-oauth-access")
                #expect(betaHeader == "oauth-2025-04-20")
            } else {
                Issue.record("Expected Anthropic OAuth bearer auth from isolated config root")
            }
        }
    }

    @Test
    func `applyAIProviderKeys leaves anthropic slot empty when only OAuth token is stored`() throws {
        try withIsolatedConfigurationEnvironment { _ in
            self.unsetAllAnthropicEnv()
            self.manager.resetForTesting()
            try self.manager.saveCredentials([
                "ANTHROPIC_ACCESS_TOKEN": "placeholder-anthropic-oauth",
                "ANTHROPIC_BETA_HEADER": "oauth-2025-04-20",
                "ANTHROPIC_ACCESS_EXPIRES": String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970)),
            ])

            let configuration = TachikomaConfiguration(loadFromEnvironment: false)
            self.manager.applyAIProviderKeys(to: configuration)

            #expect(configuration.getAPIKey(for: .anthropic) == nil)
        }
    }

    @Test
    func `applyAIProviderKeys propagates real anthropic API key into Tachikoma`() throws {
        try withIsolatedConfigurationEnvironment { _ in
            self.unsetAllAnthropicEnv()
            self.manager.resetForTesting()
            try self.manager.saveCredentials([
                "ANTHROPIC_API_KEY": "placeholder-anthropic-key",
            ])

            let configuration = TachikomaConfiguration(loadFromEnvironment: false)
            self.manager.applyAIProviderKeys(to: configuration)

            #expect(configuration.getAPIKey(for: .anthropic) == "placeholder-anthropic-key")
        }
    }

    @Test
    func `applyAIProviderKeys propagates OpenRouter API key as custom provider key`() throws {
        try withIsolatedConfigurationEnvironment { _ in
            self.unsetAllOpenRouterEnv()
            self.manager.resetForTesting()
            try self.manager.saveCredentials([
                "OPENROUTER_API_KEY": "placeholder-openrouter-key",
            ])

            let configuration = TachikomaConfiguration(loadFromEnvironment: false)
            self.manager.applyAIProviderKeys(to: configuration)

            #expect(self.manager.getOpenRouterAPIKey() == "placeholder-openrouter-key")
            #expect(configuration.getAPIKey(for: "openrouter") == "placeholder-openrouter-key")
        }
    }

    @Test
    func `Provider aliases skip empty higher-priority environment values`() throws {
        try withIsolatedConfigurationEnvironment { _ in
            self.unsetAllAliasedProviderEnv()
            setenv("GEMINI_API_KEY", "", 1)
            setenv("GOOGLE_API_KEY", "placeholder-google-key", 1)
            setenv("X_AI_API_KEY", "", 1)
            setenv("XAI_API_KEY", "placeholder-xai-key", 1)
            self.manager.resetForTesting()

            #expect(self.manager.getGeminiAPIKey() == "placeholder-google-key")
            #expect(self.manager.getGrokAPIKey() == "placeholder-xai-key")
        }
    }

    @Test
    func `Grok aliases skip empty higher-priority stored credentials`() throws {
        try withIsolatedConfigurationEnvironment { _ in
            self.unsetAllAliasedProviderEnv()
            self.manager.resetForTesting()
            try self.manager.saveCredentials([
                "X_AI_API_KEY": "",
                "GROK_API_KEY": "placeholder-grok-key",
            ])

            #expect(self.manager.getGrokAPIKey() == "placeholder-grok-key")
        }
    }

    @Test
    func `Empty batch values clear existing aliases without losing unrelated entries`() throws {
        try withIsolatedConfigurationEnvironment { configDir in
            self.unsetAllAliasedProviderEnv()
            self.manager.resetForTesting()
            try self.manager.saveCredentials([
                "X_AI_API_KEY": "synthetic-old-alias",
                "UNRELATED_API_KEY": "synthetic-unrelated",
                "OPENAI_REFRESH_TOKEN": "synthetic-oauth==",
            ])
            try self.manager.saveCredentials([
                "X_AI_API_KEY": "",
                "GROK_API_KEY": "synthetic-fallback",
            ])
            let snapshot = try self.manager.readCredentialSnapshot()
            let clearedAndPreserved = snapshot == [
                "GROK_API_KEY": "synthetic-fallback",
                "UNRELATED_API_KEY": "synthetic-unrelated",
                "OPENAI_REFRESH_TOKEN": "synthetic-oauth==",
            ]
            #expect(clearedAndPreserved)
            let fallbackResolved = self.manager.getGrokAPIKey() == "synthetic-fallback"
            #expect(fallbackResolved)
            #expect(throws: CredentialFile.Failure.invalidData) {
                try self.manager.saveCredentials([
                    "GROK_API_KEY": "invalid\nvalue",
                    "UNRELATED_API_KEY": "synthetic-must-not-publish",
                ])
            }
            let rejectedBatchPreservedFile = try self.manager.readCredentialSnapshot() == snapshot
            #expect(rejectedBatchPreservedFile)
            try self.manager.saveCredentials([
                "GROK_API_KEY": "",
                "UNRELATED_API_KEY": "",
                "OPENAI_REFRESH_TOKEN": "",
            ])
            #expect(try self.manager.readCredentialSnapshot().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: configDir.appendingPathComponent("credentials").path))
        }
    }

    // MARK: - Helpers

    private func unsetAllAnthropicEnv() {
        unsetenv("ANTHROPIC_API_KEY")
        unsetenv("ANTHROPIC_ACCESS_TOKEN")
        unsetenv("ANTHROPIC_REFRESH_TOKEN")
        unsetenv("ANTHROPIC_ACCESS_EXPIRES")
        unsetenv("ANTHROPIC_BETA_HEADER")
    }

    private func unsetAllOpenAIEnv() {
        unsetenv("OPENAI_API_KEY")
        unsetenv("OPENAI_ACCESS_TOKEN")
        unsetenv("OPENAI_REFRESH_TOKEN")
        unsetenv("OPENAI_ACCESS_EXPIRES")
    }

    private func unsetAllOpenRouterEnv() {
        unsetenv("OPENROUTER_API_KEY")
    }

    private func unsetAllAliasedProviderEnv() {
        for key in ["GEMINI_API_KEY", "GOOGLE_API_KEY", "X_AI_API_KEY", "XAI_API_KEY", "GROK_API_KEY"] {
            unsetenv(key)
        }
    }
}

private func withIsolatedConfigurationEnvironment(_ body: (URL) throws -> Void) throws {
    let fileManager = FileManager.default
    let configDir = fileManager.temporaryDirectory
        .appendingPathComponent("peekaboo-config-tests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)

    let previousProfileDirectoryName = TachikomaConfiguration.profileDirectoryName
    let environmentKeys = [
        "PEEKABOO_CONFIG_DIR",
        "PEEKABOO_CONFIG_DISABLE_MIGRATION",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_ACCESS_TOKEN",
        "ANTHROPIC_REFRESH_TOKEN",
        "ANTHROPIC_ACCESS_EXPIRES",
        "ANTHROPIC_BETA_HEADER",
        "OPENAI_API_KEY",
        "OPENAI_ACCESS_TOKEN",
        "OPENAI_REFRESH_TOKEN",
        "OPENAI_ACCESS_EXPIRES",
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY",
        "X_AI_API_KEY",
        "XAI_API_KEY",
        "GROK_API_KEY",
        "MINIMAX_API_KEY",
        "MINIMAX_CN_API_KEY",
    ]
    let previousEnvironment = Dictionary(uniqueKeysWithValues: environmentKeys.map { key in
        (key, getenv(key).map { String(cString: $0) })
    })

    setenv("PEEKABOO_CONFIG_DIR", configDir.path, 1)
    setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
    ConfigurationManager.shared.resetForTesting()

    defer {
        for key in environmentKeys {
            if case let value?? = previousEnvironment[key] {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        TachikomaConfiguration.profileDirectoryName = previousProfileDirectoryName
        ConfigurationManager.shared.resetForTesting()
        try? fileManager.removeItem(at: configDir)
    }

    try body(configDir)
}
