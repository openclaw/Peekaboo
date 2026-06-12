import Foundation
import PeekabooCore
import PeekabooFoundation
import Tachikoma
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct AgentCommandTests {
    @Test
    func `Supported OpenAI aliases map to GPT-5.5`() throws {
        let command = try AgentCommand.parse([])

        #expect(command.parseModelString("gpt-5.5") == .openai(.gpt55))
        #expect(command.parseModelString("gpt-5.4") == .openai(.gpt55))
        #expect(command.parseModelString("gpt-5.4-mini") == .openai(.gpt55))
        #expect(command.parseModelString("gpt-5.4-nano") == .openai(.gpt55))
        #expect(command.parseModelString("gpt-5") == .openai(.gpt55))
        #expect(command.parseModelString("gpt-5-mini") == .openai(.gpt55))
        #expect(command.parseModelString("gpt") == .openai(.gpt55))
        #expect(command.parseModelString("gpt-5-nano") == .openai(.gpt55))
        #expect(command.parseModelString("gpt-5.1") == nil)
        #expect(command.parseModelString("gpt-5.2") == nil)
        #expect(command.parseModelString("gpt-4o") == nil)
        #expect(command.parseModelString("gpt-4o-mini") == nil)
        #expect(command.parseModelString("definitely-not-a-model") == nil)
    }

    @Test
    func `Supported Anthropic aliases parse current models`() throws {
        let command = try AgentCommand.parse([])

        #expect(command.parseModelString("claude-fable-5") == .anthropic(.fable5))
        #expect(command.parseModelString("fable") == .anthropic(.fable5))
        #expect(command.parseModelString("claude-opus-4.8") == .anthropic(.opus48))
        #expect(command.parseModelString("claude-opus-4.7") == .anthropic(.opus47))
        #expect(command.parseModelString("claude-sonnet-4.6") == .anthropic(.sonnet46))
        #expect(command.parseModelString("claude-sonnet-4.5") == .anthropic(.sonnet45))
        #expect(command.parseModelString("Claude-Sonnet-4.5") == .anthropic(.sonnet45))
        #expect(command.parseModelString("claude") == .anthropic(.opus48))
        #expect(command.parseModelString("anthropic") == .anthropic(.opus48))
        #expect(command.parseModelString("claude-opus-4") == .anthropic(.opus4))
        #expect(command.parseModelString("claude-3-sonnet") == nil)
    }

    @Test
    func `Current and server-redirected Grok models are accepted`() throws {
        let command = try AgentCommand.parse([])

        #expect(command.parseModelString("grok-4.3") == .grok(.grok43))
        #expect(command.parseModelString("xai/grok-4.3-latest") == .grok(.grok43))
        #expect(command.parseModelString("xai/grok-4.20-multi-agent-0309") == nil)
        #expect(command.parseModelString("grok-code-fast-1") == .grok(.custom("grok-code-fast-1")))
        #expect(command.parseModelString("xai/grok-code-fast-1") == .grok(.custom("grok-code-fast-1")))
        #expect(command.parseModelString("definitely-not-a-model") == nil)
    }

    @Test
    func `Local Ollama and LM Studio tool-capable models are accepted`() throws {
        let command = try AgentCommand.parse([])

        #expect(command.parseModelString("ollama") == .ollama(.llama33))
        #expect(command.parseModelString("llama3.3") == .ollama(.llama33))
        #expect(command.parseModelString("ollama/llava") == nil)
        #expect(command.parseModelString("ollama/qwen2.5vl:3b") == nil)
        #expect(command.parseModelString("lmstudio") == .lmstudio(.gptOSS120B))
        #expect(command.parseModelString("lmstudio/openai/gpt-oss-120b") == .lmstudio(.gptOSS120B))
    }

    @Test
    func `Current Gemini models are accepted`() throws {
        let command = try AgentCommand.parse([])

        #expect(command.parseModelString("gemini-3.5-flash") == .google(.gemini35Flash))
        #expect(command.parseModelString("gemini-3.1-pro-preview") == .google(.gemini31ProPreview))
        #expect(command.parseModelString("gemini-3.1-flash-lite") == .google(.gemini31FlashLite))
        #expect(command.parseModelString("gemini-3-flash") == .google(.gemini3Flash))
        #expect(command.parseModelString("gemini") == .google(.gemini35Flash))
        #expect(command.parseModelString("gemini-2.5-pro") == .google(.gemini25Pro))
    }

    @Test
    func `Current MiniMax models are accepted`() throws {
        let command = try AgentCommand.parse([])

        #expect(command.parseModelString("MiniMax-M2.7") == .minimax(.m27))
        #expect(command.parseModelString("minimax-m2.7-highspeed") == .minimax(.m27Highspeed))
        #expect(command.parseModelString("minimax") == .minimax(.m27))
        #expect(command.parseModelString("minimax-cn/m2.7") == .minimaxCN(.m27))
        #expect(command.parseModelString("minimaxi/m2.7-highspeed") == .minimaxCN(.m27Highspeed))
        #expect(command.parseModelString("minimax-cn/not-a-supported-model") == nil)
    }

    @Test
    func `OpenRouter provider model IDs are accepted`() throws {
        let command = try AgentCommand.parse([])

        #expect(command
            .parseModelString("openrouter/xiaomi/mimo-v2.5-pro") == .openRouter(modelId: "xiaomi/mimo-v2.5-pro"))
        #expect(command.parseModelString("xiaomi/mimo-v2.5-pro") == .openRouter(modelId: "xiaomi/mimo-v2.5-pro"))
    }

    @Test
    func `Model string normalization trims whitespace`() throws {
        let command = try AgentCommand.parse([])

        #expect(command.parseModelString("  gpt-5  ") == .openai(.gpt55))
        #expect(command.parseModelString("\tgpt-5\n") == .openai(.gpt55))
        #expect(command.parseModelString(" claude-sonnet-4.5 ") == .anthropic(.sonnet45))
        #expect(command.parseModelString(" gemini-3-flash ") == .google(.gemini3Flash))
        #expect(command.parseModelString(" minimax-m2.7 ") == .minimax(.m27))
        #expect(command.parseModelString(" minimax-cn/m2.7 ") == .minimaxCN(.m27))
        #expect(command.parseModelString(" ollama/llama3.3 ") == .ollama(.llama33))
    }

    @Test
    @MainActor
    func `Configured custom provider model IDs are accepted`() throws {
        try self.withIsolatedConfiguration(
            """
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
            """,
            environment: ["PEEKABOO_CUSTOM_PROVIDER_KEY": "resolved-secret"]
        ) {
            let command = try AgentCommand.parse([])
            let model = try #require(command.parseModelString(
                "local-proxy/mini",
                configuration: PeekabooCore.ConfigurationManager.shared
            ))

            #expect(model.modelId == "local-proxy/mini")
            #expect(model.supportsTools)
            if case let .custom(provider) = model {
                #expect(provider.apiKey == "resolved-secret")
            } else {
                Issue.record("Expected custom provider model")
            }
        }
    }

    @Test
    @MainActor
    func `Unknown models do not escape custom provider shadows`() throws {
        try self.withIsolatedConfiguration(
            """
            {
              "customProviders": {
                "openai": {
                  "name": "Custom OpenAI",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
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
            """,
            environment: [
                "OPENAI_API_KEY": "hosted-key",
                "PEEKABOO_CUSTOM_PROVIDER_KEY": "custom-key",
            ]
        ) {
            let command = try AgentCommand.parse([])
            let configuration = PeekabooCore.ConfigurationManager.shared

            #expect(command.parseModelString("openai/mini", configuration: configuration)?.modelId == "openai/mini")
            #expect(command.parseModelString("openai/gpt-5.5", configuration: configuration) == nil)
        }
    }

    @Test
    func `Implicit selection skips uncredentialed provider entries`() throws {
        try self.withIsolatedConfiguration(
            """
            {
              "aiProviders": {
                "providers": "openai/gpt-5.5,anthropic/claude-fable-5"
              }
            }
            """,
            environment: ["ANTHROPIC_API_KEY": "test-anthropic-key"]
        ) {
            let command = try AgentCommand.parse([])
            let service = PeekabooAIService(configuration: PeekabooCore.ConfigurationManager.shared)

            #expect(command.firstAvailableToolModel(from: service) == .anthropic(.fable5))
        }
    }

    @Test
    func `Implicit selection uses catalog-less configured custom default`() throws {
        try self.withIsolatedConfiguration(
            """
            {
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
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  }
                }
              }
            }
            """,
            environment: ["PEEKABOO_CUSTOM_PROVIDER_KEY": "resolved-secret"]
        ) {
            let command = try AgentCommand.parse([])
            let service = PeekabooAIService(configuration: PeekabooCore.ConfigurationManager.shared)
            let model = try #require(command.configuredDefaultToolModel(
                from: service,
                configuration: PeekabooCore.ConfigurationManager.shared
            ))

            #expect(model.modelId == "local-proxy/mini")
            #expect(model.supportsTools)
        }
    }

    @Test
    func `Implicit selection does not escape explicit provider lists`() throws {
        try self.withIsolatedConfiguration(
            """
            {
              "aiProviders": {
                "providers": "openai/gpt-5.5"
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
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  }
                }
              }
            }
            """,
            environment: ["PEEKABOO_CUSTOM_PROVIDER_KEY": "resolved-secret"]
        ) {
            let command = try AgentCommand.parse([])
            let configuration = PeekabooCore.ConfigurationManager.shared
            let service = PeekabooAIService(configuration: configuration)

            #expect(configuration.hasExplicitAIProviderList())
            #expect(command.configuredDefaultToolModel(from: service, configuration: configuration)?
                .modelId == "local-proxy/mini")
            #expect(command
                .implicitToolModel(from: service, configuration: configuration, existingAgentModel: nil) == nil)
        }
    }

    private func withIsolatedConfiguration(
        _ configurationJSON: String,
        environment: [String: String] = [:],
        body: () throws -> Void
    ) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try configurationJSON.write(
            to: tempDir.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )

        let keys = [
            "PEEKABOO_CONFIG_DIR",
            "PEEKABOO_CONFIG_DISABLE_MIGRATION",
            "PEEKABOO_AI_PROVIDERS",
            "OPENAI_API_KEY",
            "ANTHROPIC_API_KEY",
            "PEEKABOO_CUSTOM_PROVIDER_KEY",
        ]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        unsetenv("PEEKABOO_AI_PROVIDERS")
        unsetenv("OPENAI_API_KEY")
        unsetenv("ANTHROPIC_API_KEY")
        unsetenv("PEEKABOO_CUSTOM_PROVIDER_KEY")
        for (key, value) in environment {
            setenv(key, value, 1)
        }
        PeekabooCore.ConfigurationManager.shared.resetForTesting()
        _ = PeekabooCore.ConfigurationManager.shared.loadConfiguration()

        defer {
            for key in keys {
                if case let value?? = previous[key] {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            PeekabooCore.ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        try body()
    }
}

/// Tests for model selection integration
@Suite(.tags(.safe))
@MainActor
struct ModelSelectionIntegrationTests {
    @Test
    func `Model parameter handling in AgentCommand`() throws {
        var command = try AgentCommand.parse([])
        command.model = "gpt-5"

        let parsedModel = command.model.flatMap { command.parseModelString($0) }
        #expect(parsedModel == .openai(.gpt55))

        command.model = "claude-opus-4.7"
        let parsedClaude = command.model.flatMap { command.parseModelString($0) }
        #expect(parsedClaude == .anthropic(.opus47))

        command.model = "gpt-4o"
        let remapped = command.model.flatMap { command.parseModelString($0) }
        #expect(remapped == nil)

        command.model = "gemini-3-flash"
        let parsedGemini = command.model.flatMap { command.parseModelString($0) }
        #expect(parsedGemini == .google(.gemini3Flash))
    }

    @Test
    func `Model description consistency`() throws {
        let command = try AgentCommand.parse([])

        let testCases: [(String, LanguageModel)] = [
            ("gpt-5.5", .openai(.gpt55)),
            ("claude-fable-5", .anthropic(.fable5)),
            ("claude-opus-4.8", .anthropic(.opus48)),
            ("gemini-3.5-flash", .google(.gemini35Flash)),
            ("MiniMax-M2.7", .minimax(.m27)),
            ("ollama/llama3.3", .ollama(.llama33)),
            ("openrouter/xiaomi/mimo-v2.5-pro", .openRouter(modelId: "xiaomi/mimo-v2.5-pro")),
        ]

        for (input, expected) in testCases {
            let parsed = command.parseModelString(input)
            #expect(parsed == expected)
            #expect(!expected.description.isEmpty)
        }
    }

    @Test
    func `Validated model selection handles optional input`() throws {
        var command = try AgentCommand.parse([])
        #expect(try command.validatedModelSelection() == nil)

        command.model = "gpt-5.5"
        let parsed = try command.validatedModelSelection()
        #expect(parsed == .openai(.gpt55))
    }

    @Test
    func `Invalid model option surfaces user-friendly error`() throws {
        var command = try AgentCommand.parse([])
        command.model = "gpt-4o"

        let error = #expect(throws: PeekabooError.self) {
            try command.validatedModelSelection()
        }

        if case let .invalidInput(message) = error {
            #expect(message.contains("Unsupported model"))
        } else {
            Issue.record("Expected invalidInput error")
        }
    }
}
