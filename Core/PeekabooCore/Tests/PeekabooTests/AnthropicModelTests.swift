import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

struct AnthropicModelTests {
    @Test
    func `Anthropic model selection and properties`() {
        // Test current Anthropic models
        let opus45 = Model.anthropic(.opus45)
        let sonnet46 = Model.anthropic(.sonnet46)
        let haiku45 = Model.anthropic(.haiku45)

        #expect(opus45.providerName == "Anthropic")
        #expect(sonnet46.providerName == "Anthropic")
        #expect(haiku45.providerName == "Anthropic")

        // Test model capabilities
        #expect(opus45.supportsVision == true)
        #expect(opus45.supportsTools == true)
        #expect(opus45.supportsStreaming == true)
        #expect(opus45.contextLength > 100_000) // All Claude models have large context

        // Test model IDs
        #expect(opus45.modelId.contains("opus"))
        #expect(sonnet46.modelId.contains("sonnet"))
        #expect(haiku45.modelId.contains("haiku"))
    }

    @Test
    func `Anthropic default model selection`() {
        // Tachikoma keeps the library-level Claude shortcut stable; Peekaboo chooses Fable separately.
        let defaultModel = Model.default
        let claudeModel = Model.claude

        #expect(defaultModel.providerName == "Anthropic")
        #expect(claudeModel.providerName == "Anthropic")
        #expect(defaultModel.modelId == "claude-opus-4-8")
        #expect(claudeModel.modelId == "claude-opus-4-8")

        // Test model shortcuts
        let anthropicModels = [
            Model.anthropic(.opus45),
            Model.anthropic(.sonnet46),
            Model.anthropic(.haiku45),
        ]

        for model in anthropicModels {
            #expect(model.providerName == "Anthropic")
            #expect(!model.modelId.isEmpty)
        }
    }

    @Test(.enabled(if: false)) // Disabled - requires API key
    func `Anthropic model generation integration`() async throws {
        // This test would require real API credentials
        // Testing the integration without actual API calls

        let model = Model.anthropic(.opus45)
        let messages = [
            ModelMessage.user("What is 2+2?"),
        ]

        // Test that the API call structure is correct (would fail without API key)
        do {
            _ = try await generateText(
                model: model,
                messages: messages,
                tools: nil,
                settings: .default,
                maxSteps: 1)
            #expect(Bool(true)) // Should not reach here without API key
        } catch {
            // Expected to fail without API key - this is testing the structure
            #expect(error is TachikomaError)
        }
    }

    @Test
    func `Anthropic vision model capabilities`() {
        let visionCapableModels = [
            Model.anthropic(.fable5),
            Model.anthropic(.opus45),
            Model.anthropic(.sonnet46),
            Model.anthropic(.haiku45),
        ]

        for model in visionCapableModels {
            #expect(model.supportsVision == true)
        }
    }

    @Test
    func `Anthropic model comparison`() {
        let opus45 = Model.anthropic(.opus45)
        let sonnet46 = Model.anthropic(.sonnet46)
        let haiku45 = Model.anthropic(.haiku45)

        // Test model descriptions
        #expect(opus45.description.contains("Anthropic"))
        #expect(sonnet46.description.contains("Anthropic"))
        #expect(haiku45.description.contains("Anthropic"))

        // Test that they're different models
        #expect(opus45.modelId != sonnet46.modelId)
        #expect(sonnet46.modelId != haiku45.modelId)
        #expect(opus45.modelId != haiku45.modelId)

        // Current Anthropic context windows are model-specific, not a simple family hierarchy.
        #expect(Model.anthropic(.fable5).contextLength == 1_000_000)
        #expect(Model.anthropic(.opus48).contextLength == 1_000_000)
        #expect(sonnet46.contextLength == 1_000_000)
        #expect(opus45.contextLength == 500_000)
        #expect(haiku45.contextLength == 200_000)
        #expect(sonnet46.contextLength >= haiku45.contextLength)
    }

    @Test
    func `Anthropic current models support tools`() {
        let fable5 = Model.anthropic(.fable5)
        let opus48 = Model.anthropic(.opus48)
        let sonnet46 = Model.anthropic(.sonnet46)

        #expect(fable5.providerName == "Anthropic")
        #expect(opus48.providerName == "Anthropic")
        #expect(sonnet46.providerName == "Anthropic")

        #expect(!fable5.modelId.contains("thinking"))
        #expect(!opus48.modelId.contains("thinking"))
        #expect(!sonnet46.modelId.contains("thinking"))

        #expect(fable5.supportsTools == true)
        #expect(fable5.supportsStreaming == false)
        #expect(opus48.supportsTools == true)
        #expect(sonnet46.supportsTools == true)
    }
}
