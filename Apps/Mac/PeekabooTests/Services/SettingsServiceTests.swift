import Darwin
import Foundation
import PeekabooCore
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit), .serialized)
@MainActor
struct PeekabooSettingsTests {
    @Test
    func `Visualizer defaults to the three v4 feedback groups`() throws {
        try withIsolatedSettingsEnvironment { _, credentialCoordinator in
            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.agentCursorEnabled)
            #expect(settings.inputHUDEnabled)
            #expect(settings.captureIndicatorsEnabled)
        }
    }

    @Test
    func `Visualizer migrates legacy animation preferences by group`() throws {
        try withIsolatedSettingsEnvironment { _, credentialCoordinator in
            let defaults = UserDefaults.standard
            for key in ["clickAnimationEnabled", "mouseTrailEnabled", "swipePathEnabled"] {
                defaults.set(false, forKey: "peekaboo.\(key)")
            }
            defaults.set(false, forKey: "peekaboo.typeAnimationEnabled")
            defaults.set(true, forKey: "peekaboo.hotkeyOverlayEnabled")
            defaults.set(false, forKey: "peekaboo.scrollAnimationEnabled")
            defaults.set(false, forKey: "peekaboo.screenshotFlashEnabled")
            defaults.set(false, forKey: "peekaboo.watchCaptureHUDEnabled")

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(!settings.agentCursorEnabled)
            #expect(!settings.inputHUDEnabled)
            #expect(!settings.captureIndicatorsEnabled)
        }
    }

    @Test
    func `Default values are set correctly`() throws {
        try withIsolatedSettingsEnvironment { _, credentialCoordinator in
            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            #expect(settings.openAIAPIKey.isEmpty)
            #expect(settings.selectedProvider == "anthropic")
            #expect(settings.selectedModel == "claude-opus-5")
            #expect(settings.alwaysOnTop == false)
            #expect(settings.showInDock == true)
            #expect(settings.launchAtLogin == false)
            #expect(settings.hapticFeedbackEnabled == true)
            #expect(settings.soundEffectsEnabled == true)
            #expect(settings.maxTokens == 16384)
            #expect(settings.temperature == 0.7)
        }
    }

    @Test
    func `API key validation`() throws {
        try withIsolatedSettingsEnvironment { _, credentialCoordinator in
            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            settings.selectedProvider = "openai"

            // Empty key should be invalid
            #expect(!settings.hasValidAPIKey)

            // Set a key
            settings.openAIAPIKey = "sk-test123"
            #expect(settings.hasValidAPIKey)

            // Clear the key
            settings.openAIAPIKey = ""
            #expect(!settings.hasValidAPIKey)
        }
    }

    @Test
    func `Model selection updates correctly`() throws {
        try withIsolatedSettingsEnvironment { _, credentialCoordinator in
            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            let models = ["gpt-5.6", "gpt-5-mini", "gpt-5-nano"]

            for model in models {
                settings.selectedModel = model
                #expect(settings.selectedModel == model)
            }
        }
    }

    @Test(arguments: [
        (-1.0, 0.0), // Below minimum
        (0.0, 0.0), // Minimum
        (0.5, 0.5), // Valid middle
        (1.0, 1.0), // Maximum
        (2.0, 1.0), // Above maximum
        (2.5, 1.0), // Way above maximum
    ])
    func `Temperature bounds are enforced`(input: Double, expected: Double) throws {
        try withIsolatedSettingsEnvironment { _, credentialCoordinator in
            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            settings.temperature = input
            #expect(settings.temperature == expected)
        }
    }

    @Test(arguments: [
        (0, 1), // Below minimum
        (1, 1), // Minimum
        (8192, 8192), // Valid middle
        (128_000, 128_000), // Maximum
        (200_000, 128_000), // Above maximum
    ])
    func `Max tokens bounds are enforced`(input: Int, expected: Int) throws {
        try withIsolatedSettingsEnvironment { _, credentialCoordinator in
            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            settings.maxTokens = input
            #expect(settings.maxTokens == expected)
        }
    }

    @Test
    func `Toggle settings work correctly`() throws {
        try withIsolatedSettingsEnvironment { _, credentialCoordinator in
            var settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            // launchAtLogin needs an application host for ServiceManagement registration, not this SwiftPM test.
            let toggles: [(WritableKeyPath<PeekabooSettings, Bool>, String)] = [
                (\.alwaysOnTop, "alwaysOnTop"),
                (\.showInDock, "showInDock"),
                (\.hapticFeedbackEnabled, "hapticFeedbackEnabled"),
                (\.soundEffectsEnabled, "soundEffectsEnabled"),
            ]

            for (keyPath, _) in toggles {
                let originalValue = settings[keyPath: keyPath]

                // Toggle on
                settings[keyPath: keyPath] = true
                #expect(settings[keyPath: keyPath] == true)

                // Toggle off
                settings[keyPath: keyPath] = false
                #expect(settings[keyPath: keyPath] == false)

                // Restore original
                settings[keyPath: keyPath] = originalValue
            }
        }
    }
}

@Suite(.tags(.services, .integration), .serialized)
@MainActor
struct PeekabooSettingsPersistenceTests {
    @Test
    func `API keys are not persisted in UserDefaults`() throws {
        try withIsolatedSettingsEnvironment { _, credentialCoordinator in
            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            settings.openAIAPIKey = "test-secret"

            #expect(UserDefaults.standard.string(forKey: "peekaboo.openAIAPIKey") == nil)
        }
    }

    @Test
    func `PeekabooSettings persist across instances`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let testAPIKey = "sk-test-persistence-key"
            let testModel = "o1-preview"
            let testTemperature = 0.9

            let settings1 = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            settings1.openAIAPIKey = testAPIKey
            settings1.selectedModel = testModel
            settings1.temperature = testTemperature
            settings1.alwaysOnTop = true

