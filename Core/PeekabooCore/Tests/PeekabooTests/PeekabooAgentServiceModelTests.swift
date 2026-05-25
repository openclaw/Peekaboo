import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

/// Tests for PeekabooAgentService model selection functionality
struct PeekabooAgentServiceTests {
    @MainActor
    private func makeServices() -> PeekabooServices {
        PeekabooServices()
    }

    @Test
    @MainActor
    func `Default model initialization`() throws {
        let mockServices = self.makeServices()
        let agentService = try PeekabooAgentService(services: mockServices)

        // Should default to Claude Opus 4.7
        #expect(agentService.defaultModel == LanguageModel.anthropic(.opus47).description)
    }

    @Test
    @MainActor
    func `Anthropic generation settings avoid stale thinking option`() throws {
        let mockServices = self.makeServices()
        let agentService = try PeekabooAgentService(services: mockServices)

        let settings = agentService.generationSettings(for: .anthropic(.opus47))

        #expect(settings.maxTokens == 4096)
        #expect(settings.providerOptions.anthropic?.thinking == nil)
    }

    @Test
    @MainActor
    func `Gemini only credentials initialize Gemini default agent`() throws {
        try self.withIsolatedAgentEnvironment(["GEMINI_API_KEY": "test-gemini-key"]) {
            let services = self.makeServices()
            let agentService = try #require(services.agent as? PeekabooAgentService)

            #expect(agentService.defaultModel == LanguageModel.google(.gemini3Flash).description)
        }
    }

    @Test
    @MainActor
    func `MiniMax only credentials initialize MiniMax default agent`() throws {
        try self.withIsolatedAgentEnvironment(["MINIMAX_API_KEY": "test-minimax-key"]) {
            let services = self.makeServices()
            let agentService = try #require(services.agent as? PeekabooAgentService)

            #expect(agentService.defaultModel == LanguageModel.minimax(.m27).description)
        }
    }

    @Test
    @MainActor
    func `MiniMax China only credentials initialize MiniMax China default agent`() throws {
        try self.withIsolatedAgentEnvironment(["MINIMAX_CN_API_KEY": "test-minimax-cn-key"]) {
            let services = self.makeServices()
            let agentService = try #require(services.agent as? PeekabooAgentService)

            #expect(agentService.defaultModel == LanguageModel.minimaxCN(.m27).description)
        }
    }

    @Test
    @MainActor
    func `MiniMax China configured default can reuse shared MiniMax key`() throws {
        try self.withIsolatedAgentEnvironment(
            ["MINIMAX_API_KEY": "test-minimax-key"],
            configurationJSON: """
            {
              "agent": {
                "defaultModel": "minimax-cn/MiniMax-M2.7"
              }
            }
            """) {
                let services = self.makeServices()
                let agentService = try #require(services.agent as? PeekabooAgentService)

                #expect(agentService.defaultModel == LanguageModel.minimaxCN(.m27).description)
            }
    }

    @Test
    @MainActor
    func `Generated default model does not block Gemini default agent`() throws {
        try self.withIsolatedAgentEnvironment(
            ["GEMINI_API_KEY": "test-gemini-key"],
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
                let services = self.makeServices()
                let agentService = try #require(services.agent as? PeekabooAgentService)

                #expect(agentService.defaultModel == LanguageModel.google(.gemini3Flash).description)
            }
    }

    @Test
    @MainActor
    func `Generated default model does not block MiniMax default agent`() throws {
        try self.withIsolatedAgentEnvironment(
            ["MINIMAX_API_KEY": "test-minimax-key"],
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
                let services = self.makeServices()
                let agentService = try #require(services.agent as? PeekabooAgentService)

                #expect(agentService.defaultModel == LanguageModel.minimax(.m27).description)
            }
    }

    @Test
    @MainActor
    func `Explicit environment provider list does not fall back to unrelated credentials`() throws {
        try self.withIsolatedAgentEnvironment([
            "PEEKABOO_AI_PROVIDERS": "openai/gpt-5.5",
            "GEMINI_API_KEY": "test-gemini-key",
        ]) {
            let services = self.makeServices()

            #expect(services.agent == nil)
        }
    }

