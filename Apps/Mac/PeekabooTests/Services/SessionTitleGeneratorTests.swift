import Tachikoma
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
@MainActor
struct SessionTitleGeneratorTests {
    @Test
    func `Explicit Fable title provider selects Fable`() {
        let model = SessionTitleGenerator.selectModel(
            providers: ["openai/gpt-5.5", "anthropic/claude-fable-5"],
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

        #expect(model == .anthropic(.opus48))
    }
}