            // Reload through an independent coordinator, not the first instance's shared draft state.
            let reloadedFixture = CredentialCoordinatorFixture(
                directory: configDir.appendingPathComponent("credential-fixture"))
            let settings2 = PeekabooSettings(credentialCoordinator: reloadedFixture.coordinator())

            #expect(settings2.openAIAPIKey == testAPIKey)
            #expect(settings2.selectedModel == testModel)
            #expect(settings2.temperature == testTemperature)
            #expect(settings2.alwaysOnTop == true)
            // The original fixture owns the directory until the independent read is complete.
            withExtendedLifetime(credentialCoordinator) {}
        }
    }
}

@Suite(.tags(.services, .integration), .serialized)
@MainActor
struct PeekabooSettingsConfigHydrationTests {
    @Test
    func `Configuration-backed state survives init`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "anthropic/claude-opus-4-8,ollama/llava:latest"
              },
              "agent": {
                "defaultModel": "claude-opus-4-8",
                "temperature": 0.3,
                "maxTokens": 4096
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            let defaults = UserDefaults.standard
            defaults.set(true, forKey: "peekaboo.agentModeEnabled")
            defaults.set(false, forKey: "peekaboo.showInDock")

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "anthropic")
            #expect(settings.selectedModel == "claude-opus-4-8")
            #expect(settings.temperature == 0.3)
            #expect(settings.maxTokens == 4096)
            #expect(settings.agentModeEnabled == true)
            #expect(settings.showInDock == false)

            let persistedConfig = try String(contentsOf: configPath, encoding: .utf8)
            #expect(persistedConfig == configJSON)
            #expect(defaults.bool(forKey: "peekaboo.agentModeEnabled") == true)
            #expect(defaults.bool(forKey: "peekaboo.showInDock") == false)
        }
    }

    @Test
    func `Configuration-backed provider aliases hydrate to Google and built-ins include Grok and MiniMax`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "gemini/gemini-3.5-flash,ollama/llava:latest"
              },
              "agent": {
                "defaultModel": "gemini-3.5-flash"
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "google")
            #expect(settings.selectedModel == "gemini-3.5-flash")
            #expect(settings.allAvailableProviders.contains("google"))
            #expect(settings.allAvailableProviders.contains("grok"))
            #expect(settings.allAvailableProviders.contains("minimax"))
        }
    }

    @Test
    func `Configuration-backed supported model IDs remain pinned`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "gemini/gemini-3-flash,ollama/llava:latest"
              },
              "agent": {
                "defaultModel": "gemini-3-flash"
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "google")
            #expect(settings.selectedModel == "gemini-3-flash")

            let persistedConfig = try String(contentsOf: configPath, encoding: .utf8)
            #expect(persistedConfig == configJSON)
        }
    }

    @Test
    func `Configuration provider-only supported model remains unchanged`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "google/gemini-3-flash"
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "google")
            #expect(settings.selectedModel == "gemini-3-flash")

            let persistedData = try Data(contentsOf: configPath)
            let persistedConfig = try #require(String(bytes: persistedData, encoding: .utf8))
            #expect(persistedConfig == configJSON)
        }
    }

    @Test
    func `Configuration provider model wins over legacy UserDefaults without rewriting config`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "openai/gpt-5.5,anthropic/claude-opus-4-8"
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            let defaults = UserDefaults.standard
            defaults.set("anthropic", forKey: "peekaboo.selectedProvider")
            defaults.set("claude-opus-4-7", forKey: "peekaboo.selectedModel")

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "openai")
            #expect(settings.selectedModel == "gpt-5.5")

            let persistedConfig = try String(contentsOf: configPath, encoding: .utf8)
            #expect(persistedConfig == configJSON)
        }
    }

    @Test
    func `Configuration-backed LM Studio provider is keyless`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "lm-studio/openai/gpt-oss-120b"
              },
              "agent": {
                "defaultModel": "openai/gpt-oss-120b"
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "lmstudio")
            #expect(settings.selectedModel == "openai/gpt-oss-120b")
            #expect(settings.hasValidAPIKey)
            #expect(settings.allAvailableProviders.contains("lmstudio"))
        }
    }

    @Test
    func `Configuration-backed MiniMax API key validates settings provider`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "minimax/MiniMax-M2.7",
                "minimaxApiKey": "config-minimax-key"
              },
              "agent": {
                "defaultModel": "MiniMax-M2.7"
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "minimax")
            #expect(settings.selectedModel == "MiniMax-M2.7")
            #expect(settings.hasValidAPIKey)
        }
    }

    @Test
    func `Standalone qualified default hydrates its provider`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "agent": {
                "defaultModel": "minimax-cn/MiniMax-M2.7"
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "minimax-cn")
            #expect(settings.selectedModel == "MiniMax-M2.7")

            settings.temperature = 0.5

            let persistedData = try Data(contentsOf: configPath)
            let persistedJSON = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
            let agent = try #require(persistedJSON["agent"] as? [String: Any])
            #expect(agent["defaultModel"] as? String == "minimax-cn/MiniMax-M2.7")
        }
    }

    @Test
    func `Custom provider settings persist qualified agent default`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            try settings.addCustomProvider(
                Configuration.CustomProvider(
                    name: "Local Proxy",
                    type: .openai,
                    options: Configuration.ProviderOptions(
                        baseURL: "http://localhost:8317/v1",
                        apiKey: "test-key"),
                    models: [
                        "mini": Configuration.ModelDefinition(
                            name: "gpt-5.4-mini",
                            supportsTools: true),
                    ]),
                id: "local-proxy")

            settings.selectedProvider = "local-proxy"
            settings.selectedModel = "mini"

            let persistedData = try Data(contentsOf: configPath)
            let persistedJSON = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
            let agent = try #require(persistedJSON["agent"] as? [String: Any])
            let aiProviders = try #require(persistedJSON["aiProviders"] as? [String: Any])
            #expect(agent["defaultModel"] as? String == "local-proxy/mini")
            #expect(aiProviders["providers"] as? String == "local-proxy/mini,ollama/llava:latest")
        }
    }

    @Test
    func `Replacing selected custom provider preserves selection and default`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            let original = Configuration.CustomProvider(
                name: "Local Proxy",
                type: .openai,
                options: Configuration.ProviderOptions(
                    baseURL: "http://localhost:8317/v1",
                    apiKey: "test-key"))
            try settings.addCustomProvider(original, id: "local-proxy")
            settings.selectedProvider = "local-proxy"
            settings.selectedModel = "mini"

            let replacement = Configuration.CustomProvider(
                name: "Local Proxy",
                type: .openai,
                options: Configuration.ProviderOptions(
                    baseURL: "http://localhost:9417/v1",
                    apiKey: "replacement-key"))
            try settings.replaceCustomProvider(replacement, id: "local-proxy")

            #expect(settings.selectedProvider == "local-proxy")
            #expect(settings.selectedModel == "mini")
            #expect(settings.getCustomProvider(id: "local-proxy")?.options.baseURL == "http://localhost:9417/v1")

            let persistedData = try Data(contentsOf: configPath)
            let persistedJSON = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
            let agent = try #require(persistedJSON["agent"] as? [String: Any])
            #expect(agent["defaultModel"] as? String == "local-proxy/mini")
        }
    }

    @Test
    func `Replacing selected custom provider retargets a removed model`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            let original = Configuration.CustomProvider(
                name: "Local Proxy",
                type: .openai,
                options: Configuration.ProviderOptions(
                    baseURL: "http://localhost:8317/v1",
                    apiKey: "test-key"),
                models: [
                    "old-model": Configuration.ModelDefinition(name: "Old Model"),
                ])
            try settings.addCustomProvider(original, id: "local-proxy")
            settings.selectCustomProvider(id: "local-proxy")

            let replacement = Configuration.CustomProvider(
                name: "Local Proxy",
                type: .openai,
                options: original.options,
                models: [
                    "new-model": Configuration.ModelDefinition(name: "New Model"),
                ])
            try settings.replaceCustomProvider(replacement, id: "local-proxy")

            #expect(settings.selectedProvider == "local-proxy")
            #expect(settings.selectedModel == "new-model")

            let persistedData = try Data(contentsOf: configPath)
            let persistedJSON = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
            let agent = try #require(persistedJSON["agent"] as? [String: Any])
            #expect(agent["defaultModel"] as? String == "local-proxy/new-model")
        }
    }

    @Test
    func `Selecting custom provider also selects its configured model`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            try settings.addCustomProvider(
                Configuration.CustomProvider(
                    name: "Local Proxy",
                    type: .openai,
                    options: Configuration.ProviderOptions(
                        baseURL: "http://localhost:8317/v1",
                        apiKey: "test-key"),
                    models: [
                        "mini": Configuration.ModelDefinition(
                            name: "gpt-5.5-mini",
                            supportsTools: true),
                    ]),
                id: "local-proxy")

            settings.selectedProvider = "anthropic"
            settings.selectedModel = "claude-opus-4-8"
            settings.selectCustomProvider(id: "local-proxy")

            #expect(settings.selectedProvider == "local-proxy")
            #expect(settings.selectedModel == "mini")

            let persistedData = try Data(contentsOf: configPath)
            let persistedJSON = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
            let agent = try #require(persistedJSON["agent"] as? [String: Any])
            #expect(agent["defaultModel"] as? String == "local-proxy/mini")
        }
    }

    @Test
    func `Selecting catalog-less custom provider does not invent a model`() throws {
        try withIsolatedSettingsEnvironment { _, credentialCoordinator in
            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            try settings.addCustomProvider(
                Configuration.CustomProvider(
                    name: "Groq",
                    type: .openai,
                    options: Configuration.ProviderOptions(
                        baseURL: "https://api.groq.com/openai/v1",
                        apiKey: "test-key")),
                id: "groq-custom")

            settings.selectedProvider = "anthropic"
            settings.selectedModel = "claude-opus-4-8"
            settings.selectCustomProvider(id: "groq-custom")

            #expect(settings.selectedProvider == "anthropic")
            #expect(settings.selectedModel == "claude-opus-4-8")
        }
    }

    @Test
    func `Editing custom provider preserves discovered models and advanced options`() {
        let original = Configuration.CustomProvider(
            name: "Local Proxy",
            type: .openai,
            options: Configuration.ProviderOptions(
                baseURL: "http://localhost:8317/v1",
                apiKey: "test-key",
                timeout: 45,
                retryAttempts: 4,
                defaultParameters: ["temperature": "0.2"]),
            models: [
                "mini": Configuration.ModelDefinition(
                    name: "gpt-5.5-mini",
                    supportsTools: false,
                    supportsVision: false),
            ],
            enabled: false)

        let edited = Configuration.CustomProvider(
            name: "Updated Proxy",
            description: "Updated",
            type: .anthropic,
            options: Configuration.ProviderOptions(
                baseURL: "http://localhost:9417/v1",
                apiKey: "replacement-key",
                headers: ["X-Test": "value"]))
        let updated = EditCustomProviderView.preservingMetadata(from: original, in: edited)

        #expect(updated.name == "Updated Proxy")
        #expect(updated.options.baseURL == "http://localhost:9417/v1")
        #expect(updated.options.timeout == 45)
        #expect(updated.options.retryAttempts == 4)
        #expect(updated.options.defaultParameters == ["temperature": "0.2"])
        #expect(updated.models?["mini"]?.supportsTools == false)
        #expect(updated.models?["mini"]?.supportsVision == false)
        #expect(!updated.enabled)
    }

    @Test
    func `Editing custom provider can add model identifiers`() {
        let original = Configuration.CustomProvider(
            name: "Groq",
            type: .openai,
            options: Configuration.ProviderOptions(
                baseURL: "https://api.groq.com/openai/v1",
                apiKey: "test-key"))
        let edited = Configuration.CustomProvider(
            name: "Groq",
            type: .openai,
            options: original.options,
            models: [
                "llama-model": Configuration.ModelDefinition(name: "llama-model"),
            ])

        let updated = EditCustomProviderView.preservingMetadata(from: original, in: edited)

        #expect(updated.models?.keys.sorted() == ["llama-model"])
    }

    @Test
    func `Editing catalog-less provider preserves absent model catalog`() {
        let original = Configuration.CustomProvider(
            name: "Local Proxy",
            type: .openai,
            options: Configuration.ProviderOptions(
                baseURL: "http://localhost:8317/v1",
                apiKey: "test-key"))

        #expect(EditCustomProviderView.canSaveModels([], originalProvider: original))
        #expect(EditCustomProviderView.editedModels(modelIdentifiers: [], originalProvider: original) == nil)
    }

    @Test
    func `Custom provider settings hydrate qualified agent default`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "local-proxy/mini,ollama/llava:latest"
              },
              "agent": {
                "defaultModel": "local-proxy/mini"
              },
              "customProviders": {
                "local-proxy": {
                  "name": "Local Proxy",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "test-key"
                  },
                  "models": {
                    "mini": {
                      "name": "gpt-5.4-mini",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "local-proxy")
            #expect(settings.selectedModel == "mini")

            settings.temperature = 0.5

            let persistedData = try Data(contentsOf: configPath)
            let persistedJSON = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
            let agent = try #require(persistedJSON["agent"] as? [String: Any])
            let aiProviders = try #require(persistedJSON["aiProviders"] as? [String: Any])
            #expect(agent["defaultModel"] as? String == "local-proxy/mini")
            #expect(aiProviders["providers"] as? String == "local-proxy/mini,ollama/llava:latest")
        }
    }

    @Test
    func `Custom provider alias shadows xAI during provider-only hydration`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "xai/old,xai/mini"
              },
              "customProviders": {
                "xai": {
                  "name": "Custom xAI Proxy",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "test-key"
                  },
                  "models": {
                    "old": {
                      "name": "Proxy Old",
                      "supportsTools": true
                    },
                    "mini": {
                      "name": "Proxy Mini",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "xai")
            #expect(settings.selectedModel == "old")

            settings.selectedModel = "mini"

            let persistedData = try Data(contentsOf: configPath)
            let persistedJSON = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
            let agent = try #require(persistedJSON["agent"] as? [String: Any])
            let aiProviders = try #require(persistedJSON["aiProviders"] as? [String: Any])
            #expect(agent["defaultModel"] as? String == "xai/mini")
            #expect(aiProviders["providers"] as? String == "xai/mini,ollama/llava:latest")
        }
    }

    @Test
    func `Qualified custom defaults resolve case-insensitively`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "OpenRouter/mini"
              },
              "agent": {
                "defaultModel": "openrouter/mini"
              },
              "customProviders": {
                "OpenRouter": {
                  "name": "Custom OpenRouter",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "test-key"
                  },
                  "models": {
                    "mini": {
                      "name": "Proxy Mini",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "OpenRouter")
            #expect(settings.selectedModel == "mini")

            settings.temperature = 0.5

            let persistedData = try Data(contentsOf: configPath)
            let persistedJSON = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
            let agent = try #require(persistedJSON["agent"] as? [String: Any])
            let aiProviders = try #require(persistedJSON["aiProviders"] as? [String: Any])
            #expect(agent["defaultModel"] as? String == "OpenRouter/mini")
            #expect(aiProviders["providers"] as? String == "OpenRouter/mini,ollama/llava:latest")
        }
    }

    @Test
    func `OpenRouter nested model IDs retain OpenRouter routing`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "openrouter/anthropic/claude-sonnet-4.6,ollama/llava:latest"
              },
              "agent": {
                "defaultModel": "openrouter/anthropic/claude-sonnet-4.6"
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "openrouter")
            #expect(settings.selectedModel == "anthropic/claude-sonnet-4.6")

            settings.temperature = 0.5

            let persistedData = try Data(contentsOf: configPath)
            let persistedJSON = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
            let agent = try #require(persistedJSON["agent"] as? [String: Any])
            let aiProviders = try #require(persistedJSON["aiProviders"] as? [String: Any])
            #expect(agent["defaultModel"] as? String == "openrouter/anthropic/claude-sonnet-4.6")
            #expect(
                aiProviders["providers"] as? String ==
                    "openrouter/anthropic/claude-sonnet-4.6,ollama/llava:latest")
        }
    }

    @Test
    func `Built-in model picker includes current frontier models in tier order`() throws {
        #expect(AgentSettingsView.builtinName(forModelId: "gpt-5.6-sol") == "GPT-5.6 Sol")
        #expect(AgentSettingsView.builtinName(forModelId: "gpt-5.6-terra") == "GPT-5.6 Terra")
        #expect(AgentSettingsView.builtinName(forModelId: "gpt-5.6-luna") == "GPT-5.6 Luna")
        #expect(AgentSettingsView.builtinName(forModelId: "claude-opus-5") == "Claude Opus 5")
        #expect(AgentSettingsView.builtinName(forModelId: "claude-fable-5") == "Claude Fable 5")
        #expect(AgentSettingsView.builtinName(forModelId: "claude-sonnet-5") == "Claude Sonnet 5")

        let openAI = try #require(AgentSettingsView.builtinProviderCatalog.first { $0.provider == "openai" })
        let anthropic = try #require(AgentSettingsView.builtinProviderCatalog.first { $0.provider == "anthropic" })
        #expect(openAI.models.prefix(4).map(\.id) == [
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
            "gpt-5.5",
        ])
        #expect(anthropic.models.prefix(3).map(\.id) == [
            "claude-opus-5",
            "claude-fable-5",
            "claude-sonnet-5",
        ])
    }

    @Test
    func `Hydrated OpenRouter model remains available in model picker`() {
        let modelGroups = AgentSettingsView.appendingSelectedOpenRouterModel(
            to: [("openai", [(id: "gpt-5.5", name: "GPT-5.5")])],
            selectedProvider: "openrouter",
            selectedModel: "anthropic/claude-sonnet-4.6",
            customProviderIDs: [])

        #expect(modelGroups.contains { group in
            group.provider == "openrouter" &&
                group.models.contains { $0.id == "anthropic/claude-sonnet-4.6" }
        })
    }

    @Test
    func `Qualified default selects a later configured provider`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "openai/gpt-5.5,openrouter/anthropic/claude-sonnet-4.6"
              },
              "agent": {
                "defaultModel": "openrouter/anthropic/claude-sonnet-4.6"
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "openrouter")
            #expect(settings.selectedModel == "anthropic/claude-sonnet-4.6")

            settings.temperature = 0.5

            let persistedData = try Data(contentsOf: configPath)
            let persistedJSON = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
            let agent = try #require(persistedJSON["agent"] as? [String: Any])
            let aiProviders = try #require(persistedJSON["aiProviders"] as? [String: Any])
            #expect(agent["defaultModel"] as? String == "openrouter/anthropic/claude-sonnet-4.6")
            #expect(
                aiProviders["providers"] as? String ==
                    "openrouter/anthropic/claude-sonnet-4.6,openai/gpt-5.5")
        }
    }

    @Test
    func `Exact built-in custom provider shadows built-in settings entry`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "grok/mini"
              },
              "customProviders": {
                "grok": {
                  "name": "Custom Grok Proxy",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "test-custom-key"
                  },
                  "models": {
                    "mini": {
                      "name": "Proxy Mini",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.allAvailableProviders.count(where: { $0 == "grok" }) == 1)
            #expect(settings.selectedProvider == "grok")
            #expect(settings.selectedModel == "mini")
            #expect(settings.hasValidAPIKey)

            settings.temperature = 0.5

            let persistedData = try Data(contentsOf: configPath)
            let persistedJSON = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
            let agent = try #require(persistedJSON["agent"] as? [String: Any])
            #expect(agent["defaultModel"] as? String == "grok/mini")
        }
    }

    @Test
    func `Disabled custom provider does not shadow built-in settings entry`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "grok/grok-4.3"
              },
              "customProviders": {
                "grok": {
                  "name": "Disabled Grok Proxy",
                  "type": "openai",
                  "enabled": false,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "test-custom-key"
                  },
                  "models": {
                    "mini": {
                      "name": "Proxy Mini",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.allAvailableProviders.count(where: { $0 == "grok" }) == 1)
            #expect(settings.selectedProvider == "grok")
            #expect(settings.selectedModel == "grok-4.3")
        }
    }

    @Test
    func `Configuration-backed xAI provider alias hydrates to Grok`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let previousXAIKey = getenv("X_AI_API_KEY").map { String(cString: $0) }
            setenv("X_AI_API_KEY", "test-xai-key", 1)
            defer {
                if let previousXAIKey {
                    setenv("X_AI_API_KEY", previousXAIKey, 1)
                } else {
                    unsetenv("X_AI_API_KEY")
                }
            }

            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "xai/grok-4.3"
              },
              "agent": {
                "defaultModel": "xai/grok-4.3"
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "grok")
            #expect(settings.selectedModel == "grok-4.3")
            #expect(settings.hasValidAPIKey)
        }
    }

    @Test
    func `Configuration-backed qualified supported aliases remain unchanged`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "xai/grok-4"
              },
              "agent": {
                "defaultModel": "xai/grok-4"
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "grok")
            #expect(settings.selectedModel == "grok-4")

            let persistedData = try Data(contentsOf: configPath)
            let persistedConfig = try #require(String(bytes: persistedData, encoding: .utf8))
            #expect(persistedConfig == configJSON)
        }
    }
}

