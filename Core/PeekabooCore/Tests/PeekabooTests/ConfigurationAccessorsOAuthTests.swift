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
