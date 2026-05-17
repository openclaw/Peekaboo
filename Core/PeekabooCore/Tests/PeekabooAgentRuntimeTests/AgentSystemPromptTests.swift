import Testing
@testable import PeekabooAgentRuntime

struct AgentSystemPromptTests {
    /// Forbidden tokens that must not appear in the generated system prompt.
    /// These correspond to tools or arguments that do not exist in the current
    /// agent tool schema, so mentioning them would mislead the model.
    private static let forbiddenTokens = [
        "`calculate`",
        "`wait` tool",
        "`dialog_click`",
        "`dialog_input`",
        "`menu_click`",
        "json_output",
        "`list_windows`",
    ]

    @Test
    func `generated prompt contains no forbidden stale tool references`() {
        guard #available(macOS 14.0, *) else { return }
        let prompt = AgentSystemPrompt.generate()
        for token in Self.forbiddenTokens {
            #expect(
                !prompt.contains(token),
                "Prompt still references stale tool/argument: \(token)")
        }
    }

    @Test
    func `generated prompt references real see parameter app_target`() {
        guard #available(macOS 14.0, *) else { return }
        let prompt = AgentSystemPrompt.generate()
        #expect(
            prompt.contains("app_target"),
            "Prompt should guide agents to use the real `app_target` parameter for `see`.")
    }

    @Test
    func `generated prompt references real dialog tool`() {
        guard #available(macOS 14.0, *) else { return }
        let prompt = AgentSystemPrompt.generate()
        #expect(prompt.contains("`dialog` tool"), "Prompt should reference the real `dialog` tool.")
    }

    @Test
    func `generated prompt references real menu tool`() {
        guard #available(macOS 14.0, *) else { return }
        let prompt = AgentSystemPrompt.generate()
        #expect(prompt.contains("`menu` tool"), "Prompt should reference the real `menu` tool.")
    }

    @Test
    func `generated prompt references real sleep tool`() {
        guard #available(macOS 14.0, *) else { return }
        let prompt = AgentSystemPrompt.generate()
        #expect(prompt.contains("`sleep`"), "Prompt should reference the real `sleep` tool for waits.")
    }

    @Test
    func `generated prompt includes app when listing application windows`() {
        guard #available(macOS 14.0, *) else { return }
        let prompt = AgentSystemPrompt.generate()
        #expect(
            prompt.contains(#""item_type": "application_windows", "app": "Safari""#),
            "Prompt should include the required `app` argument when listing application windows.")
    }

    @Test
    func `generated prompt routes observation by target surface`() {
        guard #available(macOS 14.0, *) else { return }
        let prompt = AgentSystemPrompt.generate()

        #expect(prompt.contains("observation tool appropriate to the target surface"))
        #expect(prompt.contains("Use `browser` for Chrome page content"))
        #expect(prompt.contains("Use `inspect_ui` for native macOS UI text"))
        #expect(prompt.contains("Use `see` for desktop/app screenshots"))
    }

    @Test
    func `generated prompt no longer forces see as the first observation tool`() {
        guard #available(macOS 14.0, *) else { return }
        let prompt = AgentSystemPrompt.generate()

        #expect(!prompt.contains("Screenshots → always use `see`"))
        #expect(!prompt.contains("Start with the `see` tool"))
        #expect(!prompt.contains("First call `see`"))
    }

    @Test
    func `generated prompt preserves see for visual observations`() {
        guard #available(macOS 14.0, *) else { return }
        let prompt = AgentSystemPrompt.generate()

        #expect(prompt.contains("visual layout"))
        #expect(prompt.contains("pixels"))
        #expect(prompt.contains("accessibility text is missing or incomplete"))
    }
}
