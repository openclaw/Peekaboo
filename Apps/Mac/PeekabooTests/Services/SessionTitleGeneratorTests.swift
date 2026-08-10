import Tachikoma
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
@MainActor
struct SessionTitleGeneratorTests {
    @Test
    func `Explicit Fable title provider selects Fable`() {
        let model = SessionTitleGenerator.selectModel(
            providers: ["openai/gpt-5.6", "anthropic/claude-fable-5"],
            hasOpenAI: false,
            hasAnthropic: true)

        #expect(model == .anthropic(.fable5))
    }

    @Test
    func `Bare Anthropic title provider keeps Opus default`() {
        let model = SessionTitleGenerator.selectModel(
            providers: ["anthropic"],
            hasOpenAI: false,
            hasAnthropic: true)

        #expect(model == .anthropic(.opus5))
    }

    @Test
    func `Auth-only Anthropic title generation keeps compatibility fallback`() {
        let model = SessionTitleGenerator.selectModel(
            providers: ["openai/gpt-5.6", "anthropic/claude-opus-5"],
            hasOpenAI: false,
            hasAnthropic: true,
            hasProviderSelection: false)

        #expect(model == .anthropic(.opus48))
    }

    @Test
    func `Explicit title provider model pins are preserved`() {
        let anthropic = SessionTitleGenerator.selectModel(
            providers: ["anthropic/claude-opus-4-8"],
            hasOpenAI: false,
            hasAnthropic: true)
        let openAI = SessionTitleGenerator.selectModel(
            providers: ["openai/gpt-5.5"],
            hasOpenAI: true,
            hasAnthropic: false)

        #expect(anthropic == .anthropic(.opus48))
        #expect(openAI == .openai(.gpt55))
    }

    @Test
    func `Configured agent default takes precedence over generated provider choices`() {
        let model = SessionTitleGenerator.selectModel(
            providers: ["openai/gpt-5.6", "anthropic/claude-opus-5"],
            hasOpenAI: false,
            hasAnthropic: true,
            configuredDefault: "claude-opus-4-8")

        #expect(model == .anthropic(.opus48))
    }
}