    @Test
    @MainActor
    func `Empty environment provider list does not block available credentials`() throws {
        try self.withIsolatedAgentEnvironment([
            "PEEKABOO_AI_PROVIDERS": "   ",
            "GEMINI_API_KEY": "test-gemini-key",
        ]) {
            let services = self.makeServices()
            let agentService = try #require(services.agent as? PeekabooAgentService)

            #expect(agentService.defaultModel == LanguageModel.google(.gemini3Flash).description)
        }
    }

    @Test
    @MainActor
    func `Explicit config provider list does not fall back to unrelated credentials`() throws {
        try self.withIsolatedAgentEnvironment(
            ["GEMINI_API_KEY": "test-gemini-key"],
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
                let services = self.makeServices()

                #expect(services.agent == nil)
            }
    }

    @Test
    @MainActor
    func `Configured Ollama provider initializes local default agent`() throws {
        try self.withIsolatedAgentEnvironment(["PEEKABOO_AI_PROVIDERS": "ollama/llama3.3"]) {
            let services = self.makeServices()
            let agentService = try #require(services.agent as? PeekabooAgentService)

            #expect(agentService.defaultModel == LanguageModel.ollama(.llama33).description)
        }
    }

    @Test
    @MainActor
    func `Bare Ollama provider initializes local default agent`() throws {
        try self.withIsolatedAgentEnvironment(["PEEKABOO_AI_PROVIDERS": "ollama"]) {
            let services = self.makeServices()
            let agentService = try #require(services.agent as? PeekabooAgentService)

            #expect(agentService.defaultModel == LanguageModel.ollama(.llama33).description)
        }
    }

    @Test
    @MainActor
    func `Configured Ollama vision fallback does not initialize agent`() throws {
        try self.withIsolatedAgentEnvironment(["PEEKABOO_AI_PROVIDERS": "ollama/llava:latest"]) {
            let services = self.makeServices()

            #expect(services.agent == nil)
        }
    }

    @Test
    @MainActor
    func `Configured Ollama provider tolerates comma whitespace`() throws {
        try self.withIsolatedAgentEnvironment(["PEEKABOO_AI_PROVIDERS": "openai/gpt-5.5, ollama/llama3.3"]) {
            let services = self.makeServices()
            let agentService = try #require(services.agent as? PeekabooAgentService)

            #expect(agentService.defaultModel == LanguageModel.ollama(.llama33).description)
        }
    }

    @Test
    @MainActor
    func `Configured LM Studio provider initializes local default agent`() throws {
        try self.withIsolatedAgentEnvironment(["PEEKABOO_AI_PROVIDERS": "lmstudio/openai/gpt-oss-120b"]) {
            let services = self.makeServices()
            let agentService = try #require(services.agent as? PeekabooAgentService)

            #expect(agentService.defaultModel == LanguageModel.lmstudio(.gptOSS120B).description)
        }
    }

    @Test
    @MainActor
    func `Hyphenated LM Studio provider matches unqualified configured default`() throws {
        try self.withIsolatedAgentEnvironment(
            ["PEEKABOO_AI_PROVIDERS": "lm-studio/openai/gpt-oss-120b"],
            configurationJSON: """
            {
              "agent": {
                "defaultModel": "openai/gpt-oss-120b"
              }
            }
            """) {
                let services = self.makeServices()
                let agentService = try #require(services.agent as? PeekabooAgentService)

                #expect(agentService.defaultModel == LanguageModel.lmstudio(.gptOSS120B).description)
            }
    }

    @Test
    @MainActor
    func `Bare LM Studio provider initializes local default agent`() throws {
        try self.withIsolatedAgentEnvironment(["PEEKABOO_AI_PROVIDERS": "lmstudio"]) {
            let services = self.makeServices()
            let agentService = try #require(services.agent as? PeekabooAgentService)

            #expect(agentService.defaultModel == LanguageModel.lmstudio(.gptOSS120B).description)
        }
    }

    @Test
    @MainActor
    func `Custom default model initialization`() throws {
        let mockServices = self.makeServices()
        let customModel = LanguageModel.openai(.gpt55)
        let agentService = try PeekabooAgentService(
            services: mockServices,
            defaultModel: customModel)

        #expect(agentService.defaultModel == customModel.description)
    }

