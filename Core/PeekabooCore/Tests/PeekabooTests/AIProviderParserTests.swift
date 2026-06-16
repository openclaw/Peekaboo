import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

struct AIProviderParserTests {
    @Test
    func `Parse single provider`() {
        #expect(AIProviderParser.parse("openai/gpt-5.5") == AIProviderParser.ProviderConfig(
            provider: "openai",
            model: "gpt-5.5"))
        #expect(AIProviderParser.parse("anthropic/claude-opus-4-7") == AIProviderParser.ProviderConfig(
            provider: "anthropic",
            model: "claude-opus-4-7"))
        #expect(AIProviderParser.parse("ollama/llava:latest") == AIProviderParser.ProviderConfig(
            provider: "ollama",
            model: "llava:latest"))
        #expect(AIProviderParser.parse("minimax/MiniMax-M2.7") == AIProviderParser.ProviderConfig(
            provider: "minimax",
            model: "MiniMax-M2.7"))
        #expect(AIProviderParser.parse("minimax/MiniMax-M3") == AIProviderParser.ProviderConfig(
            provider: "minimax",
            model: "MiniMax-M3"))
        #expect(AIProviderParser.parse("minimax-cn/MiniMax-M2.7") == AIProviderParser.ProviderConfig(
            provider: "minimax-cn",
            model: "MiniMax-M2.7"))
    }

    @Test
    func `Parse with whitespace`() {
        #expect(AIProviderParser.parse("  openai/gpt-5.5  ") == AIProviderParser.ProviderConfig(
            provider: "openai",
            model: "gpt-5.5"))
        #expect(AIProviderParser.parse("\tanthropic/claude-opus-4-7\n") == AIProviderParser.ProviderConfig(
            provider: "anthropic",
            model: "claude-opus-4-7"))
    }

    @Test
    func `Parse invalid formats`() {
        #expect(AIProviderParser.parse("openai") == nil)
        #expect(AIProviderParser.parse("/gpt-4") == nil)
        #expect(AIProviderParser.parse("openai/") == nil)
        #expect(AIProviderParser.parse("") == nil)
        #expect(AIProviderParser.parse("no-slash-here") == nil)
        #expect(AIProviderParser.parse("openai/gpt-4") == nil)
        #expect(AIProviderParser.parse("anthropic/claude-3") == nil)
    }

    @Test
    func `Parse provider list`() {
        let providers = AIProviderParser.parseList("openai/gpt-5.5,anthropic/claude-opus-4-7,ollama/llava:latest")
        #expect(providers.count == 3)
        #expect(providers[0] == AIProviderParser.ProviderConfig(provider: "openai", model: "gpt-5.5"))
        #expect(providers[1] == AIProviderParser.ProviderConfig(provider: "anthropic", model: "claude-opus-4-7"))
        #expect(providers[2] == AIProviderParser.ProviderConfig(provider: "ollama", model: "llava:latest"))
    }

    @Test
    func `Parse list with invalid entries`() {
        let providers = AIProviderParser.parseList(
            "openai/gpt-4,invalid,anthropic/claude-3,/bad,ollama/,openai/gpt-5.5")
        #expect(providers.count == 1)
        #expect(providers[0] == AIProviderParser.ProviderConfig(provider: "openai", model: "gpt-5.5"))
    }

    @Test
    func `Parse first provider`() {
        #expect(AIProviderParser.parseFirst("openai/gpt-5.5,anthropic/claude-opus-4-7")?.provider == "openai")
        #expect(AIProviderParser.parseFirst("invalid,anthropic/claude-opus-4-7")?.provider == "anthropic")
        #expect(AIProviderParser.parseFirst("invalid,bad,") == nil)
    }

    @Test
    func `Determine default model with all providers`() {
        // When all providers are available, should use first one
        let model = AIProviderParser.determineDefaultModel(
            from: "ollama/llava:latest,openai/gpt-5.5,anthropic/claude-opus-4-7",
            hasOpenAI: true,
            hasAnthropic: true,
            hasOllama: false)
        #expect(model == "gpt-5.5")
    }

    @Test
    func `Determine default model with limited providers`() {
        // When only some providers are available
        let model1 = AIProviderParser.determineDefaultModel(
            from: "openai/gpt-5.5,ollama/llava:latest,anthropic/claude-opus-4-7",
            hasOpenAI: false,
            hasAnthropic: true,
            hasOllama: false)
        #expect(model1 == "claude-opus-4-8")

        let model2 = AIProviderParser.determineDefaultModel(
            from: "openai/gpt-5.5,anthropic/claude-sonnet-4.5,ollama/llava:latest",
            hasOpenAI: false,
            hasAnthropic: true,
            hasOllama: false)
        #expect(model2 == "claude-opus-4-8")

        let model3 = AIProviderParser.determineDefaultModel(
            from: "openai/gpt-5.5,minimax/MiniMax-M2.7",
            hasOpenAI: false,
            hasMiniMax: true,
            hasOllama: false)
        #expect(model3 == "MiniMax-M2.7")

        let model4 = AIProviderParser.determineDefaultModel(
            from: "openai/gpt-5.5,minimax-cn/MiniMax-M2.7",
            hasOpenAI: false,
            hasMiniMaxChina: true,
            hasOllama: false)
        #expect(model4 == "minimax-cn/MiniMax-M2.7")
    }

    @Test
    func `Determine default model keeps MiniMax China availability separate`() {
        let model1 = AIProviderParser.determineDefaultModel(
            from: "minimax-cn/MiniMax-M2.7",
            hasMiniMax: false,
            hasMiniMaxChina: true)
        #expect(model1 == "minimax-cn/MiniMax-M2.7")

        let model2 = AIProviderParser.determineDefaultModel(
            from: "minimax-cn/MiniMax-M2.7",
            hasMiniMax: true,
            hasMiniMaxChina: false)
        #expect(model2 == "MiniMax-M2.7")
    }

    @Test
    func `Determine default model with configured default`() {
        let model = AIProviderParser.determineDefaultModel(
            from: "openai/gpt-5.5,anthropic/claude-opus-4-7",
            hasOpenAI: true,
            hasAnthropic: true,
            configuredDefault: "my-custom-model")
        #expect(model == "my-custom-model")
    }

    @Test
    func `Determine default model fallback`() {
        // When no providers match, fall back to defaults
        let model1 = AIProviderParser.determineDefaultModel(
            from: "invalid/model",
            hasOpenAI: false,
            hasAnthropic: true)
        #expect(model1 == "claude-opus-4-8")

        let model2 = AIProviderParser.determineDefaultModel(
            from: "",
            hasOpenAI: true,
            hasAnthropic: false)
        #expect(model2 == "gpt-5.5")

        let model3 = AIProviderParser.determineDefaultModel(
            from: "",
            hasOpenAI: false,
            hasAnthropic: false)
        #expect(model3 == "gpt-5.5")

        let model4 = AIProviderParser.determineDefaultModel(
            from: "",
            hasOpenAI: false,
            hasAnthropic: false,
            hasGemini: true)
        #expect(model4 == "gemini-3.5-flash")
    }

    @Test
    func `Extract provider and model`() {
        #expect(AIProviderParser.extractProvider(from: "openai/gpt-5.5") == "openai")
        #expect(AIProviderParser.extractModel(from: "openai/gpt-5.5") == "gpt-5.5")
        #expect(AIProviderParser.extractProvider(from: "invalid") == nil)
        #expect(AIProviderParser.extractModel(from: "invalid") == nil)
    }
}