extension PeekabooSettingsConfigHydrationTests {
    @Test
    func `Removing selected custom provider resets provider and model atomically`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            try settings.addCustomProvider(
                Configuration.CustomProvider(
                    name: "Local Proxy",
                    type: .openai,
                    options: Configuration.ProviderOptions(
                        baseURL: "http://localhost:8317/v1",
                        apiKey: "test-key"),
                    models: [
                        "mini": Configuration.ModelDefinition(
                            name: "Proxy Mini",
                            supportsTools: true),
                    ]),
                id: "local-proxy")
            settings.selectCustomProvider(id: "local-proxy")

            try settings.removeCustomProvider(id: "local-proxy")

            #expect(settings.selectedProvider == "anthropic")
            #expect(settings.selectedModel == "claude-opus-5")

            let persistedData = try Data(contentsOf: configPath)
            let persistedJSON = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
            let agent = try #require(persistedJSON["agent"] as? [String: Any])
            let aiProviders = try #require(persistedJSON["aiProviders"] as? [String: Any])
            #expect(agent["defaultModel"] as? String == "claude-opus-5")
            #expect(
                aiProviders["providers"] as? String ==
                    "anthropic/claude-opus-5,ollama/llava:latest")
        }
    }

    @Test
    func `Mixed-case built-in provider IDs normalize before persistence`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let previousOpenAIKey = getenv("OPENAI_API_KEY").map { String(cString: $0) }
            setenv("OPENAI_API_KEY", "test-openai-key", 1)
            defer {
                if let previousOpenAIKey {
                    setenv("OPENAI_API_KEY", previousOpenAIKey, 1)
                } else {
                    unsetenv("OPENAI_API_KEY")
                }
            }

            let configPath = configDir.appendingPathComponent("config.json")
            try """
            {
              "aiProviders": {
                "providers": "OpenAI/gpt-5.5,ollama/llava:latest"
              },
              "agent": {
                "defaultModel": "OpenAI/gpt-5.5"
              }
            }
            """.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)

            #expect(settings.selectedProvider == "openai")
            #expect(settings.selectedModel == "gpt-5.5")
            #expect(settings.hasValidAPIKey)

            settings.temperature = 0.5

            let persistedData = try Data(contentsOf: configPath)
            let persistedJSON = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
            let agent = try #require(persistedJSON["agent"] as? [String: Any])
            let aiProviders = try #require(persistedJSON["aiProviders"] as? [String: Any])
            #expect(agent["defaultModel"] as? String == "gpt-5.5")
            #expect(aiProviders["providers"] as? String == "openai/gpt-5.5,ollama/llava:latest")
        }
    }

    @Test
    func `Replacing fallback custom provider refreshes active agent`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            try """
            {
              "customProviders": {
                "local-proxy": {
                  "name": "Local Proxy",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "test-key"
                  },
                  "models": {
                    "mini": {
                      "name": "Proxy Mini",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """.write(to: configPath, atomically: true, encoding: .utf8)

            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let services = PeekabooServices()
            let originalAgent = try #require(services.agent as? PeekabooAgentService)
            #expect(originalAgent.defaultModelSelection == "local-proxy/mini")

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            settings.selectedProvider = "openai"
            settings.selectedModel = "gpt-5.5"
            settings.connectServices(services)

            let replacement = Configuration.CustomProvider(
                name: "Local Proxy",
                type: .openai,
                options: Configuration.ProviderOptions(
                    baseURL: "http://localhost:9417/v1",
                    apiKey: "replacement-key"),
                models: [
                    "mini": Configuration.ModelDefinition(
                        name: "Proxy Mini",
                        supportsTools: true),
                ])
            try settings.replaceCustomProvider(replacement, id: "local-proxy")

            let refreshedAgent = try #require(services.agent as? PeekabooAgentService)
            #expect(ObjectIdentifier(refreshedAgent) != ObjectIdentifier(originalAgent))
            #expect(refreshedAgent.defaultModelSelection == "local-proxy/mini")
        }
    }

    @Test
    func `Ollama base URL edits stick in config and a default clears the saved URL`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let configJSON = """
            {
              "aiProviders": {
                "providers": "anthropic/claude-opus-4-8,ollama/llava:latest",
                "ollamaBaseUrl": "http://ollama.example:11434"
              },
              "agent": {
                "defaultModel": "claude-opus-4-8",
                "temperature": 0.3,
                "maxTokens": 4096
              },
              "defaults": {
                "savePath": "~/Desktop/Screenshots",
                "imageFormat": "png"
              },
              "logging": {
                "level": "info",
                "path": "~/.peekaboo/logs/peekaboo.log"
              }
            }
            """
            try configJSON.write(to: configPath, atomically: true, encoding: .utf8)
            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            #expect(settings.ollamaBaseURL == "http://ollama.example:11434")

            settings.ollamaBaseURL = "http://127.0.0.1:11435"
            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()
            #expect(ConfigurationManager.shared.getOllamaBaseURL() == "http://127.0.0.1:11435")
            #expect(try Self.ollamaBaseURL(in: configPath) == "http://127.0.0.1:11435")
            try Self.expectUnrelatedSettings(in: configPath)

            settings.ollamaBaseURL = "http://localhost:11434"
            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()
            #expect(ConfigurationManager.shared.getOllamaBaseURL() == "http://localhost:11434")
            #expect(try Self.ollamaBaseURL(in: configPath) == nil)
            try Self.expectUnrelatedSettings(in: configPath)

            let reloaded = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            #expect(reloaded.ollamaBaseURL == "http://localhost:11434")
            #expect(reloaded.selectedModel == "claude-opus-4-8")
            #expect(reloaded.temperature == 0.3)
            #expect(reloaded.maxTokens == 4096)
        }
    }

    @Test
    func `a new config file records an Ollama URL and drops the default`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            #expect(!FileManager.default.fileExists(atPath: configPath.path))

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            settings.ollamaBaseURL = "http://127.0.0.1:11435"
            #expect(FileManager.default.fileExists(atPath: configPath.path))
            let stored = try Self.ollamaBaseURL(in: configPath)
            #expect(stored == "http://127.0.0.1:11435")

            settings.ollamaBaseURL = "http://localhost:11434"
            let cleared = try Self.ollamaBaseURL(in: configPath)
            #expect(cleared == nil)
            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()
            #expect(ConfigurationManager.shared.getOllamaBaseURL() == "http://localhost:11434")
        }
    }

    @Test
    func `a v4_9_5 config keeps its other settings when the Ollama URL changes`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let template = """
            {
              "aiProviders": {
              "providers": "openai/gpt-5.6,anthropic/claude-opus-5"
              },
              "defaults": {
                "savePath": "~/Desktop/Screenshots",
                "imageFormat": "png",
                "captureMode": "window",
                "captureFocus": "background"
              },
              "logging": {
                "level": "info",
                "path": "~/.peekaboo/logs/peekaboo.log"
              }
            }
            """
            try template.write(to: configPath, atomically: true, encoding: .utf8)
            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            settings.ollamaBaseURL = "http://127.0.0.1:11435"
            let custom = try Self.object(in: configPath)
            let customProviders = try #require(custom["aiProviders"] as? [String: Any])
            let customDefaults = try #require(custom["defaults"] as? [String: Any])
            let customLogging = try #require(custom["logging"] as? [String: Any])
            #expect(customProviders["ollamaBaseUrl"] as? String == "http://127.0.0.1:11435")
            #expect(customProviders["providers"] as? String == "openai/gpt-5.6,anthropic/claude-opus-5")
            #expect(customDefaults["savePath"] as? String == "~/Desktop/Screenshots")
            #expect(customDefaults["imageFormat"] as? String == "png")
            #expect(customDefaults["captureMode"] as? String == "window")
            #expect(customDefaults["captureFocus"] as? String == "background")
            #expect(customLogging["level"] as? String == "info")
            #expect(customLogging["path"] as? String == "~/.peekaboo/logs/peekaboo.log")

            settings.ollamaBaseURL = "http://localhost:11434"
            let cleared = try Self.object(in: configPath)
            let clearedProviders = try #require(cleared["aiProviders"] as? [String: Any])
            #expect(clearedProviders["ollamaBaseUrl"] == nil)
            #expect(clearedProviders["providers"] as? String == "openai/gpt-5.6,anthropic/claude-opus-5")
            #expect((cleared["defaults"] as? [String: Any])?["captureMode"] as? String == "window")
        }
    }

    @Test
    func `Custom vision model writes only agent visionModel`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            let template = """
            {
              "aiProviders": {
                "providers": "openai/gpt-5.6,anthropic/claude-opus-5"
              },
              "defaults": {
                "savePath": "~/Desktop/Screenshots",
                "imageFormat": "png",
                "captureMode": "window",
                "captureFocus": "background"
              },
              "logging": {
                "level": "info",
                "path": "~/.peekaboo/logs/peekaboo.log"
              }
            }
            """
            try template.write(to: configPath, atomically: true, encoding: .utf8)
            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            settings.useCustomVisionModel = true
            settings.customVisionProvider = "anthropic"
            settings.customVisionModel = "claude-opus-5"

            let saved = try Self.object(in: configPath)
            let savedProviders = try #require(saved["aiProviders"] as? [String: Any])
            let savedAgent = try #require(saved["agent"] as? [String: Any])
            #expect(savedAgent["visionModel"] as? String == "anthropic/claude-opus-5")
            #expect(savedAgent["defaultModel"] == nil)
            #expect(savedProviders["providers"] as? String == "openai/gpt-5.6,anthropic/claude-opus-5")
            #expect((saved["defaults"] as? [String: Any])?["captureMode"] as? String == "window")
            #expect((saved["logging"] as? [String: Any])?["level"] as? String == "info")

            settings.useCustomVisionModel = false
            let cleared = try Self.object(in: configPath)
            let clearedProviders = try #require(cleared["aiProviders"] as? [String: Any])
            let clearedAgent = cleared["agent"] as? [String: Any]
            #expect(clearedAgent?["visionModel"] == nil)
            #expect(clearedProviders["providers"] as? String == "openai/gpt-5.6,anthropic/claude-opus-5")
            #expect((cleared["defaults"] as? [String: Any])?["captureFocus"] as? String == "background")
        }
    }

    @Test
    func `Removing agent visionModel stays removed`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            try Self.writeVisionFixture(
                to: configPath,
                providers: "openai/gpt-5.6,anthropic/claude-opus-5",
                visionModel: nil)
            ConfigurationManager.shared.resetForTesting()
            _ = ConfigurationManager.shared.loadConfiguration()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            settings.useCustomVisionModel = true
            settings.customVisionProvider = "anthropic"
            settings.customVisionModel = "claude-opus-5"
            #expect(
                try (Self.object(in: configPath)["agent"] as? [String: Any])?["visionModel"] as? String
                    == "anthropic/claude-opus-5")

            var stored = try Self.object(in: configPath)
            var agent = try #require(stored["agent"] as? [String: Any])
            agent.removeValue(forKey: "visionModel")
            stored["agent"] = agent
            try JSONSerialization.data(withJSONObject: stored, options: [.prettyPrinted])
                .write(to: configPath)
            ConfigurationManager.shared.resetForTesting()

            let reloaded = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            let reloadedAgent = try Self.object(in: configPath)["agent"] as? [String: Any]
            #expect(reloadedAgent?["visionModel"] == nil)
            #expect(!reloaded.useCustomVisionModel)
            #expect(reloaded.customVisionProvider.isEmpty)
            #expect(
                try (Self.object(in: configPath)["aiProviders"] as? [String: Any])?["providers"] as? String
                    == "openai/gpt-5.6,anthropic/claude-opus-5")
        }
    }

    @Test
    func `A legacy vision toggle is copied once`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            try Self.writeVisionFixture(to: configPath, providers: "openai/gpt-5.6", visionModel: nil)
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: "peekaboo.useCustomVisionModel")
            defaults.set("anthropic", forKey: "peekaboo.customVisionProvider")
            defaults.set("claude-opus-5", forKey: "peekaboo.customVisionModel")
            ConfigurationManager.shared.resetForTesting()

            _ = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            #expect(
                try (Self.object(in: configPath)["agent"] as? [String: Any])?["visionModel"] as? String
                    == "anthropic/claude-opus-5")

            var stored = try Self.object(in: configPath)
            var agent = try #require(stored["agent"] as? [String: Any])
            agent.removeValue(forKey: "visionModel")
            stored["agent"] = agent
            try JSONSerialization.data(withJSONObject: stored, options: [.prettyPrinted])
                .write(to: configPath)
            ConfigurationManager.shared.resetForTesting()

            _ = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            #expect(try (Self.object(in: configPath)["agent"] as? [String: Any])?["visionModel"] == nil)
        }
    }

    @Test
    func `A failed vision config load keeps the saved choice`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            try "{".write(to: configPath, atomically: true, encoding: .utf8)
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: "peekaboo.useCustomVisionModel")
            defaults.set("anthropic", forKey: "peekaboo.customVisionProvider")
            defaults.set("claude-opus-5", forKey: "peekaboo.customVisionModel")
            defaults.set(true, forKey: "peekaboo.visionModelConfigAuthoritative")
            ConfigurationManager.shared.resetForTesting()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            #expect(settings.useCustomVisionModel)
            #expect(settings.customVisionProvider == "anthropic")
            #expect(settings.customVisionModel == "claude-opus-5")
            #expect(defaults.bool(forKey: "peekaboo.useCustomVisionModel"))
            #expect(defaults.string(forKey: "peekaboo.customVisionProvider") == "anthropic")
        }
    }

    @Test
    func `A failed vision backfill stays retryable`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            try "{".write(to: configPath, atomically: true, encoding: .utf8)
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: "peekaboo.useCustomVisionModel")
            defaults.set("anthropic", forKey: "peekaboo.customVisionProvider")
            defaults.set("claude-opus-5", forKey: "peekaboo.customVisionModel")
            ConfigurationManager.shared.resetForTesting()

            _ = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            #expect(!defaults.bool(forKey: "peekaboo.visionModelConfigAuthoritative"))

            try Self.writeVisionFixture(to: configPath, providers: "openai/gpt-5.6", visionModel: nil)
            ConfigurationManager.shared.resetForTesting()
            _ = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            #expect(
                try (Self.object(in: configPath)["agent"] as? [String: Any])?["visionModel"] as? String
                    == "anthropic/claude-opus-5")
        }
    }

    @Test
    func `Vision provider reloads outside the agent provider list`() throws {
        try withIsolatedSettingsEnvironment { configDir, credentialCoordinator in
            let configPath = configDir.appendingPathComponent("config.json")
            try Self.writeVisionFixture(
                to: configPath,
                providers: "openai/gpt-5.5",
                visionModel: "anthropic/claude-opus-5",
                defaultModel: "openai/gpt-5.5")
            ConfigurationManager.shared.resetForTesting()

            let settings = PeekabooSettings(credentialCoordinator: credentialCoordinator)
            #expect(settings.useCustomVisionModel)
            #expect(settings.customVisionProvider == "anthropic")
            #expect(settings.customVisionModel == "claude-opus-5")
            #expect(settings.selectedProvider == "openai")
            #expect(
                try (Self.object(in: configPath)["aiProviders"] as? [String: Any])?["providers"] as? String
                    == "openai/gpt-5.5")
        }
    }

    private static func writeVisionFixture(
        to configPath: URL,
        providers: String,
        visionModel: String?,
        defaultModel: String? = nil) throws
    {
        var agent: [String: Any] = [:]
        if let defaultModel {
            agent["defaultModel"] = defaultModel
        }
        if let visionModel {
            agent["visionModel"] = visionModel
        }
        var root: [String: Any] = [
            "aiProviders": ["providers": providers],
            "defaults": [
                "savePath": "~/Desktop/Screenshots",
                "imageFormat": "png",
            ],
        ]
        if !agent.isEmpty {
            root["agent"] = agent
        }
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]).write(to: configPath)
    }

    private static func ollamaBaseURL(in configPath: URL) throws -> String? {
        let providers = try Self.object(in: configPath)["aiProviders"] as? [String: Any]
        return providers?["ollamaBaseUrl"] as? String
    }

    private static func expectUnrelatedSettings(in configPath: URL) throws {
        let object = try Self.object(in: configPath)
        let providers = try #require(object["aiProviders"] as? [String: Any])
        let agent = try #require(object["agent"] as? [String: Any])
        let defaults = try #require(object["defaults"] as? [String: Any])
        let logging = try #require(object["logging"] as? [String: Any])
        #expect(providers["providers"] as? String == "anthropic/claude-opus-4-8,ollama/llava:latest")
        #expect(agent["defaultModel"] as? String == "claude-opus-4-8")
        #expect(agent["temperature"] as? Double == 0.3)
        #expect(agent["maxTokens"] as? Int == 4096)
        #expect(defaults["savePath"] as? String == "~/Desktop/Screenshots")
        #expect(defaults["imageFormat"] as? String == "png")
        #expect(logging["level"] as? String == "info")
        #expect(logging["path"] as? String == "~/.peekaboo/logs/peekaboo.log")
    }

    private static func object(in configPath: URL) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: configPath)) as? [String: Any])
    }
}

