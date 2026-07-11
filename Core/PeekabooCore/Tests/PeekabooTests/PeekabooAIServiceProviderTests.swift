import Foundation
import Tachikoma
import Testing
@testable import PeekabooAutomation

@Suite(.serialized)
// swiftlint:disable:next type_body_length
struct PeekabooAIServiceProviderTests {
    @Test
    @MainActor
    func `Resolves custom provider entries from config`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let configPath = tempDir.appendingPathComponent("config.json")
        try """
        {
          "aiProviders": { "providers": "local-proxy/mini" },
          "customProviders": {
            "local-proxy": {
              "name": "Local Proxy",
              "type": "openai",
              "enabled": true,
              "options": {
                "baseURL": "http://localhost:8317/v1",
                "apiKey": "dummy-not-used"
              },
              "models": {
                "mini": {
                  "name": "GPT-5.4 Mini",
                  "supportsVision": true
                }
              }
            }
          }
        }
        """.write(to: configPath, atomically: true, encoding: .utf8)

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        defer {
            unsetenv("PEEKABOO_CONFIG_DIR")
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        ConfigurationManager.shared.resetForTesting()
        _ = ConfigurationManager.shared.loadConfiguration()

        let service = PeekabooAIService()
        let model = try #require(service.availableModels().first)
        #expect(service.availableModels().count == 1)
        #expect(model.modelId == "local-proxy/mini")
        #expect(model.supportsVision)
    }