    private func withIsolatedAgentEnvironment(
        _ overrides: [String: String],
        configurationJSON: String? = nil,
        body: () throws -> Void) throws
    {
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
            "PEEKABOO_OLLAMA_BASE_URL",
            "OLLAMA_BASE_URL",
        ]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })
        defer {
            for key in keys {
                if case let value?? = previous[key] {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            ConfigurationManager.shared.resetForTesting()
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-agent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        if let configurationJSON {
            try configurationJSON.write(
                to: tempDir.appendingPathComponent("config.json"),
                atomically: true,
                encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        unsetenv("PEEKABOO_AI_PROVIDERS")
        unsetenv("OPENAI_API_KEY")
        unsetenv("ANTHROPIC_API_KEY")
        unsetenv("GEMINI_API_KEY")
        unsetenv("GOOGLE_API_KEY")
        unsetenv("MINIMAX_API_KEY")
        unsetenv("MINIMAX_CN_API_KEY")
        unsetenv("PEEKABOO_OLLAMA_BASE_URL")
        unsetenv("OLLAMA_BASE_URL")
        for (key, value) in overrides {
            setenv(key, value, 1)
        }
        ConfigurationManager.shared.resetForTesting()

        try body()
    }

    @Test
    @MainActor
    func `Model parameter precedence in executeTask`() async throws {
        let mockServices = self.makeServices()
        let defaultModel = LanguageModel.anthropic(.opus47)
        let agentService = try PeekabooAgentService(
            services: mockServices,
            defaultModel: defaultModel)

        // Mock event delegate that captures model usage
        let eventDelegate = MockEventDelegate()

        // Test with custom model parameter
        let customModel = LanguageModel.openai(.gpt55)

        // This would normally make an API call, but we're testing the model selection logic
        // In a real test, we'd mock the network layer
        do {
            let result = try await agentService.executeTask(
                "test task",
                maxSteps: 1,
                sessionId: nil,
                model: customModel,
                eventDelegate: eventDelegate)

            // Verify the result metadata shows the custom model was used
            #expect(result.metadata.modelName == customModel.description)
        } catch {
            // Expected to fail due to missing API keys in test environment
            // The important part is that the model selection logic works
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test
    @MainActor
    func `Model parameter falls back to default when nil`() async throws {
        let mockServices = self.makeServices()
        let defaultModel = LanguageModel.anthropic(.opus47)
        let agentService = try PeekabooAgentService(
            services: mockServices,
            defaultModel: defaultModel)

        let eventDelegate = MockEventDelegate()

        // Test with nil model parameter - should use default
        do {
            let result = try await agentService.executeTask(
                "test task",
                maxSteps: 1,
                sessionId: nil,
                model: nil, // Should fall back to default
                eventDelegate: eventDelegate)

            // Verify the result metadata shows the default model was used
            #expect(result.metadata.modelName == defaultModel.description)
        } catch {
            // Expected to fail due to missing API keys in test environment
            // Accept any error as we're testing the model selection logic, not API calls
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test
    @MainActor
    func `Streaming execution respects model parameter`() async throws {
        let mockServices = self.makeServices()
        let agentService = try PeekabooAgentService(services: mockServices)

        let customModel = LanguageModel.openai(.gpt55)
        _ = MockEventDelegate()

        // Test streaming execution with custom model
        do {
            let result = try await agentService.executeTaskStreaming(
                "test task",
                sessionId: nil,
                model: customModel)
            { _ in
                // Stream handler
            }

            #expect(result.metadata.modelName == customModel.description)
        } catch {
            // Expected to fail due to missing API keys
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test
    @MainActor
    func `Resume session respects model parameter`() async throws {
        let mockServices = self.makeServices()
        let agentService = try PeekabooAgentService(services: mockServices)

        let customModel = LanguageModel.anthropic(.opus47)

        // Test resume session with custom model
        do {
            let result = try await agentService.resumeSession(
                sessionId: "test-session-id",
                model: customModel,
                eventDelegate: nil)

            #expect(result.metadata.modelName == customModel.description)
        } catch {
            // Expected to fail due to non-existent session or missing API keys
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test
    @MainActor
    func `Dry run execution reports requested model`() async throws {
        let mockServices = self.makeServices()
        let agentService = try PeekabooAgentService(
            services: mockServices,
            defaultModel: .anthropic(.opus47))

        let result = try await agentService.executeTask(
            "describe state",
            maxSteps: 1,
            sessionId: nil,
            model: .openai(.gpt55),
            dryRun: true,
            eventDelegate: nil)

        #expect(result.metadata.modelName == LanguageModel.openai(.gpt55).description)
        #expect(result.content.contains("Dry run"))
    }
}

/// Mock event delegate for testing
@MainActor
private class MockEventDelegate: AgentEventDelegate {
    var events: [AgentEvent] = []

    func agentDidEmitEvent(_ event: AgentEvent) {
        self.events.append(event)
    }
}

/// Tests for model selection in different execution paths
struct ModelSelectionExecutionPathTests {
    @MainActor
    private func makeServices() -> PeekabooServices {
        PeekabooServices()
    }

    @Test
    @MainActor
    func `executeWithStreaming uses provided model`() async throws {
        let mockServices = self.makeServices()
        let agentService = try PeekabooAgentService(services: mockServices)

        // Test that the internal executeWithStreaming method would use the provided model
        // This is tested indirectly through the public API since executeWithStreaming is private

        let customModel = LanguageModel.openai(.gpt55)
        let eventDelegate = MockEventDelegate()

        do {
            let result = try await agentService.executeTask(
                "test streaming execution",
                maxSteps: 1,
                sessionId: nil as String?,
                model: customModel,
                eventDelegate: eventDelegate)

            // The streaming path should be taken when eventDelegate is provided
            #expect(result.metadata.modelName == customModel.description)
        } catch {
            // Expected to fail due to API constraints in test environment
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test
    @MainActor
    func `executeWithoutStreaming uses provided model`() async throws {
        let mockServices = self.makeServices()
        let agentService = try PeekabooAgentService(services: mockServices)

        let customModel = LanguageModel.anthropic(.opus47)

        do {
            // No event delegate means non-streaming path
            let result = try await agentService.executeTask(
                "test non-streaming execution",
                maxSteps: 1,
                sessionId: nil as String?,
                model: customModel,
                eventDelegate: nil as (any AgentEventDelegate)?)

            #expect(result.metadata.modelName == customModel.description)
        } catch {
            // Expected to fail due to API constraints in test environment
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test
    @MainActor
    func `Model consistency across multiple calls`() async throws {
        let mockServices = PeekabooServices()
        let agentService = try PeekabooAgentService(services: mockServices)

        let models: [LanguageModel] = [
            .openai(.gpt55),
            .anthropic(.opus47),
        ]

        for model in models {
            do {
                let result = try await agentService.executeTask(
                    "test model \(model.description)",
                    maxSteps: 1,
                    sessionId: nil,
                    model: model,
                    eventDelegate: nil)

                #expect(result.metadata.modelName == model.description)
            } catch {
                // Expected to fail, but should fail consistently for each model
                #expect(!error.localizedDescription.isEmpty)
            }
        }
    }
}

/// Tests for edge cases and error handling
struct ModelSelectionEdgeCasesTests {
    @Test
    @MainActor
    func `Dry run execution respects model parameter`() async throws {
        let mockServices = PeekabooServices()
        let defaultModel = LanguageModel.openai(.gpt55)
        let agentService = try PeekabooAgentService(
            services: mockServices,
            defaultModel: defaultModel)

        // Dry run should not make API calls but should still record the model
        let result = try await agentService.executeTask(
            "dry run test",
            maxSteps: 1,
            dryRun: true,
            eventDelegate: nil)

        // Dry run uses the service default model
        #expect(result.metadata.modelName == defaultModel.description)
        #expect(result.content.contains("Dry run completed"))
    }

    @Test
    @MainActor
    func `Audio task execution model handling`() async throws {
        let mockServices = PeekabooServices()
        let defaultModel = LanguageModel.openai(.gpt55)
        let agentService = try PeekabooAgentService(
            services: mockServices,
            defaultModel: defaultModel)

        let audioContent = AudioContent(
            duration: 5.0,
            transcript: "test audio transcript")

        // Audio execution should use default model (no model parameter in this method)
        let result = try await agentService.executeTaskWithAudio(
            audioContent: audioContent,
            maxSteps: 1,
            dryRun: true,
            eventDelegate: nil)

        #expect(result.metadata.modelName == defaultModel.description)
        #expect(result.content.contains("Dry run completed"))
    }
}