/// Hosted CI only: this surrounding Settings graph still uses ambient defaults and provider singletons.
@MainActor
func withIsolatedSettingsEnvironment(_ body: (URL, ProviderCredentialCoordinator) throws -> Void) throws {
    let fileManager = FileManager.default
    let configDir = fileManager.temporaryDirectory
        .appendingPathComponent("peekaboo-settings-tests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)

    let defaults = UserDefaults.standard
    let previousConfigDir = getenv("PEEKABOO_CONFIG_DIR").map { String(cString: $0) }
    let previousDisableMigration = getenv("PEEKABOO_CONFIG_DISABLE_MIGRATION").map { String(cString: $0) }
    let credentialEnvironmentKeys = [
        "OPENAI_API_KEY",
        "OPENAI_ACCESS_TOKEN",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_ACCESS_TOKEN",
        "X_AI_API_KEY",
        "XAI_API_KEY",
        "GROK_API_KEY",
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY",
        "MINIMAX_API_KEY",
    ]
    let previousCredentialEnvironment = credentialEnvironmentKeys.reduce(into: [String: String]()) { values, key in
        if let value = getenv(key).map({ String(cString: $0) }) {
            values[key] = value
        }
    }
    let previousKeys = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("peekaboo.") }

    clearPeekabooDefaults(defaults)
    defaults.set(true, forKey: "peekaboo.migratedToConfigJson")
    setenv("PEEKABOO_CONFIG_DIR", configDir.path, 1)
    setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
    for key in credentialEnvironmentKeys {
        unsetenv(key)
    }
    ConfigurationManager.shared.resetForTesting()

    defer {
        clearPeekabooDefaults(defaults)
        for (key, value) in previousKeys {
            defaults.set(value, forKey: key)
        }
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
        for key in credentialEnvironmentKeys {
            if let value = previousCredentialEnvironment[key] {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        ConfigurationManager.shared.resetForTesting()
        try? fileManager.removeItem(at: configDir)
    }

    let fixture = CredentialCoordinatorFixture(directory: configDir.appendingPathComponent("credential-fixture"))
    try body(configDir, fixture.coordinator())
}

private func clearPeekabooDefaults(_ defaults: UserDefaults) {
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("peekaboo.") {
        defaults.removeObject(forKey: key)
    }
}
