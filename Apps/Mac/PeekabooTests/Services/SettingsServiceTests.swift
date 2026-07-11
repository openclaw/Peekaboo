import Darwin
import Foundation
import PeekabooCore
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit), .serialized)
@MainActor
struct PeekabooSettingsTests {
    @Test
    func `Default values are set correctly`() throws {
        try withIsolatedSettingsEnvironment { _ in
            let settings = PeekabooSettings()
            #expect(settings.openAIAPIKey.isEmpty)
            #expect(settings.selectedProvider == "anthropic")
            #expect(settings.selectedModel == "claude-opus-4-8")
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
        try withIsolatedSettingsEnvironment { _ in
            let settings = PeekabooSettings()
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
        try withIsolatedSettingsEnvironment { _ in
            let settings = PeekabooSettings()
            let models = ["gpt-5.5", "gpt-5-mini", "gpt-5-nano"]

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
        try withIsolatedSettingsEnvironment { _ in
            let settings = PeekabooSettings()
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
        try withIsolatedSettingsEnvironment { _ in
            let settings = PeekabooSettings()
            settings.maxTokens = input
            #expect(settings.maxTokens == expected)
        }
    }

    @Test
    func `Toggle settings work correctly`() throws {
        try withIsolatedSettingsEnvironment { _ in
            var settings = PeekabooSettings()
            // Test all boolean settings
            let toggles: [(WritableKeyPath<PeekabooSettings, Bool>, String)] = [
                (\.alwaysOnTop, "alwaysOnTop"),
                (\.showInDock, "showInDock"),
                (\.launchAtLogin, "launchAtLogin"),
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
    func `PeekabooSettings persist across instances`() throws {
        try withIsolatedSettingsEnvironment { _ in
            let testAPIKey = "sk-test-persistence-key"
            let testModel = "o1-preview"
            let testTemperature = 0.9

            let settings1 = PeekabooSettings()
            settings1.openAIAPIKey = testAPIKey
            settings1.selectedModel = testModel
            settings1.temperature = testTemperature
            settings1.alwaysOnTop = true

            // Create new instance and verify
            let settings2 = PeekabooSettings()

            #expect(settings2.openAIAPIKey == testAPIKey)
            #expect(settings2.selectedModel == testModel)
            #expect(settings2.temperature == testTemperature)
            #expect(settings2.alwaysOnTop == true)
        }
    }
}

@Suite(.tags(.services, .integration), .serialized)
@MainActor
struct PeekabooSettingsConfigHydrationTests {
    @Test
    func `Configuration-backed state survives init`() throws {
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

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
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

            #expect(settings.selectedProvider == "google")
            #expect(settings.selectedModel == "gemini-3.5-flash")
            #expect(settings.allAvailableProviders.contains("google"))
            #expect(settings.allAvailableProviders.contains("grok"))
            #expect(settings.allAvailableProviders.contains("minimax"))
        }
    }

    @Test
    func `Configuration-backed supported model IDs remain pinned`() throws {
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

            #expect(settings.selectedProvider == "google")
            #expect(settings.selectedModel == "gemini-3-flash")

            let persistedConfig = try String(contentsOf: configPath, encoding: .utf8)
            #expect(persistedConfig == configJSON)
        }
    }

    @Test
    func `Configuration provider-only supported model remains unchanged`() throws {
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

            #expect(settings.selectedProvider == "google")
            #expect(settings.selectedModel == "gemini-3-flash")

            let persistedData = try Data(contentsOf: configPath)
            let persistedConfig = try #require(String(bytes: persistedData, encoding: .utf8))
            #expect(persistedConfig == configJSON)
        }
    }

    @Test
    func `Configuration provider model wins over legacy UserDefaults without rewriting config`() throws {
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

            #expect(settings.selectedProvider == "openai")
            #expect(settings.selectedModel == "gpt-5.5")

            let persistedConfig = try String(contentsOf: configPath, encoding: .utf8)
            #expect(persistedConfig == configJSON)
        }
    }

    @Test
    func `Configuration-backed LM Studio provider is keyless`() throws {
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

            #expect(settings.selectedProvider == "lmstudio")
            #expect(settings.selectedModel == "openai/gpt-oss-120b")
            #expect(settings.hasValidAPIKey)
            #expect(settings.allAvailableProviders.contains("lmstudio"))
        }
    }

    @Test
    func `Configuration-backed MiniMax API key validates settings provider`() throws {
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

            #expect(settings.selectedProvider == "minimax")
            #expect(settings.selectedModel == "MiniMax-M2.7")
            #expect(settings.hasValidAPIKey)
        }
    }

    @Test
    func `Standalone qualified default hydrates its provider`() throws {
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

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
        try withIsolatedSettingsEnvironment { configDir in
            let configPath = configDir.appendingPathComponent("config.json")
            let settings = PeekabooSettings()
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
        try withIsolatedSettingsEnvironment { configDir in
            let configPath = configDir.appendingPathComponent("config.json")
            let settings = PeekabooSettings()
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
        try withIsolatedSettingsEnvironment { configDir in
            let configPath = configDir.appendingPathComponent("config.json")
            let settings = PeekabooSettings()
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
        try withIsolatedSettingsEnvironment { configDir in
            let configPath = configDir.appendingPathComponent("config.json")
            let settings = PeekabooSettings()
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
        try withIsolatedSettingsEnvironment { _ in
            let settings = PeekabooSettings()
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
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

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
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

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
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

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
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

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
        #expect(anthropic.models.prefix(2).map(\.id) == [
            "claude-fable-5",
            "claude-sonnet-5",
        ])
        #expect(AIAssistantModelCatalog.options.map(\.model.modelId) == [
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
            "gpt-5.5",
            "claude-fable-5",
            "claude-sonnet-5",
            "claude-opus-4-8",
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
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

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
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

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
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

            #expect(settings.allAvailableProviders.count(where: { $0 == "grok" }) == 1)
            #expect(settings.selectedProvider == "grok")
            #expect(settings.selectedModel == "grok-4.3")
        }
    }

    @Test
    func `Configuration-backed xAI provider alias hydrates to Grok`() throws {
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

            #expect(settings.selectedProvider == "grok")
            #expect(settings.selectedModel == "grok-4.3")
            #expect(settings.hasValidAPIKey)
        }
    }

    @Test
    func `Configuration-backed qualified supported aliases remain unchanged`() throws {
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

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
        try withIsolatedSettingsEnvironment { configDir in
            let configPath = configDir.appendingPathComponent("config.json")
            let settings = PeekabooSettings()
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
            #expect(settings.selectedModel == "claude-opus-4-8")

            let persistedData = try Data(contentsOf: configPath)
            let persistedJSON = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
            let agent = try #require(persistedJSON["agent"] as? [String: Any])
            let aiProviders = try #require(persistedJSON["aiProviders"] as? [String: Any])
            #expect(agent["defaultModel"] as? String == "claude-opus-4-8")
            #expect(
                aiProviders["providers"] as? String ==
                    "anthropic/claude-opus-4-8,ollama/llava:latest")
        }
    }

    @Test
    func `Mixed-case built-in provider IDs normalize before persistence`() throws {
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()

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
        try withIsolatedSettingsEnvironment { configDir in
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

            let settings = PeekabooSettings()
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
}

@MainActor
private func withIsolatedSettingsEnvironment(_ body: (URL) throws -> Void) throws {
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

    try body(configDir)
}

private func clearPeekabooDefaults(_ defaults: UserDefaults) {
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("peekaboo.") {
        defaults.removeObject(forKey: key)
    }
}
