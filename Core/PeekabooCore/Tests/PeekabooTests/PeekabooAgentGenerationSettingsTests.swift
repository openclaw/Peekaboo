import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooAgentGenerationSettingsTests {
    @Test
    @MainActor
    func `Configured custom Anthropic provider clamps temperature to Anthropic range`() throws {
        try self.withTemporaryConfig(
            """
            {
              "aiProviders": { "providers": "local-anthropic/claude-opus-4-7" },
              "agent": { "temperature": 1.8, "maxTokens": 128000 },
              "customProviders": {
                "local-anthropic": {
                  "name": "Local Anthropic",
                  "type": "anthropic",
                  "enabled": true,
                  "options": {
                    "baseURL": "https://anthropic-compatible.example",
                    "apiKey": "test-key"
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
                let configuration = ConfigurationManager.shared
                _ = configuration.loadConfiguration()
                let aiService = PeekabooAIService(configuration: configuration)
                let model = try #require(aiService.availableModels().first)
                let agentService = try PeekabooAgentService(services: PeekabooServices())

                #expect(model.modelId == "local-anthropic/claude-opus-4-7")
                #expect(agentService.generationSettings(for: model).temperature == 1.0)
                #expect(agentService.generationSettings(for: model).maxTokens == 128_000)
            }
    }

    @Test
    @MainActor
    func `Anthropic compatible current Claude models clamp max tokens to inferred provider caps`() throws {
        try self.withTemporaryConfig(
            """
            {
              "agent": { "maxTokens": 128000 }
            }
            """) {
                let agentService = try PeekabooAgentService(services: PeekabooServices())

                #expect(agentService.generationSettings(for: .anthropicCompatible(
                    modelId: "claude-opus-4-7",
                    baseURL: "https://anthropic-compatible.example")).maxTokens == 128_000)
                #expect(agentService.generationSettings(for: .anthropicCompatible(
                    modelId: "claude-sonnet-4-6",
                    baseURL: "https://anthropic-compatible.example")).maxTokens == 64000)
            }
    }

    @Test
    @MainActor
    func `OpenAI compatible GPT 5 provider-qualified model omits unsupported temperature`() throws {
        try self.withTemporaryConfig(
            """
            {
              "agent": { "temperature": 0.7 }
            }
            """) {
                let agentService = try PeekabooAgentService(services: PeekabooServices())
                let settings = agentService.generationSettings(for: .openaiCompatible(
                    modelId: "openai/gpt-5.5",
                    baseURL: "https://openai-compatible.example"))

                #expect(settings.temperature == nil)
            }
    }

    @Test
    @MainActor
    func `Configured custom OpenAI GPT 5 provider omits unsupported temperature`() throws {
        try self.withTemporaryConfig(
            """
            {
              "aiProviders": { "providers": "local-openai/gpt-5.5" },
              "agent": { "temperature": 0.7 },
              "customProviders": {
                "local-openai": {
                  "name": "Local OpenAI",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "https://openai-compatible.example",
                    "apiKey": "test-key"
                  },
                  "models": {
                    "gpt-5.5": {
                      "name": "GPT-5.5",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let configuration = ConfigurationManager.shared
                _ = configuration.loadConfiguration()
                let aiService = PeekabooAIService(configuration: configuration)
                let model = try #require(aiService.availableModels().first)
                let agentService = try PeekabooAgentService(services: PeekabooServices())

                #expect(model.modelId == "local-openai/gpt-5.5")
                #expect(agentService.generationSettings(for: model).temperature == nil)
            }
    }

    @Test
    @MainActor
    func `Configured custom OpenAI provider-qualified GPT 5 model omits unsupported temperature`() throws {
        try self.withTemporaryConfig(
            """
            {
              "aiProviders": { "providers": "local-openai/openai/gpt-5.5" },
              "agent": { "temperature": 0.7 },
              "customProviders": {
                "local-openai": {
                  "name": "Local OpenAI",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "https://openai-compatible.example",
                    "apiKey": "test-key"
                  },
                  "models": {
                    "openai/gpt-5.5": {
                      "name": "GPT-5.5",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let configuration = ConfigurationManager.shared
                _ = configuration.loadConfiguration()
                let aiService = PeekabooAIService(configuration: configuration)
                let model = try #require(aiService.availableModels().first)
                let agentService = try PeekabooAgentService(services: PeekabooServices())

                #expect(model.modelId == "local-openai/openai/gpt-5.5")
                #expect(agentService.generationSettings(for: model).temperature == nil)
            }
    }

    private func withTemporaryConfig(_ configurationJSON: String, body: () throws -> Void) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try configurationJSON.write(
            to: tempDir.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8)

        let keys = [
            "PEEKABOO_CONFIG_DIR",
            "PEEKABOO_CONFIG_DISABLE_MIGRATION",
            "PEEKABOO_AI_PROVIDERS",
        ]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        unsetenv("PEEKABOO_AI_PROVIDERS")
        ConfigurationManager.shared.resetForTesting()

        defer {
            for key in keys {
                if case let value?? = previous[key] {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        try body()
    }
}
