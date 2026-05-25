import PeekabooFoundation
import Tachikoma
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
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
    func `Supported Anthropic aliases map to Claude Opus 4.7`() throws {
        let command = try AgentCommand.parse([])

        #expect(command.parseModelString("claude-opus-4.7") == .anthropic(.opus47))
        #expect(command.parseModelString("claude-sonnet-4.6") == .anthropic(.opus47))
        #expect(command.parseModelString("claude-sonnet-4.5") == .anthropic(.opus47))
        #expect(command.parseModelString("Claude-Sonnet-4.5") == .anthropic(.opus47))
        #expect(command.parseModelString("claude") == .anthropic(.opus47))
        #expect(command.parseModelString("claude-opus-4") == .anthropic(.opus47))
        #expect(command.parseModelString("claude-3-sonnet") == nil)
    }

    @Test
    func `Unsupported providers are rejected`() throws {
        let command = try AgentCommand.parse([])

        #expect(command.parseModelString("grok-4") == nil)
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

        #expect(command.parseModelString("gemini-3.1-pro-preview") == .google(.gemini31ProPreview))
        #expect(command.parseModelString("gemini-3.1-flash-lite") == .google(.gemini31FlashLite))
        #expect(command.parseModelString("gemini-3-flash") == .google(.gemini3Flash))
        #expect(command.parseModelString("gemini") == .google(.gemini31ProPreview))
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
        #expect(command.parseModelString(" claude-sonnet-4.5 ") == .anthropic(.opus47))
        #expect(command.parseModelString(" gemini-3-flash ") == .google(.gemini3Flash))
        #expect(command.parseModelString(" minimax-m2.7 ") == .minimax(.m27))
        #expect(command.parseModelString(" minimax-cn/m2.7 ") == .minimaxCN(.m27))
        #expect(command.parseModelString(" ollama/llama3.3 ") == .ollama(.llama33))
    }
}

/// Tests for model selection integration
@Suite(.tags(.safe))
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
            ("claude-opus-4.7", .anthropic(.opus47)),
            ("gemini-3.1-pro-preview", .google(.gemini31ProPreview)),
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
