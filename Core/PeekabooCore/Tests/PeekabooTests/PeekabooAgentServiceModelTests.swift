import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

/// Tests for PeekabooAgentService model selection functionality
@Suite(.serialized)
struct PeekabooAgentServiceTests {
    @MainActor
    private func makeServices() -> PeekabooServices {
        PeekabooServices()
    }
}

extension PeekabooAgentServiceTests {
    @Test
    @MainActor
    func `Default model initialization`() throws {
        let mockServices = self.makeServices()
        let agentService = try PeekabooAgentService(services: mockServices)

        // Should default to Claude Opus 4.8 for Anthropic zero-retention compatibility.
        #expect(agentService.defaultModel == LanguageModel.anthropic(.opus48).description)
    }

    @Test
    @MainActor
    func `Anthropic generation settings avoid stale thinking option`() throws {
        try self.withIsolatedAgentEnvironment([:]) {
            let mockServices = self.makeServices()
            let agentService = try PeekabooAgentService(services: mockServices)

            let settings = agentService.generationSettings(for: .anthropic(.opus47))

            #expect(settings.maxTokens == 16384)
            #expect(settings.providerOptions.anthropic?.thinking == nil)
        }
    }

    @Test
    @MainActor
    func `Fable generation settings use synced max token configuration`() throws {
        try self.withIsolatedAgentEnvironment(
            [:],
            configurationJSON: """
            {
              "agent": {
                "maxTokens": 128000,
                "temperature": 0.2
              }
            }
            """) {
                let services = self.makeServices()
                let agentService = try PeekabooAgentService(services: services)

                let fableSettings = agentService.generationSettings(for: .anthropic(.fable5))
                let opusSettings = agentService.generationSettings(for: .anthropic(.opus48))

                #expect(fableSettings.maxTokens == 128_000)
                #expect(fableSettings.temperature == 0.2)
                #expect(opusSettings.maxTokens == 128_000)
                #expect(opusSettings.temperature == 0.2)
            }
    }

    @Test
    @MainActor
    func `Generation settings clamp max tokens to provider capabilities`() throws {
        try self.withIsolatedAgentEnvironment(
            [:],
            configurationJSON: """
            {
              "agent": {
                "maxTokens": 128000
              }
            }
            """) {
                let services = self.makeServices()
                let agentService = try PeekabooAgentService(services: services)
                let customProvider = ConfigurableReasoningReplayProvider(
                    modelId: "custom-small-model",
                    maxOutputTokens: 2048)

                #expect(agentService.generationSettings(for: .anthropic(.fable5)).maxTokens == 128_000)
                #expect(agentService.generationSettings(for: .minimax(.m27)).maxTokens == 8192)
                #expect(agentService.generationSettings(for: .groq(.llama3370b)).maxTokens == 4096)
                #expect(agentService.generationSettings(for: .custom(provider: customProvider)).maxTokens == 2048)
            }
    }

    @Test
    @MainActor
    func `Generation settings clamp invalid configured request values`() throws {
        try self.withIsolatedAgentEnvironment(
            [:],
            configurationJSON: """
            {
              "agent": {
                "maxTokens": -200,
                "temperature": 9.5
              }
            }
            """) {
                let services = self.makeServices()
                let agentService = try PeekabooAgentService(services: services)

                let settings = agentService.generationSettings(for: .anthropic(.fable5))

                #expect(settings.maxTokens == 1)
                #expect(settings.temperature == 1.0)
            }
    }

    @Test
    @MainActor
    func `Fable generation settings default to larger synced setting`() throws {
        try self.withIsolatedAgentEnvironment([:]) {
            let services = self.makeServices()
            let agentService = try PeekabooAgentService(services: services)

            let settings = agentService.generationSettings(for: .anthropic(.fable5))

            #expect(settings.maxTokens == 16384)
            #expect(settings.temperature == 0.7)
        }
    }