    @Test
    @MainActor
    func `Custom provider generation uses model key and resolved credentials`() throws {
        try self.withIsolatedEnvironment(
            ["PEEKABOO_CUSTOM_PROVIDER_KEY": "resolved-secret"],
            configurationJSON: """
            {
              "aiProviders": { "providers": "local-proxy/mini" },
              "customProviders": {
                "local-proxy": {
                  "name": "Local Proxy",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  },
                  "models": {
                    "mini": {
                      "name": "GPT-5.4 Mini",
                      "supportsVision": true
                    }
                  }
                }
              }
            }
            """) {
                let tempHome = FileManager.default.temporaryDirectory
                    .appendingPathComponent("peekaboo-home-\(UUID().uuidString)", isDirectory: true)
                let profileDir = tempHome.appendingPathComponent(".peekaboo", isDirectory: true)
                try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
                try """
                {
                  "customProviders": {
                    "local-proxy": {
                      "type": "openai",
                      "options": {
                        "baseURL": "http://localhost:8317/v1",
                        "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                      }
                    }
                  }
                }
                """.write(to: profileDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

                let previousHome = getenv("HOME").map { String(cString: $0) }
                setenv("HOME", tempHome.path, 1)
                CustomProviderRegistry.shared.loadFromProfile()
                defer {
                    try? "{}".write(
                        to: profileDir.appendingPathComponent("config.json"),
                        atomically: true,
                        encoding: .utf8)
                    CustomProviderRegistry.shared.loadFromProfile()
                    if let previousHome {
                        setenv("HOME", previousHome, 1)
                    } else {
                        unsetenv("HOME")
                    }
                    try? FileManager.default.removeItem(at: tempHome)
                }

                let service = PeekabooAIService()
                let model = try #require(service.availableModels().first)
                let provider = try service.tachikomaConfiguration(for: model).makeProvider(for: model)

                #expect(String(describing: type(of: provider)).contains("PeekabooCustomProviderModel"))
                #expect(Mirror(reflecting: provider).descendant("resolvedModelID") as? String == "mini")
                #expect(Mirror(reflecting: provider).descendant("apiKey") as? String == "resolved-secret")
            }
    }

    @Test
    @MainActor
    func `Custom provider advertises configured model max tokens`() throws {
        try self.withIsolatedEnvironment(
            ["PEEKABOO_CUSTOM_PROVIDER_KEY": "resolved-secret"],
            configurationJSON: """
            {
              "aiProviders": { "providers": "local-proxy/large" },
              "customProviders": {
                "local-proxy": {
                  "name": "Local Proxy",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  },
                  "models": {
                    "large": {
                      "name": "Large Local Model",
                      "supportsVision": true,
                      "supportsTools": true,
                      "maxTokens": 8192
                    }
                  }
                }
              }
            }
            """) {
                let service = PeekabooAIService()
                let model = try #require(service.availableModels().first)
                let provider = try service.tachikomaConfiguration(for: model).makeProvider(for: model)

                #expect(provider.capabilities.maxOutputTokens == 8192)
            }
    }

    @Test
    @MainActor
    func `Custom Opus 4 8 provider advertises nonstreaming capability`() throws {
        try self.withIsolatedEnvironment(
            ["PEEKABOO_CUSTOM_PROVIDER_KEY": "resolved-secret"],
            configurationJSON: """
            {
              "aiProviders": { "providers": "local-anthropic/claude-opus-4-8" },
              "customProviders": {
                "local-anthropic": {
                  "name": "Local Anthropic",
                  "type": "anthropic",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  },
                  "models": {
                    "claude-opus-4-8": {
                      "name": "Claude Opus 4.8",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let service = PeekabooAIService()
                let model = try #require(service.availableModels().first)
                let provider = try service.tachikomaConfiguration(for: model).makeProvider(for: model)

                #expect(model.modelId == "local-anthropic/claude-opus-4-8")
                #expect(!provider.capabilities.supportsStreaming)
                #expect(provider.capabilities.contextLength == 1_000_000)
                #expect(provider.capabilities.maxOutputTokens == 128_000)
            }
    }

    @Test
    @MainActor
    func `Custom Opus 4 7 provider advertises inferred current Claude capabilities`() throws {
        try self.withIsolatedEnvironment(
            ["PEEKABOO_CUSTOM_PROVIDER_KEY": "resolved-secret"],
            configurationJSON: """
            {
              "aiProviders": { "providers": "local-anthropic/claude-opus-4-7" },
              "customProviders": {
                "local-anthropic": {
                  "name": "Local Anthropic",
                  "type": "anthropic",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  },
                  "models": {
                    "claude-opus-4-7": {
                      "name": "Claude Opus 4.7",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let service = PeekabooAIService()
                let model = try #require(service.availableModels().first)
                let provider = try service.tachikomaConfiguration(for: model).makeProvider(for: model)

                #expect(model.modelId == "local-anthropic/claude-opus-4-7")
                #expect(provider.capabilities.supportsStreaming)
                #expect(provider.capabilities.contextLength == 1_000_000)
                #expect(provider.capabilities.maxOutputTokens == 128_000)
            }
    }

    @Test
    @MainActor
    func `Saved custom provider models become default candidates`() throws {
        try self.withIsolatedEnvironment(
            ["PEEKABOO_CUSTOM_PROVIDER_KEY": "resolved-secret"],
            configurationJSON: """
            {
              "customProviders": {
                "local-proxy": {
                  "name": "Local Proxy",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  },
                  "models": {
                    "mini": {
                      "name": "gpt-5.5-mini",
                      "supportsVision": true
                    }
                  }
                }
              }
            }
            """) {
                let service = PeekabooAIService()
                let model = try #require(service.availableModels().first)

                #expect(service.availableModels().count == 1)
                #expect(model.modelId == "local-proxy/mini")
                #expect(service.resolvedDefaultModel.modelId == "local-proxy/mini")
            }
    }

    @Test
    @MainActor
    func `Custom provider model preserves configured tool capability`() throws {
        try self.withIsolatedEnvironment(
            ["PEEKABOO_CUSTOM_PROVIDER_KEY": "resolved-secret"],
            configurationJSON: """
            {
              "customProviders": {
                "local-proxy": {
                  "name": "Local Proxy",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  },
                  "models": {
                    "mini": {
                      "name": "gpt-5.5-mini",
                      "supportsVision": true,
                      "supportsTools": false
                    }
                  }
                }
              }
            }
            """) {
                let service = PeekabooAIService()
                let model = try #require(service.availableModels().first)

                #expect(model.modelId == "local-proxy/mini")
                #expect(!model.supportsTools)
            }
    }

    @Test
    @MainActor
    func `Custom provider IDs shadow hosted provider aliases`() throws {
        try self.withIsolatedEnvironment(
            [
                "OPENROUTER_API_KEY": "built-in-key",
                "PEEKABOO_CUSTOM_PROVIDER_KEY": "custom-secret",
            ],
            configurationJSON: """
            {
              "aiProviders": { "providers": "openrouter/mini" },
              "customProviders": {
                "openrouter": {
                  "name": "Custom OpenRouter",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  },
                  "models": {
                    "mini": {
                      "name": "custom-router-mini",
                      "supportsVision": true,
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let service = PeekabooAIService()
                let model = try #require(service.availableModels().first)
                let provider = try service.tachikomaConfiguration(for: model).makeProvider(for: model)

                #expect(model.modelId == "openrouter/mini")
                #expect(String(describing: type(of: provider)).contains("PeekabooCustomProviderModel"))
                #expect(Mirror(reflecting: provider).descendant("apiKey") as? String == "custom-secret")
            }
    }

    @Test
    @MainActor
    func `Custom provider lookup preserves mixed case IDs`() throws {
        try self.withIsolatedEnvironment(
            ["PEEKABOO_CUSTOM_PROVIDER_KEY": "custom-secret"],
            configurationJSON: """
            {
              "aiProviders": { "providers": "OpenRouter/mini" },
              "customProviders": {
                "OpenRouter": {
                  "name": "Mixed Case Provider",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  },
                  "models": {
                    "mini": {
                      "name": "custom-router-mini",
                      "supportsVision": true,
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let service = PeekabooAIService()
                let model = try #require(service.availableModels().first)

                #expect(model.modelId == "OpenRouter/mini")
            }
    }

    @Test
    @MainActor
    func `Custom provider unresolved references do not fall back to generic compatible keys`() async throws {
        try await self.withIsolatedEnvironment(
            ["API_KEY": "wrong-generic-key"],
            configurationJSON: """
            {
              "aiProviders": { "providers": "local-proxy/mini" },
              "customProviders": {
                "local-proxy": {
                  "name": "Local Proxy",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://127.0.0.1:9/v1",
                    "apiKey": "${PEEKABOO_MISSING_PROVIDER_KEY}"
                  },
                  "models": {
                    "mini": {
                      "name": "gpt-5.4-mini",
                      "supportsVision": true
                    }
                  }
                }
              }
            }
            """) {
                let service = PeekabooAIService()
                let model = try #require(service.availableModels().first)
                let provider = try service.tachikomaConfiguration(for: model).makeProvider(for: model)

                await #expect(throws: TachikomaError.self) {
                    _ = try await provider.generateText(request: ProviderRequest(messages: [.user("hello")]))
                }
            }
    }

    @Test
    @MainActor
    func `Falls back to Gemini when only Gemini key is present`() throws {
        try self.withIsolatedEnvironment(["GEMINI_API_KEY": "key"]) {
            let service = PeekabooAIService()
            #expect(service.resolvedDefaultModel == .google(.gemini35Flash))
            #expect(service.availableModels() == [.google(.gemini35Flash)])
        }
    }

    @Test
    @MainActor
    func `Custom built-in aliases allow legacy-looking model keys`() throws {
        try self.withIsolatedEnvironment(
            ["PEEKABOO_CUSTOM_PROVIDER_KEY": "custom-secret"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "openai/gpt-4.1,anthropic/claude-3.5-sonnet"
              },
              "customProviders": {
                "openai": {
                  "name": "Custom OpenAI Proxy",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  },
                  "models": {
                    "gpt-4.1": {
                      "name": "Proxy GPT",
                      "supportsTools": true
                    }
                  }
                },
                "anthropic": {
                  "name": "Custom Anthropic Proxy",
                  "type": "anthropic",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8318",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  },
                  "models": {
                    "claude-3.5-sonnet": {
                      "name": "Proxy Claude",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let service = PeekabooAIService()

                #expect(service.availableModels().map(\.modelId) == [
                    "openai/gpt-4.1",
                    "anthropic/claude-3.5-sonnet",
                ])
            }
    }

    @Test
    @MainActor
    func `Built-in credentials take precedence over saved custom providers`() throws {
        try self.withIsolatedEnvironment(
            [
                "GEMINI_API_KEY": "key",
                "PEEKABOO_CUSTOM_PROVIDER_KEY": "resolved-secret",
            ],
            configurationJSON: """
            {
              "customProviders": {
                "local-proxy": {
                  "name": "Local Proxy",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  },
                  "models": {
                    "mini": {
                      "name": "Display Name",
                      "supportsVision": true,
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let service = PeekabooAIService()

                #expect(service.resolvedDefaultModel == .google(.gemini35Flash))
                #expect(service.availableModels() == [.google(.gemini35Flash)])
            }
    }

    @Test
    @MainActor
    func `Falls back to Grok when only xAI key is present`() throws {
        try self.withIsolatedEnvironment(["X_AI_API_KEY": "key"]) {
            let service = PeekabooAIService()
            #expect(service.resolvedDefaultModel == .grok(.grok43))
            #expect(service.availableModels() == [.grok(.grok43)])
            #expect(TachikomaConfiguration.current.getAPIKey(for: .grok) == "key")
        }
    }

    @Test
    @MainActor
    func `Generated default provider list still falls back to Gemini credentials`() throws {
        try self.withIsolatedEnvironment(
            ["GEMINI_API_KEY": "key"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "openai/gpt-5.5,anthropic/claude-opus-4-7"
              }
            }
            """) {
                let service = PeekabooAIService()
                #expect(service.resolvedDefaultModel == .google(.gemini35Flash))
                #expect(service.availableModels() == [.google(.gemini35Flash)])
            }
    }

    @Test
    @MainActor
    func `Settings generated provider list still falls back to Gemini credentials`() throws {
        try self.withIsolatedEnvironment(
            ["GEMINI_API_KEY": "key"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "anthropic/claude-opus-4-7,ollama/llava:latest"
              },
              "agent": {
                "defaultModel": "claude-opus-4-7"
              }
            }
            """) {
                let service = PeekabooAIService()
                let visionFallback = LanguageModel.ollama(.custom("llava:latest"))
                #expect(service.resolvedDefaultModel == .google(.gemini35Flash))
                #expect(service.resolvedDefaultVisionModel == .google(.gemini35Flash))
                #expect(service.availableModels() == [.google(.gemini35Flash), visionFallback])
            }
    }

    @Test
    @MainActor
    func `Falls back to MiniMax when only MiniMax key is present`() throws {
        try self.withIsolatedEnvironment(["MINIMAX_API_KEY": "key"]) {
            let service = PeekabooAIService()
            #expect(service.resolvedDefaultModel == .minimax(.m27))
            #expect(service.resolvedDefaultVisionModel == nil)
            #expect(service.availableModels() == [.minimax(.m27)])
        }
    }

    @Test
    @MainActor
    func `Falls back to MiniMax China when only MiniMax China key is present`() throws {
        try self.withIsolatedEnvironment(["MINIMAX_CN_API_KEY": "key"]) {
            let service = PeekabooAIService()
            #expect(service.resolvedDefaultModel == .minimaxCN(.m27))
            #expect(service.resolvedDefaultVisionModel == nil)
            #expect(service.availableModels() == [.minimaxCN(.m27)])
        }
    }

    @Test
    @MainActor
    func `Falls back to Kimi when only Kimi key is present`() throws {
        try self.withIsolatedEnvironment(["MOONSHOT_API_KEY": "key"]) {
            let service = PeekabooAIService()
            #expect(service.resolvedDefaultModel == .kimi(.k26))
            #expect(service.resolvedDefaultVisionModel == .kimi(.k26))
            #expect(service.availableModels() == [.kimi(.k26)])
        }
    }

    @Test
    @MainActor
    func `Explicit MiniMax China provider can reuse shared MiniMax key`() throws {
        try self.withIsolatedEnvironment(
            ["MINIMAX_API_KEY": "key"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "minimax-cn/MiniMax-M2.7"
              }
            }
            """) {
                let service = PeekabooAIService()
                #expect(service.resolvedDefaultModel == .minimaxCN(.m27))
                #expect(service.availableModels() == [.minimaxCN(.m27)])
            }
    }

    @Test
    @MainActor
    func `Invalid MiniMax China provider entry does not become OpenRouter`() throws {
        try self.withIsolatedEnvironment(
            ["MINIMAX_API_KEY": "key"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "minimax-cn/not-a-supported-model"
              }
            }
            """) {
                let service = PeekabooAIService()
                #expect(service.availableModels().isEmpty)
            }
    }

    @Test
    @MainActor
    func `Falls back to OpenRouter when only OpenRouter key is present`() throws {
        try self.withIsolatedEnvironment(["OPENROUTER_API_KEY": "key"]) {
            let service = PeekabooAIService()
            #expect(service.resolvedDefaultModel == .openRouter(modelId: "openai/gpt-oss-120b"))
            #expect(service.resolvedDefaultVisionModel == nil)
            #expect(service.availableModels() == [.openRouter(modelId: "openai/gpt-oss-120b")])
            #expect(TachikomaConfiguration.current.getAPIKey(for: "openrouter") == "key")
        }
    }

    @Test
    @MainActor
    func `Explicit OpenRouter provider list resolves configured model`() throws {
        try self.withIsolatedEnvironment(
            ["OPENROUTER_API_KEY": "key"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "openrouter/xiaomi/mimo-v2.5-pro"
              }
            }
            """) {
                let service = PeekabooAIService()
                #expect(service.resolvedDefaultModel == .openRouter(modelId: "xiaomi/mimo-v2.5-pro"))
                #expect(service.availableModels() == [.openRouter(modelId: "xiaomi/mimo-v2.5-pro")])
            }
    }

    @Test
    @MainActor
    func `Generated default provider list still falls back to MiniMax credentials`() throws {
        try self.withIsolatedEnvironment(
            ["MINIMAX_API_KEY": "key"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "openai/gpt-5.5,anthropic/claude-opus-4-7"
              }
            }
            """) {
                let service = PeekabooAIService()
                #expect(service.resolvedDefaultModel == .minimax(.m27))
                #expect(service.availableModels() == [.minimax(.m27)])
            }
    }

    @Test
    @MainActor
    func `Settings generated provider list still falls back to MiniMax credentials`() throws {
        try self.withIsolatedEnvironment(
            ["MINIMAX_API_KEY": "key"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "anthropic/claude-opus-4-7,ollama/llava:latest"
              },
              "agent": {
                "defaultModel": "claude-opus-4-7"
              }
            }
            """) {
                let service = PeekabooAIService()
                let visionFallback = LanguageModel.ollama(.custom("llava:latest"))
                #expect(service.resolvedDefaultModel == .minimax(.m27))
                #expect(service.resolvedDefaultVisionModel == visionFallback)
                #expect(service.availableModels() == [.minimax(.m27), visionFallback])
            }
    }

    @Test
    @MainActor
    func `Explicit single provider list does not fall back to unrelated credentials`() throws {
        try self.withIsolatedEnvironment(
            ["GEMINI_API_KEY": "key"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "openai/gpt-5.5"
              },
              "agent": {
                "defaultModel": "gpt-5.5"
              }
            }
            """) {
                let service = PeekabooAIService()
                #expect(service.resolvedDefaultModel == .openai(.gpt55))
                #expect(service.availableModels() == [.openai(.gpt55)])
            }
    }

    @Test
    @MainActor
    func `Explicit Fable provider list does not fall back to unrelated credentials`() throws {
        try self.withIsolatedEnvironment(
            ["GEMINI_API_KEY": "key"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "openai/gpt-5.5,anthropic/claude-fable-5"
              }
            }
            """) {
                let service = PeekabooAIService()
                #expect(service.resolvedDefaultModel == .openai(.gpt55))
                #expect(service.availableModels() == [.openai(.gpt55), .anthropic(.fable5)])
            }
    }

    @Test
    @MainActor
    func `Explicit Grok provider list preserves server-redirected model slug`() throws {
        try self.withIsolatedEnvironment(
            ["X_AI_API_KEY": "key"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "xai/grok-code-fast-1"
              },
              "agent": {
                "defaultModel": "xai/grok-code-fast-1"
              }
            }
            """) {
                let service = PeekabooAIService()

                #expect(service.availableModels() == [.grok(.custom("grok-code-fast-1"))])
            }
    }

    @Test
    @MainActor
    func `MiniMax only credentials do not default image analysis to text model`() async throws {
        try await self.withIsolatedEnvironment(["MINIMAX_API_KEY": "key"]) {
            let service = PeekabooAIService()
            await #expect(throws: TachikomaError.self) {
                _ = try await service.analyzeImageDetailed(imageData: Data(), question: "What is this?")
            }
        }
    }

    @Test
    @MainActor
    func `Config only MiniMax key is applied to Tachikoma`() throws {
        try self.withIsolatedEnvironment(
            [:],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "minimax/MiniMax-M2.7",
                "minimaxApiKey": "config-minimax-key"
              }
            }
            """) {
                let service = PeekabooAIService()
                #expect(service.resolvedDefaultModel == .minimax(.m27))
                #expect(TachikomaConfiguration.current.getAPIKey(for: .minimax) == "config-minimax-key")
            }
    }

    @Test
    @MainActor
    func `Configured Ollama base URL is applied to Tachikoma`() throws {
        try self.withIsolatedEnvironment(
            [:],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "ollama/qwen2.5vl:latest",
                "ollamaBaseUrl": "http://ollama.example:11434"
              }
            }
            """) {
                _ = PeekabooAIService()
                #expect(TachikomaConfiguration.current.getBaseURL(for: .ollama) == "http://ollama.example:11434")
            }
    }

    @Test
    @MainActor
    func `LM Studio hyphenated provider alias resolves local model`() throws {
        try self.withIsolatedEnvironment(
            [:],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "lm-studio/openai/gpt-oss-120b"
              }
            }
            """) {
                let service = PeekabooAIService()
                let model = try #require(service.availableModels().first)

                if case .lmstudio = model {
                    #expect(model.modelId == "openai/gpt-oss-120b")
                } else {
                    Issue.record("Expected LM Studio model, got \\(model)")
                }
            }
    }

    @Test
    @MainActor
    func `OLLAMA_BASE_URL environment is applied to Tachikoma`() throws {
        try self.withIsolatedEnvironment(["OLLAMA_BASE_URL": "http://remote-ollama:11434"]) {
            _ = PeekabooAIService()
            #expect(TachikomaConfiguration.current.getBaseURL(for: .ollama) == "http://remote-ollama:11434")
        }
    }

    private func withIsolatedEnvironment(
        _ overrides: [String: String],
        configurationJSON: String? = nil,
        body: () throws -> Void) throws
    {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        if let configurationJSON {
            try configurationJSON.write(
                to: tempDir.appendingPathComponent("config.json"),
                atomically: true,
                encoding: .utf8)
        }

        let keys = [
            "PEEKABOO_CONFIG_DIR",
            "PEEKABOO_CONFIG_DISABLE_MIGRATION",
            "PEEKABOO_AI_PROVIDERS",
            "OPENAI_API_KEY",
            "ANTHROPIC_API_KEY",
            "GEMINI_API_KEY",
            "GOOGLE_API_KEY",
            "MINIMAX_API_KEY",
            "MINIMAX_CN_API_KEY",
            "MOONSHOT_API_KEY",
            "KIMI_API_KEY",
            "OPENROUTER_API_KEY",
            "X_AI_API_KEY",
            "XAI_API_KEY",
            "GROK_API_KEY",
            "API_KEY",
            "PEEKABOO_CUSTOM_PROVIDER_KEY",
            "PEEKABOO_MISSING_PROVIDER_KEY",
            "PEEKABOO_OLLAMA_BASE_URL",
            "OLLAMA_BASE_URL",
        ]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        self.clearTachikomaKeys()
        for key in keys where !key.hasPrefix("PEEKABOO_CONFIG") {
            unsetenv(key)
        }
        for (key, value) in overrides {
            setenv(key, value, 1)
        }
        ConfigurationManager.shared.resetForTesting()
        _ = ConfigurationManager.shared.loadConfiguration()

        defer {
            for key in keys {
                if case let value?? = previous[key] {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            self.clearTachikomaKeys()
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        try body()
    }

    private func withIsolatedEnvironment(
        _ overrides: [String: String],
        configurationJSON: String? = nil,
        body: () async throws -> Void) async throws
    {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        if let configurationJSON {
            try configurationJSON.write(
                to: tempDir.appendingPathComponent("config.json"),
                atomically: true,
                encoding: .utf8)
        }

        let keys = [
            "PEEKABOO_CONFIG_DIR",
            "PEEKABOO_CONFIG_DISABLE_MIGRATION",
            "PEEKABOO_AI_PROVIDERS",
            "OPENAI_API_KEY",
            "ANTHROPIC_API_KEY",
            "GEMINI_API_KEY",
            "GOOGLE_API_KEY",
            "MINIMAX_API_KEY",
            "MINIMAX_CN_API_KEY",
            "MOONSHOT_API_KEY",
            "KIMI_API_KEY",
            "OPENROUTER_API_KEY",
            "X_AI_API_KEY",
            "XAI_API_KEY",
            "GROK_API_KEY",
            "API_KEY",
            "PEEKABOO_CUSTOM_PROVIDER_KEY",
            "PEEKABOO_MISSING_PROVIDER_KEY",
            "PEEKABOO_OLLAMA_BASE_URL",
            "OLLAMA_BASE_URL",
        ]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        self.clearTachikomaKeys()
        for key in keys where !key.hasPrefix("PEEKABOO_CONFIG") {
            unsetenv(key)
        }
        for (key, value) in overrides {
            setenv(key, value, 1)
        }
        ConfigurationManager.shared.resetForTesting()
        _ = ConfigurationManager.shared.loadConfiguration()

        defer {
            for key in keys {
                if case let value?? = previous[key] {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            self.clearTachikomaKeys()
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        try await body()
    }

    private func clearTachikomaKeys() {
        TachikomaConfiguration.current.removeAPIKey(for: .openai)
        TachikomaConfiguration.current.removeAPIKey(for: .anthropic)
        TachikomaConfiguration.current.removeAPIKey(for: .google)
        TachikomaConfiguration.current.removeAPIKey(for: .minimax)
        TachikomaConfiguration.current.removeAPIKey(for: .minimaxCN)
        TachikomaConfiguration.current.removeAPIKey(for: .kimi)
        TachikomaConfiguration.current.removeAPIKey(for: .grok)
        TachikomaConfiguration.current.removeAPIKey(for: .custom("openrouter"))
        TachikomaConfiguration.current.removeBaseURL(for: .ollama)
    }
}

extension PeekabooAIServiceProviderTests {
    @Test
    @MainActor
    func `Catalog-backed custom providers reject unknown model IDs`() throws {
        try self.withIsolatedEnvironment(
            ["PEEKABOO_CUSTOM_PROVIDER_KEY": "custom-secret"],
            configurationJSON: """
            {
              "customProviders": {
                "openrouter": {
                  "name": "Custom OpenRouter",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  },
                  "models": {
                    "mini": {
                      "name": "custom-router-mini",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let service = PeekabooAIService()

                #expect(service.resolveConfiguredModel("openrouter/mini")?.modelId == "openrouter/mini")
                #expect(service.resolveConfiguredModel("openrouter/mni") == nil)
            }
    }

    @Test
    @MainActor
    func `Unavailable generated custom provider does not fall through to hosted credentials`() throws {
        try self.withIsolatedEnvironment(
            ["X_AI_API_KEY": "hosted-xai-key"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "grok/mini,ollama/llava:latest"
              },
              "agent": {
                "defaultModel": "grok/mini"
              },
              "customProviders": {
                "grok": {
                  "name": "Custom Grok",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "${PEEKABOO_MISSING_PROVIDER_KEY}"
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
            """) {
                let service = PeekabooAIService()
                let model = try #require(service.availableModels().first)

                #expect(model.modelId == "grok/mini")
                #expect(!service.isModelAvailable(model))
                if case .custom = model {
                    // Expected custom routing.
                } else {
                    Issue.record("Expected unavailable custom provider model")
                }
            }
    }
}