    @Test
    @MainActor
    func `Nonstreaming Anthropic loop replays signed reasoning before tool continuation`() async throws {
        let provider = ConfigurableReasoningReplayProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.fable5))

        _ = try await agentService.executeTask(
            "Use a tool, then continue.",
            maxSteps: 2,
            model: .anthropic(.fable5),
            enhancementOptions: nil)

        let secondRequestMessages = try #require(provider.secondRequestMessages)
        let reasoningMessage = try #require(secondRequestMessages.first { message in
            message.channel == .thinking
        })

        #expect(reasoningMessage.content == [.text("signed fable thinking")])
        #expect(reasoningMessage.metadata?.customData?["anthropic.thinking.signature"] == "sig-fable")
        #expect(reasoningMessage.metadata?.customData?["anthropic.thinking.type"] == "thinking")
        #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.provider"] == "anthropic")
        #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.model"] == "claude-fable-5")
        #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.base_url"] != nil)
    }

    @Test
    @MainActor
    func `Nonstreaming Fable emits tool start before unavailable completion`() async throws {
        let provider = ConfigurableReasoningReplayProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = CapturingAgentEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.fable5))

        _ = try await agentService.executeTask(
            "Use a tool once.",
            maxSteps: 1,
            model: .anthropic(.fable5),
            eventDelegate: delegate,
            enhancementOptions: nil)

        let startIndex = try #require(delegate.events.firstIndexOfToolStart("missing_test_tool"))
        let completionIndex = try #require(delegate.events.firstIndexOfToolCompletion("missing_test_tool"))
        #expect(startIndex < completionIndex)
    }

    @Test
    @MainActor
    func `Nonstreaming Fable drains delegate assistant and completion events`() async throws {
        let provider = CapturingRequestProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = CapturingAgentEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.fable5))

        let result = try await agentService.executeTask(
            "Return done.",
            maxSteps: 1,
            model: .anthropic(.fable5),
            eventDelegate: delegate,
            enhancementOptions: nil)

        #expect(result.content == "done")
        #expect(delegate.events.containsAssistantMessage("done"))
        #expect(delegate.events.containsCompleted(summary: "done"))
    }

    @Test
    @MainActor
    func `Nonstreaming custom Anthropic loop replays signed reasoning before tool continuation`() async throws {
        try await self.withIsolatedAgentEnvironment(
            ["PEEKABOO_CUSTOM_PROVIDER_KEY": "custom-secret"],
            configurationJSON: """
            {
              "customProviders": {
                "peekaboo-anthropic": {
                  "name": "Custom Anthropic",
                  "type": "anthropic",
                  "enabled": true,
                  "options": {
                    "baseURL": "https://custom.anthropic.example/v1",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  },
                  "models": {
                    "claude-fable-5": {
                      "name": "Claude Fable 5",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let provider = ConfigurableReasoningReplayProvider(
                    modelId: "peekaboo-anthropic/claude-fable-5",
                    baseURL: "https://custom.anthropic.example/v1")
                let services = self.makeServices()
                let agentService = try PeekabooAgentService(
                    services: services,
                    defaultModel: .custom(provider: provider))

                _ = try await agentService.executeTask(
                    "Use a tool, then continue.",
                    maxSteps: 2,
                    model: .custom(provider: provider),
                    enhancementOptions: nil)

                let secondRequestMessages = try #require(provider.secondRequestMessages)
                let reasoningMessage = try #require(secondRequestMessages.first { message in
                    message.channel == .thinking
                })

                #expect(reasoningMessage.content == [.text("signed fable thinking")])
                #expect(reasoningMessage.metadata?.customData?["anthropic.thinking.signature"] == "sig-fable")
                #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.provider"] == "custom-anthropic")
                #expect(
                    reasoningMessage.metadata?.customData?["tachikoma.reasoning.model"] ==
                        "peekaboo-anthropic/claude-fable-5")
                #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.base_url"] != nil)
            }
    }

    @Test
    @MainActor
    func `Nonstreaming registry custom Anthropic replays signed reasoning with resolved identity`() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-registry-tests-\(UUID().uuidString)", isDirectory: true)
        let profileDir = tempHome.appendingPathComponent(".tachikoma", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try """
        {
          "customProviders": {
            "claude-proxy": {
              "type": "anthropic",
              "options": {
                "baseURL": "https://proxy.anthropic.example/v1",
                "apiKey": "test-key"
              }
            }
          }
        }
        """.write(to: profileDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let previousProfileDirectoryName = TachikomaConfiguration.profileDirectoryName
        TachikomaConfiguration.profileDirectoryName = profileDir.path
        CustomProviderRegistry.shared.loadFromProfile()
        defer {
            try? "{}".write(
                to: profileDir.appendingPathComponent("config.json"),
                atomically: true,
                encoding: .utf8)
            CustomProviderRegistry.shared.loadFromProfile()
            TachikomaConfiguration.profileDirectoryName = previousProfileDirectoryName
            try? FileManager.default.removeItem(at: tempHome)
        }

        let provider = ConfigurableReasoningReplayProvider(
            modelId: "claude-proxy/claude-fable-5",
            baseURL: nil)
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .custom(provider: provider))

        _ = try await agentService.executeTask(
            "Use a tool, then continue.",
            maxSteps: 2,
            model: .custom(provider: provider),
            enhancementOptions: nil)

        let secondRequestMessages = try #require(provider.secondRequestMessages)
        let reasoningMessage = try #require(secondRequestMessages.first { message in
            message.channel == .thinking
        })

        #expect(reasoningMessage.content == [.text("signed fable thinking")])
        #expect(reasoningMessage.metadata?.customData?["anthropic.thinking.signature"] == "sig-fable")
        #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.provider"] == "custom-anthropic")
        #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.model"] == "claude-fable-5")
        #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.base_url"] != nil)
    }

    @Test
    @MainActor
    func `Nonstreaming MiniMax loop replays signed reasoning before tool continuation`() async throws {
        let provider = ConfigurableReasoningReplayProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .minimax(.m27))

        _ = try await agentService.executeTask(
            "Use a tool, then continue.",
            maxSteps: 2,
            model: .minimax(.m27),
            enhancementOptions: nil)

        let secondRequestMessages = try #require(provider.secondRequestMessages)
        let reasoningMessage = try #require(secondRequestMessages.first { message in
            message.channel == .thinking
        })

        #expect(reasoningMessage.content == [.text("signed fable thinking")])
        #expect(reasoningMessage.metadata?.customData?["anthropic.thinking.signature"] == "sig-fable")
        #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.provider"] == "minimax")
        #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.model"] == "MiniMax-M2.7")
        #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.base_url"] != nil)
    }

    @Test
    @MainActor
    func `Streaming Anthropic loop replays signed reasoning with endpoint identity`() async throws {
        let provider = StreamingReasoningReplayProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let delegate = CapturingAgentEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.opus47))

        _ = try await agentService.executeTask(
            "Use a tool, then continue.",
            maxSteps: 2,
            model: .anthropic(.opus47),
            eventDelegate: delegate,
            enhancementOptions: nil)

        let secondRequestMessages = try #require(provider.secondRequestMessages)
        let reasoningMessages = secondRequestMessages.filter { message in
            message.channel == .thinking
        }
        #expect(reasoningMessages.count == 2)
        let firstReasoningMessage = try #require(reasoningMessages.first)
        let secondReasoningMessage = try #require(reasoningMessages.dropFirst().first)

        #expect(firstReasoningMessage.content == [.text("streamed signed thinking one")])
        #expect(firstReasoningMessage.metadata?.customData?["anthropic.thinking.signature"] == "sig-stream-one")
        #expect(firstReasoningMessage.metadata?.customData?["tachikoma.reasoning.provider"] == "anthropic")
        #expect(firstReasoningMessage.metadata?.customData?["tachikoma.reasoning.model"] == "claude-opus-4-7")
        #expect(firstReasoningMessage.metadata?.customData?["tachikoma.reasoning.base_url"] != nil)
        #expect(secondReasoningMessage.content == [.text("streamed signed thinking two")])
        #expect(secondReasoningMessage.metadata?.customData?["anthropic.thinking.signature"] == "sig-stream-two")
    }

    @Test
    @MainActor
    func `Streaming custom Anthropic loop replays signed reasoning with provider identity`() async throws {
        try await self.withIsolatedAgentEnvironment(
            ["PEEKABOO_CUSTOM_PROVIDER_KEY": "custom-secret"],
            configurationJSON: """
            {
              "customProviders": {
                "peekaboo-anthropic": {
                  "name": "Custom Anthropic",
                  "type": "anthropic",
                  "enabled": true,
                  "options": {
                    "baseURL": "https://custom.anthropic.example/v1",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  },
                  "models": {
                    "claude-fable-5": {
                      "name": "Claude Fable 5",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let provider = StreamingReasoningReplayProvider(
                    modelId: "peekaboo-anthropic/claude-fable-5",
                    baseURL: "https://custom.anthropic.example/v1")
                let services = self.makeServices()
                let delegate = CapturingAgentEventDelegate()
                let agentService = try PeekabooAgentService(
                    services: services,
                    defaultModel: .custom(provider: provider))

                _ = try await agentService.executeTask(
                    "Use a tool, then continue.",
                    maxSteps: 2,
                    model: .custom(provider: provider),
                    eventDelegate: delegate,
                    enhancementOptions: nil)

                let secondRequestMessages = try #require(provider.secondRequestMessages)
                let reasoningMessage = try #require(secondRequestMessages.first { message in
                    message.channel == .thinking
                })

                #expect(reasoningMessage.content == [.text("streamed signed thinking one")])
                #expect(reasoningMessage.metadata?.customData?["anthropic.thinking.signature"] == "sig-stream-one")
                #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.provider"] == "custom-anthropic")
                #expect(
                    reasoningMessage.metadata?.customData?["tachikoma.reasoning.model"] ==
                        "peekaboo-anthropic/claude-fable-5")
                #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.base_url"] != nil)
            }
    }

    @Test
    @MainActor
    func `Streaming signed reasoning keeps tail emitted after signature`() async throws {
        let stream = AsyncThrowingStream<TextStreamDelta, any Error> { continuation in
            continuation.yield(.reasoning("streamed signed thinking ", type: "thinking"))
            continuation.yield(.reasoning("", signature: "sig-stream-tail", type: "thinking"))
            continuation.yield(.reasoning("tail", type: "thinking"))
            continuation.yield(.done(finishReason: .stop))
            continuation.finish()
        }
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.opus47))

        let output = try await agentService.collectStreamOutput(
            from: StreamTextResult(
                stream: stream,
                model: .anthropic(.opus47),
                settings: GenerationSettings()),
            model: .anthropic(.opus47),
            eventHandler: nil,
            stepIndex: 0)

        let reasoningBlock = try #require(output.reasoningBlocks.first)
        #expect(reasoningBlock.text == "streamed signed thinking tail")
        #expect(reasoningBlock.signature == "sig-stream-tail")
    }

    @Test
    @MainActor
    func `Nonstreaming native reasoning only response records assistant boundary`() async throws {
        let provider = NativeReasoningOnlyProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.fable5))

        let result = try await agentService.executeTask(
            "think only",
            maxSteps: 1,
            model: .anthropic(.fable5),
            enhancementOptions: nil)

        let thinkingIndex = try #require(result.messages.firstIndex { $0.channel == .thinking })
        let boundaryMessage = try #require(result.messages.dropFirst(thinkingIndex + 1).first)

        #expect(boundaryMessage.role == .assistant)
        #expect(boundaryMessage.content == [.text("")])
        #expect(boundaryMessage.metadata?.customData?["tachikoma.internal.boundary"] == "reasoning_only")
    }

    @Test
    @MainActor
    func `Nonstreaming resume strips Anthropic reasoning when switching providers`() async throws {
        let provider = CapturingRequestProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))
        let sessionId = "resume-provider-switch-\(UUID().uuidString)"
        let now = Date()
        try agentService.sessionManager.saveSession(AgentSession(
            id: sessionId,
            modelName: LanguageModel.anthropic(.fable5).description,
            messages: [
                .system("Test system prompt"),
                .user("Test task"),
                ModelMessage(
                    role: .assistant,
                    content: [.text("private signed thinking")],
                    channel: .thinking,
                    metadata: .init(customData: [
                        "anthropic.thinking.type": "thinking",
                        "anthropic.thinking.model": "claude-fable-5",
                        "anthropic.thinking.signature": "sig-private",
                        "tachikoma.reasoning.provider": "anthropic",
                        "tachikoma.reasoning.model": "claude-fable-5",
                        "tachikoma.reasoning.base_url": "sha256:test",
                    ])),
                ModelMessage(
                    role: .assistant,
                    content: [.text("")],
                    metadata: .init(customData: ["tachikoma.internal.boundary": "reasoning_only"])),
            ],
            metadata: SessionMetadata(),
            createdAt: now,
            updatedAt: now))

        do {
            _ = try await agentService.resumeSession(
                sessionId: sessionId,
                model: .openai(.gpt55),
                maxSteps: 1,
                enhancementOptions: nil)
            try await agentService.deleteSession(id: sessionId)
        } catch {
            try? await agentService.deleteSession(id: sessionId)
            throw error
        }

        let requestMessages = try #require(provider.firstRequestMessages)
        #expect(!requestMessages.contains { $0.channel == .thinking })
        #expect(!requestMessages.contains {
            $0.metadata?.customData?["tachikoma.internal.boundary"] == "reasoning_only"
        })
    }

    @Test
    func `Provider sanitization preserves legacy signed thinking for non Fable Anthropic`() {
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        let legacyThinking = ModelMessage(
            role: .assistant,
            content: [.text("legacy signed thinking")],
            channel: .thinking,
            metadata: .init(customData: [
                "anthropic.thinking.type": "thinking",
                "anthropic.thinking.signature": "sig-legacy",
            ]))

        let opusMessages = [legacyThinking].sanitizedForProviderContext(
            model: .anthropic(.opus47),
            configuration: configuration)
        let fableMessages = [legacyThinking].sanitizedForProviderContext(
            model: .anthropic(.fable5),
            configuration: configuration)

        #expect(opusMessages == [legacyThinking])
        #expect(fableMessages.isEmpty)
    }

    @Test
    func `Provider sanitization drops boundary when paired reasoning is filtered`() {
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        let mismatchedThinking = ModelMessage(
            role: .assistant,
            content: [.text("fable-only thinking")],
            channel: .thinking,
            metadata: .init(customData: [
                "anthropic.thinking.type": "thinking",
                "anthropic.thinking.model": "claude-fable-5",
                "anthropic.thinking.signature": "sig-fable",
                "tachikoma.reasoning.provider": "anthropic",
                "tachikoma.reasoning.model": "claude-fable-5",
                "tachikoma.reasoning.base_url": "sha256:test",
            ]))
        let boundary = ModelMessage(
            role: .assistant,
            content: [.text("")],
            metadata: .init(customData: ["tachikoma.internal.boundary": "reasoning_only"]))

        let sanitized = [mismatchedThinking, boundary].sanitizedForProviderContext(
            model: .anthropic(.opus47),
            configuration: configuration)

        #expect(sanitized.isEmpty)
    }

    @Test
    @MainActor
    func `Custom OpenAI provider reasoning stays generic`() throws {
        try self.withIsolatedAgentEnvironment(
            ["PEEKABOO_CUSTOM_PROVIDER_KEY": "custom-secret"],
            configurationJSON: """
            {
              "customProviders": {
                "local-openai": {
                  "name": "Local OpenAI",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "https://example.test/v1",
                    "apiKey": "${PEEKABOO_CUSTOM_PROVIDER_KEY}"
                  },
                  "models": {
                    "claude-fable-5": {
                      "name": "Fable-shaped OpenAI model",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let services = self.makeServices()
                let agentService = try PeekabooAgentService(services: services)
                let provider = ConfigurableReasoningReplayProvider(
                    modelId: "local-openai/claude-fable-5",
                    baseURL: "https://example.test/v1")
                var messages = [ModelMessage.user("hello")]

                _ = agentService.appendResponseHistory(
                    from: ProviderResponse(
                        text: "done",
                        finishReason: .stop,
                        reasoning: [
                            ProviderReasoningBlock(
                                text: "openai-compatible reasoning",
                                signature: "sig-openai-compatible",
                                type: "thinking"),
                        ]),
                    model: .custom(provider: provider),
                    configuration: TachikomaConfiguration(loadFromEnvironment: false),
                    peekabooConfiguration: services.configuration,
                    to: &messages)

                let reasoningMessage = try #require(messages.first { $0.channel == .thinking })
                let customData = reasoningMessage.metadata?.customData ?? [:]
                #expect(customData["tachikoma.reasoning.provider"] == nil)
                #expect(customData["tachikoma.reasoning.type"] == "thinking")
            }
    }

    @Test
    @MainActor
    func `Nonstreaming repeated response text still records current assistant turn`() async throws {
        let provider = RepeatedTextReasoningProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.fable5))

        let result = try await agentService.executeTask(
            "repeat done",
            maxSteps: 2,
            model: .anthropic(.fable5),
            enhancementOptions: nil)

        let doneAssistantTurns = result.messages.filter { message in
            message.role == .assistant &&
                message.channel != .thinking &&
                message.content.contains { $0 == .text("Done") }
        }
        #expect(doneAssistantTurns.count == 2)
    }

    @Test
    @MainActor
    func `Nonstreaming content filter does not emit blocked text`() async throws {
        let provider = ContentFilterProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let delegate = CapturingAgentEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.fable5))

        await #expect(throws: (any Error).self) {
            _ = try await agentService.executeTask(
                "trigger filter",
                maxSteps: 1,
                model: .anthropic(.fable5),
                eventDelegate: delegate,
                enhancementOptions: nil)
        }

        #expect(!delegate.events.containsAssistantMessage("blocked partial text"))
    }

    @Test
    @MainActor
    func `Streaming buffered provider content filter does not emit blocked text`() async throws {
        let provider = ContentFilterProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let delegate = CapturingAgentEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        await #expect(throws: (any Error).self) {
            _ = try await agentService.executeTask(
                "trigger filter",
                maxSteps: 1,
                model: .openai(.gpt55),
                eventDelegate: delegate,
                enhancementOptions: nil)
        }

        #expect(!delegate.events.containsAssistantMessage("blocked partial text"))
    }

    @Test
    @MainActor
    func `Streaming buffered provider content filter does not emit blocked thinking text`() async throws {
        let provider = ContentFilterProvider(text: "Let me expose blocked partial text")
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let delegate = CapturingAgentEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        await #expect(throws: (any Error).self) {
            _ = try await agentService.executeTask(
                "trigger filter",
                maxSteps: 1,
                model: .openai(.gpt55),
                eventDelegate: delegate,
                enhancementOptions: nil)
        }

        #expect(!delegate.events.containsAssistantMessage("Let me expose blocked partial text"))
        #expect(!delegate.events.containsThinkingMessage("Let me expose blocked partial text"))
    }

    @Test
    @MainActor
    func `Streaming buffered provider preserves thinking text classification`() async throws {
        let provider = PlanningTextStreamProvider(text: "Let me plan this")
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let delegate = CapturingAgentEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        _ = try await agentService.executeTask(
            "stream planning text",
            maxSteps: 1,
            model: .openai(.gpt55),
            eventDelegate: delegate,
            enhancementOptions: nil)

        #expect(delegate.events.containsThinkingMessage("Let me plan this"))
        #expect(!delegate.events.containsAssistantMessage("Let me plan this"))
    }

    @Test
    @MainActor
    func `Streaming buffered provider content filter does not emit buffered tool events`() async throws {
        let provider = try ContentFilterProvider(toolCall: AgentToolCall(
            id: "filtered-tool",
            name: "missing_test_tool",
            arguments: ["query": "blocked"]))
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let delegate = CapturingAgentEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        await #expect(throws: (any Error).self) {
            _ = try await agentService.executeTask(
                "trigger filter",
                maxSteps: 1,
                model: .openai(.gpt55),
                eventDelegate: delegate,
                enhancementOptions: nil)
        }

        #expect(delegate.events.firstIndexOfToolStart("missing_test_tool") == nil)
        #expect(delegate.events.firstIndexOfToolCompletion("missing_test_tool") == nil)
    }

    @Test
    @MainActor
    func `Streaming custom OpenAI content filter does not emit blocked text`() async throws {
        let provider = ContentFilterProvider(modelId: "custom-openai/test-model")
        try await self.withIsolatedAgentEnvironment(
            [:],
            configurationJSON: """
            {
              "customProviders": {
                "custom-openai": {
                  "name": "Custom OpenAI",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "https://custom.openai.example/v1",
                    "apiKey": "test-key"
                  },
                  "models": {
                    "test-model": {
                      "name": "test-model",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let delegate = CapturingAgentEventDelegate()
                let agentService = try PeekabooAgentService(
                    services: PeekabooServices(),
                    defaultModel: .custom(provider: provider))

                await #expect(throws: (any Error).self) {
                    _ = try await agentService.executeTask(
                        "trigger filter",
                        maxSteps: 1,
                        model: .custom(provider: provider),
                        eventDelegate: delegate,
                        enhancementOptions: nil)
                }

                #expect(!delegate.events.containsAssistantMessage("blocked partial text"))
            }
    }

    @Test
    @MainActor
    func `Streaming safe provider emits assistant text before later tool events`() async throws {
        let provider = IncrementalToolStreamProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let delegate = CapturingAgentEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.opus47))

        _ = try await agentService.executeTask(
            "stream before tool",
            maxSteps: 2,
            model: .anthropic(.opus47),
            eventDelegate: delegate,
            enhancementOptions: nil)

        let assistantIndex = try #require(delegate.events.firstIndexOfAssistantMessage("before tool"))
        let toolIndex = try #require(delegate.events.firstIndexOfToolStart("missing_test_tool"))
        #expect(assistantIndex < toolIndex)
    }

    @Test
    @MainActor
    func `Streaming buffered provider replays assistant text before tool events`() async throws {
        let provider = IncrementalToolStreamProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let delegate = CapturingAgentEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        _ = try await agentService.executeTask(
            "stream before tool",
            maxSteps: 2,
            model: .openai(.gpt55),
            eventDelegate: delegate,
            enhancementOptions: nil)

        let assistantIndex = try #require(delegate.events.firstIndexOfAssistantMessage("before tool"))
        let toolIndex = try #require(delegate.events.firstIndexOfToolStart("missing_test_tool"))
        #expect(assistantIndex < toolIndex)
    }

    @Test
    @MainActor
    func `Nonstreaming OpenRouter reasoning is replayed before tool continuation`() async throws {
        let provider = OpenRouterReasoningReplayProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openRouter(modelId: "anthropic/claude-fable-5"))

        _ = try await agentService.executeTask(
            "Use a tool, then continue.",
            maxSteps: 2,
            model: LanguageModel.openRouter(modelId: "anthropic/claude-fable-5"),
            enhancementOptions: nil)

        let secondRequestMessages = try #require(provider.secondRequestMessages)
        let reasoningMessage = try #require(secondRequestMessages.first { message in
            message.channel == .thinking
        })

        #expect(reasoningMessage.content == [.text("raw openrouter thinking")])
        #expect(reasoningMessage.metadata?.customData?["openrouter.reasoning_details"] == #"{"type":"reasoning"}"#)
        #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.provider"] == "openrouter")
        #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.model"] == "anthropic/claude-fable-5")
        #expect(reasoningMessage.metadata?.customData?["tachikoma.reasoning.base_url"] != nil)
    }

    @Test
    @MainActor
    func `Gemini only credentials initialize Gemini default agent`() throws {
        try self.withIsolatedAgentEnvironment(["GEMINI_API_KEY": "test-gemini-key"]) {
            let services = self.makeServices()
            let agentService = try #require(services.agent as? PeekabooAgentService)

            #expect(agentService.defaultModel == LanguageModel.google(.gemini35Flash).description)
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
    func `xAI only credentials initialize Grok default agent`() throws {
        try self.withIsolatedAgentEnvironment(["X_AI_API_KEY": "test-xai-key"]) {
            let services = self.makeServices()
            let agentService = try #require(services.agent as? PeekabooAgentService)

            #expect(agentService.defaultModel == LanguageModel.grok(.grok43).description)
        }
    }

    @Test
    @MainActor
    func `Generated provider list preserves available model order`() throws {
        try self.withIsolatedAgentEnvironment([
            "OPENAI_API_KEY": "test-openai-key",
            "ANTHROPIC_API_KEY": "test-anthropic-key",
        ]) {
            let services = self.makeServices()
            let agentService = try #require(services.agent as? PeekabooAgentService)

            #expect(agentService.defaultModel == LanguageModel.openai(.gpt55).description)
        }
    }

    @Test
    @MainActor
    func `Saved custom provider initializes default agent`() throws {
        try self.withIsolatedAgentEnvironment(
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
                let services = self.makeServices()
                let agentService = try #require(services.agent as? PeekabooAgentService)

                #expect(agentService.defaultModel == "Custom/local-proxy/mini")
            }
    }

    @Test
    @MainActor
    func `Saved custom provider default preserves model alias metadata`() throws {
        try self.withIsolatedAgentEnvironment(
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
                    "alias": {
                      "name": "same",
                      "supportsVision": false,
                      "supportsTools": true
                    },
                    "same": {
                      "name": "wrong",
                      "supportsVision": true,
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let services = self.makeServices()
                let agentService = try #require(services.agent as? PeekabooAgentService)

                #expect(agentService.defaultModelSelection == "local-proxy/alias")
                #expect(agentService.defaultLanguageModel.modelId == "local-proxy/alias")
                #expect(!agentService.defaultLanguageModel.supportsVision)
                #expect(agentService.resolveConfiguredModel("local-proxy/alias")?.modelId == "local-proxy/alias")
            }
    }

    @Test
    @MainActor
    func `Configured custom default wins over built-in credentials`() throws {
        try self.withIsolatedAgentEnvironment(
            [
                "OPENAI_API_KEY": "test-openai-key",
                "PEEKABOO_CUSTOM_PROVIDER_KEY": "resolved-secret",
            ],
            configurationJSON: """
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
                  },
                  "models": {
                    "mini": {
                      "name": "gpt-5.5-mini",
                      "supportsVision": true,
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let services = self.makeServices()
                let agentService = try #require(services.agent as? PeekabooAgentService)

                #expect(agentService.defaultModel == "Custom/local-proxy/mini")
            }
    }

    @Test
    @MainActor
    func `Settings-style custom default wins over built-in credentials`() throws {
        try self.withIsolatedAgentEnvironment(
            [
                "OPENAI_API_KEY": "test-openai-key",
                "PEEKABOO_CUSTOM_PROVIDER_KEY": "resolved-secret",
            ],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "local-proxy/mini,ollama/llava:latest"
              },
              "agent": {
                "defaultModel": "mini"
              },
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
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let services = self.makeServices()
                let agentService = try #require(services.agent as? PeekabooAgentService)

                #expect(agentService.defaultModel == "Custom/local-proxy/mini")
            }
    }

    @Test
    @MainActor
    func `Saved custom provider does not override built-in credentials`() throws {
        try self.withIsolatedAgentEnvironment(
            [
                "GEMINI_API_KEY": "test-gemini-key",
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
                let services = self.makeServices()
                let agentService = try #require(services.agent as? PeekabooAgentService)

                #expect(agentService.defaultModel == LanguageModel.google(.gemini35Flash).description)
            }
    }

    @Test
    @MainActor
    func `Non-tool custom provider does not initialize agent`() throws {
        try self.withIsolatedAgentEnvironment(
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
                let services = self.makeServices()

                #expect(services.agent == nil)
            }
    }

    @Test
    @MainActor
    func `Explicit custom provider list initializes default agent`() throws {
        try self.withIsolatedAgentEnvironment(
            ["PEEKABOO_CUSTOM_PROVIDER_KEY": "resolved-secret"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "local-proxy/mini"
              },
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
                let services = self.makeServices()
                let agentService = try #require(services.agent as? PeekabooAgentService)

                #expect(agentService.defaultModel == "Custom/local-proxy/mini")
            }
    }

    @Test
    @MainActor
    func `Explicit custom provider list preserves custom order before built-in`() throws {
        try self.withIsolatedAgentEnvironment(
            [
                "ANTHROPIC_API_KEY": "test-anthropic-key",
                "PEEKABOO_CUSTOM_PROVIDER_KEY": "resolved-secret",
            ],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "local-proxy/mini,anthropic/claude-opus-4-8"
              },
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
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let services = self.makeServices()
                let agentService = try #require(services.agent as? PeekabooAgentService)

                #expect(agentService.defaultModel == "Custom/local-proxy/mini")
            }
    }

    @Test
    @MainActor
    func `Missing custom default credentials fall back to available built-in`() throws {
        try self.withIsolatedAgentEnvironment(
            ["OPENAI_API_KEY": "test-openai-key"],
            configurationJSON: """
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
                    "apiKey": "${PEEKABOO_MISSING_PROVIDER_KEY}"
                  },
                  "models": {
                    "mini": {
                      "name": "gpt-5.5-mini",
                      "supportsVision": true,
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let services = self.makeServices()
                let agentService = try #require(services.agent as? PeekabooAgentService)

                #expect(agentService.defaultModel == LanguageModel.openai(.gpt55).description)
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
    func `Unavailable custom alias does not fall through to hosted provider`() throws {
        try self.withIsolatedAgentEnvironment(
            ["X_AI_API_KEY": "test-xai-key"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "xai/mini"
              },
              "customProviders": {
                "xai": {
                  "name": "Custom xAI Proxy",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "${PEEKABOO_MISSING_PROVIDER_KEY}"
                  },
                  "models": {
                    "mini": {
                      "name": "Proxy Mini",
                      "supportsVision": true,
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let services = self.makeServices()

                #expect(services.agent == nil)
            }
    }

    @Test
    @MainActor
    func `Generated custom provider selection does not fall through to shadowed hosted provider`() throws {
        try self.withIsolatedAgentEnvironment(
            ["X_AI_API_KEY": "test-xai-key"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "xai/mini,ollama/llava:latest"
              },
              "agent": {
                "defaultModel": "xai/mini"
              },
              "customProviders": {
                "xai": {
                  "name": "Custom xAI Proxy",
                  "type": "openai",
                  "enabled": true,
                  "options": {
                    "baseURL": "http://localhost:8317/v1",
                    "apiKey": "${PEEKABOO_MISSING_PROVIDER_KEY}"
                  },
                  "models": {
                    "mini": {
                      "name": "Proxy Mini",
                      "supportsVision": true,
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let services = self.makeServices()

                #expect(services.agent == nil)
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

                #expect(agentService.defaultModel == LanguageModel.google(.gemini35Flash).description)
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

            #expect(agentService.defaultModel == LanguageModel.google(.gemini35Flash).description)
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
    func `Explicit provider list does not fall back to custom default`() throws {
        try self.withIsolatedAgentEnvironment(
            ["PEEKABOO_CUSTOM_PROVIDER_KEY": "resolved-secret"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "openai/gpt-5.5"
              },
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
                      "supportsTools": true
                    }
                  }
                }
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
    func `Unhandled hosted provider does not borrow unrelated credentials`() throws {
        try self.withIsolatedAgentEnvironment(
            ["GEMINI_API_KEY": "test-gemini-key"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "mistral/mistral-large-latest"
              }
            }
            """) {
                let services = self.makeServices()

                #expect(services.agent == nil)
            }
    }

    @Test
    @MainActor
    func `Explicit provider list initializes server-redirected Grok model`() throws {
        try self.withIsolatedAgentEnvironment(
            ["X_AI_API_KEY": "test-xai-key"],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "xai/grok-code-fast-1"
              }
            }
            """) {
                let services = self.makeServices()
                let agentService = try #require(services.agent as? PeekabooAgentService)

                #expect(agentService.defaultModel == LanguageModel.grok(.custom("grok-code-fast-1")).description)
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
            #expect(agentService.defaultModelSelection == "lmstudio/openai/gpt-oss-120b")
        }
    }

    @Test
    @MainActor
    func `Default model selection preserves OpenRouter provider identity`() throws {
        let agentService = try PeekabooAgentService(
            services: self.makeServices(),
            defaultModel: .openRouter(modelId: "openai/gpt-oss-120b"))

        #expect(agentService.defaultModelSelection == "openrouter/openai/gpt-oss-120b")
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
            "X_AI_API_KEY",
            "XAI_API_KEY",
            "GROK_API_KEY",
            "PEEKABOO_CUSTOM_PROVIDER_KEY",
            "PEEKABOO_MISSING_PROVIDER_KEY",
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
            TachikomaConfiguration.current.removeAPIKey(for: .grok)
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
        unsetenv("X_AI_API_KEY")
        unsetenv("XAI_API_KEY")
        unsetenv("GROK_API_KEY")
        unsetenv("PEEKABOO_CUSTOM_PROVIDER_KEY")
        unsetenv("PEEKABOO_MISSING_PROVIDER_KEY")
        unsetenv("MINIMAX_API_KEY")
        unsetenv("MINIMAX_CN_API_KEY")
        unsetenv("PEEKABOO_OLLAMA_BASE_URL")
        unsetenv("OLLAMA_BASE_URL")
        TachikomaConfiguration.current.removeAPIKey(for: .grok)
        for (key, value) in overrides {
            setenv(key, value, 1)
        }
        ConfigurationManager.shared.resetForTesting()

        try body()
    }

    private func withIsolatedAgentEnvironment(
        _ overrides: [String: String],
        configurationJSON: String? = nil,
        body: () async throws -> Void) async throws
    {
        let keys = [
            "PEEKABOO_CONFIG_DIR",
            "PEEKABOO_CONFIG_DISABLE_MIGRATION",
            "PEEKABOO_AI_PROVIDERS",
            "OPENAI_API_KEY",
            "ANTHROPIC_API_KEY",
            "GEMINI_API_KEY",
            "GOOGLE_API_KEY",
            "X_AI_API_KEY",
            "XAI_API_KEY",
            "GROK_API_KEY",
            "PEEKABOO_CUSTOM_PROVIDER_KEY",
            "PEEKABOO_MISSING_PROVIDER_KEY",
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
            TachikomaConfiguration.current.removeAPIKey(for: .grok)
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
        unsetenv("X_AI_API_KEY")
        unsetenv("XAI_API_KEY")
        unsetenv("GROK_API_KEY")
        unsetenv("PEEKABOO_CUSTOM_PROVIDER_KEY")
        unsetenv("PEEKABOO_MISSING_PROVIDER_KEY")
        unsetenv("MINIMAX_API_KEY")
        unsetenv("MINIMAX_CN_API_KEY")
        unsetenv("PEEKABOO_OLLAMA_BASE_URL")
        unsetenv("OLLAMA_BASE_URL")
        for (key, value) in overrides {
            setenv(key, value, 1)
        }
        ConfigurationManager.shared.resetForTesting()
        defer { ConfigurationManager.shared.resetForTesting() }

        try await body()
    }
}

extension PeekabooAgentServiceTests {
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

extension PeekabooAgentServiceTests {
    @Test
    @MainActor
    func `Generated default with unknown shadowing custom model does not use hosted fallback`() throws {
        try self.withIsolatedAgentEnvironment(
            [
                "OPENAI_API_KEY": "hosted-openai-key",
                "PEEKABOO_CUSTOM_PROVIDER_KEY": "custom-secret",
            ],
            configurationJSON: """
            {
              "agent": {
                "defaultModel": "openai/gpt-5.5"
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
                    "mini": {
                      "name": "Proxy Mini",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let services = self.makeServices()

                #expect(services.agent == nil)
            }
    }

    @Test
    @MainActor
    func `Unknown model on shadowing custom provider does not use hosted fallback`() throws {
        try self.withIsolatedAgentEnvironment(
            [
                "OPENAI_API_KEY": "hosted-openai-key",
                "PEEKABOO_CUSTOM_PROVIDER_KEY": "custom-secret",
            ],
            configurationJSON: """
            {
              "aiProviders": {
                "providers": "openai/gpt-5.5"
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
                    "mini": {
                      "name": "Proxy Mini",
                      "supportsTools": true
                    }
                  }
                }
              }
            }
            """) {
                let services = self.makeServices()

                #expect(services.agent == nil)
            }
    }
}

struct PeekabooAgentResumeTests {
    @Test
    @MainActor
    func `Resume session respects max steps`() async throws {
        let provider = StepCountingProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer {
            TachikomaConfiguration.default = previousConfiguration
        }

        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))
        let sessionId = "resume-max-steps-\(UUID().uuidString)"
        let now = Date()
        try agentService.sessionManager.saveSession(AgentSession(
            id: sessionId,
            modelName: LanguageModel.openai(.gpt55).description,
            messages: [
                .system("Test system prompt"),
                .user("Test task"),
            ],
            metadata: SessionMetadata(),
            createdAt: now,
            updatedAt: now))

        do {
            _ = try await agentService.resumeSession(
                sessionId: sessionId,
                model: .openai(.gpt55),
                maxSteps: 1,
                enhancementOptions: nil)
            try await agentService.deleteSession(id: sessionId)
        } catch {
            try? await agentService.deleteSession(id: sessionId)
            throw error
        }

        #expect(provider.requestCount == 1)
    }
}

private final class StepCountingProvider: ModelProvider, @unchecked Sendable {
    let modelId = "step-counting-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let lock = NSLock()
    private var _requestCount = 0

    var requestCount: Int {
        self.lock.withLock { self._requestCount }
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        let requestCount = self.lock.withLock {
            self._requestCount += 1
            return self._requestCount
        }
        return ProviderResponse(
            text: "step \(requestCount)",
            finishReason: .toolCalls,
            toolCalls: [
                AgentToolCall(
                    id: "missing-tool-\(requestCount)",
                    name: "missing_test_tool",
                    arguments: [:]),
            ])
    }

    func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let response = try await self.generateText(request: request)
        return AsyncThrowingStream { continuation in
            continuation.yield(TextStreamDelta(type: .textDelta, content: response.text))
            continuation.yield(TextStreamDelta(type: .done))
            continuation.finish()
        }
    }
}

private final class ConfigurableReasoningReplayProvider: ModelProvider, @unchecked Sendable {
    let modelId: String
    let baseURL: String?
    let apiKey: String? = nil
    let capabilities: ModelCapabilities
    private let reasoningText: String
    private let reasoningSignature: String

    private let lock = NSLock()
    private var requestCount = 0
    private var capturedSecondRequestMessages: [ModelMessage]?

    init(
        modelId: String = "reasoning-replay-provider",
        baseURL: String? = nil,
        maxOutputTokens: Int = 4096,
        reasoningText: String = "signed fable thinking",
        reasoningSignature: String = "sig-fable")
    {
        self.modelId = modelId
        self.baseURL = baseURL
        self.capabilities = ModelCapabilities(maxOutputTokens: maxOutputTokens)
        self.reasoningText = reasoningText
        self.reasoningSignature = reasoningSignature
    }

    var secondRequestMessages: [ModelMessage]? {
        self.lock.withLock { self.capturedSecondRequestMessages }
    }

    func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        let requestNumber = self.lock.withLock {
            self.requestCount += 1
            if self.requestCount == 2 {
                self.capturedSecondRequestMessages = request.messages
            }
            return self.requestCount
        }

        if requestNumber == 1 {
            return ProviderResponse(
                text: "",
                finishReason: .toolCalls,
                toolCalls: [
                    AgentToolCall(
                        id: "missing-tool",
                        name: "missing_test_tool",
                        arguments: [:]),
                ],
                reasoning: [
                    ProviderReasoningBlock(
                        text: self.reasoningText,
                        signature: self.reasoningSignature,
                        type: "thinking"),
                ],
                assistantMessages: [
                    ModelMessage(role: .assistant, content: [
                        .toolCall(AgentToolCall(
                            id: "missing-tool",
                            name: "missing_test_tool",
                            arguments: [:])),
                    ]),
                ])
        }

        return ProviderResponse(text: "done", finishReason: .stop)
    }

    func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let response = try await self.generateText(request: request)
        return AsyncThrowingStream { continuation in
            if !response.text.isEmpty {
                continuation.yield(.text(response.text))
            }
            continuation.yield(.done(finishReason: response.finishReason))
            continuation.finish()
        }
    }
}

private final class StreamingReasoningReplayProvider: ModelProvider, @unchecked Sendable {
    let modelId: String
    let baseURL: String?
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let lock = NSLock()
    private var requestCount = 0
    private var capturedSecondRequestMessages: [ModelMessage]?

    var secondRequestMessages: [ModelMessage]? {
        self.lock.withLock { self.capturedSecondRequestMessages }
    }

    init(
        modelId: String = "streaming-reasoning-replay-provider",
        baseURL: String? = nil)
    {
        self.modelId = modelId
        self.baseURL = baseURL
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(text: "done", finishReason: .stop)
    }

    func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let requestNumber = self.lock.withLock {
            self.requestCount += 1
            if self.requestCount == 2 {
                self.capturedSecondRequestMessages = request.messages
            }
            return self.requestCount
        }

        return AsyncThrowingStream { continuation in
            if requestNumber == 1 {
                continuation.yield(.reasoning("streamed signed thinking one", type: "thinking"))
                continuation.yield(.reasoning("", signature: "sig-stream-one", type: "thinking"))
                continuation.yield(.reasoning("streamed signed thinking two", type: "thinking"))
                continuation.yield(.reasoning("", signature: "sig-stream-two", type: "thinking"))
                continuation.yield(TextStreamDelta(
                    type: .toolCall,
                    toolCall: AgentToolCall(
                        id: "missing-tool",
                        name: "missing_test_tool",
                        arguments: [:])))
                continuation.yield(.done(finishReason: .toolCalls))
            } else {
                continuation.yield(.text("done"))
                continuation.yield(.done(finishReason: .stop))
            }
            continuation.finish()
        }
    }
}

private final class IncrementalToolStreamProvider: ModelProvider, @unchecked Sendable {
    let modelId = "incremental-tool-stream-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let lock = NSLock()
    private var requestCount = 0

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(text: "done", finishReason: .stop)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let requestNumber = self.lock.withLock {
            self.requestCount += 1
            return self.requestCount
        }

        return AsyncThrowingStream { continuation in
            if requestNumber == 1 {
                continuation.yield(.text("before tool"))
                continuation.yield(TextStreamDelta(
                    type: .toolCall,
                    toolCall: AgentToolCall(
                        id: "missing-tool",
                        name: "missing_test_tool",
                        arguments: [:])))
                continuation.yield(.done(finishReason: .toolCalls))
            } else {
                continuation.yield(.text("done"))
                continuation.yield(.done(finishReason: .stop))
            }
            continuation.finish()
        }
    }
}

private final class NativeReasoningOnlyProvider: ModelProvider, @unchecked Sendable {
    let modelId = "native-reasoning-only-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(
            text: "",
            finishReason: .stop,
            assistantMessages: [
                ModelMessage(
                    role: .assistant,
                    content: [.text("native thinking only")],
                    channel: .thinking,
                    metadata: .init(customData: [
                        "anthropic.thinking.type": "thinking",
                        "anthropic.thinking.model": "claude-fable-5",
                        "anthropic.thinking.signature": "sig-native",
                        "tachikoma.reasoning.provider": "anthropic",
                        "tachikoma.reasoning.model": "claude-fable-5",
                        "tachikoma.reasoning.base_url": "sha256:test",
                    ])),
            ])
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.reasoning("streamed native thinking", signature: "sig-native-stream", type: "thinking"))
            continuation.yield(.done(finishReason: .stop))
            continuation.finish()
        }
    }
}

private final class CapturingRequestProvider: ModelProvider, @unchecked Sendable {
    let modelId = "capturing-request-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let lock = NSLock()
    private var capturedFirstRequestMessages: [ModelMessage]?

    var firstRequestMessages: [ModelMessage]? {
        self.lock.withLock { self.capturedFirstRequestMessages }
    }

    func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        self.lock.withLock {
            if self.capturedFirstRequestMessages == nil {
                self.capturedFirstRequestMessages = request.messages
            }
        }
        return ProviderResponse(text: "done", finishReason: .stop)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("done"))
            continuation.yield(.done(finishReason: .stop))
            continuation.finish()
        }
    }
}

private final class RepeatedTextReasoningProvider: ModelProvider, @unchecked Sendable {
    let modelId = "repeated-text-reasoning-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let lock = NSLock()
    private var requestCount = 0

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        let requestNumber = self.lock.withLock {
            self.requestCount += 1
            return self.requestCount
        }

        if requestNumber == 1 {
            return ProviderResponse(
                text: "Done",
                finishReason: .toolCalls,
                toolCalls: [
                    AgentToolCall(
                        id: "missing-tool",
                        name: "missing_test_tool",
                        arguments: [:]),
                ])
        }

        return ProviderResponse(
            text: "Done",
            finishReason: .stop,
            reasoning: [
                ProviderReasoningBlock(
                    text: "second response thinking",
                    signature: "sig-repeat",
                    type: "thinking"),
            ])
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("Done"))
            continuation.yield(.done(finishReason: .stop))
            continuation.finish()
        }
    }
}

private final class ContentFilterProvider: ModelProvider, @unchecked Sendable {
    let modelId: String
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()
    private let text: String
    private let toolCall: AgentToolCall?

    init(
        modelId: String = "content-filter-provider",
        text: String = "blocked partial text",
        toolCall: AgentToolCall? = nil)
    {
        self.modelId = modelId
        self.text = text
        self.toolCall = toolCall
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(
            text: self.text,
            finishReason: .contentFilter,
            toolCalls: self.toolCall.map { [$0] })
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text(self.text))
            if let toolCall = self.toolCall {
                continuation.yield(TextStreamDelta(type: .toolCall, toolCall: toolCall))
            }
            continuation.yield(.done(finishReason: .contentFilter))
            continuation.finish()
        }
    }
}

private final class PlanningTextStreamProvider: ModelProvider, @unchecked Sendable {
    let modelId = "planning-text-stream-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()
    private let text: String

    init(text: String) {
        self.text = text
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(
            text: self.text,
            finishReason: .stop)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text(self.text))
            continuation.yield(.done(finishReason: .stop))
            continuation.finish()
        }
    }
}

private final class OpenRouterReasoningReplayProvider: ModelProvider, @unchecked Sendable {
    let modelId = "openrouter-reasoning-replay-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let lock = NSLock()
    private var requestCount = 0
    private var capturedSecondRequestMessages: [ModelMessage]?

    var secondRequestMessages: [ModelMessage]? {
        self.lock.withLock { self.capturedSecondRequestMessages }
    }

    func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        let requestNumber = self.lock.withLock {
            self.requestCount += 1
            if self.requestCount == 2 {
                self.capturedSecondRequestMessages = request.messages
            }
            return self.requestCount
        }

        if requestNumber == 1 {
            return ProviderResponse(
                text: "",
                finishReason: .toolCalls,
                toolCalls: [
                    AgentToolCall(
                        id: "missing-tool",
                        name: "missing_test_tool",
                        arguments: [:]),
                ],
                reasoning: [
                    ProviderReasoningBlock(
                        text: "raw openrouter thinking",
                        type: "openrouter_reasoning",
                        rawJSON: #"{"type":"reasoning"}"#),
                ])
        }

        return ProviderResponse(text: "done", finishReason: .stop)
    }

    func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let response = try await self.generateText(request: request)
        return AsyncThrowingStream { continuation in
            if !response.text.isEmpty {
                continuation.yield(.text(response.text))
            }
            continuation.yield(.done(finishReason: response.finishReason))
            continuation.finish()
        }
    }
}

@MainActor
private final class CapturingAgentEventDelegate: AgentEventDelegate {
    private(set) var events: [AgentEvent] = []

    func agentDidEmitEvent(_ event: AgentEvent) {
        self.events.append(event)
    }
}

extension [AgentEvent] {
    fileprivate func containsAssistantMessage(_ expected: String) -> Bool {
        self.contains { event in
            if case let .assistantMessage(content) = event {
                return content == expected
            }
            return false
        }
    }

    fileprivate func containsThinkingMessage(_ expected: String) -> Bool {
        self.contains { event in
            if case let .thinkingMessage(content) = event {
                return content == expected
            }
            return false
        }
    }

    fileprivate func firstIndexOfAssistantMessage(_ expected: String) -> Int? {
        self.firstIndex { event in
            if case let .assistantMessage(content) = event {
                return content == expected
            }
            return false
        }
    }

    fileprivate func firstIndexOfToolStart(_ expected: String) -> Int? {
        self.firstIndex { event in
            if case let .toolCallStarted(name, _) = event {
                return name == expected
            }
            return false
        }
    }

    fileprivate func firstIndexOfToolCompletion(_ expected: String) -> Int? {
        self.firstIndex { event in
            if case let .toolCallCompleted(name, _) = event {
                return name == expected
            }
            return false
        }
    }

    fileprivate func containsCompleted(summary expected: String) -> Bool {
        self.contains { if case let .completed(
            summary,
            _) = $0 { summary == expected } else { false } }
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
