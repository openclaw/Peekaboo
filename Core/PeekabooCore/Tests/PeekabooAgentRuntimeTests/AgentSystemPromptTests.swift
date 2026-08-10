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

    @Test
    func `generated prompt forbids claims from withheld or incomplete observation evidence`() {
        guard #available(macOS 14.0, *) else { return }
        let prompt = AgentSystemPrompt.generate()

        #expect(prompt.contains("not delivered, do not describe"))
        #expect(prompt.contains("missing text or elements do not prove absence"))
        #expect(prompt.contains("report that the state is unverified"))
        #expect(prompt.contains("two-phase contract"))
        #expect(prompt.contains("first structurally valid"))
        #expect(prompt.contains("Repeat the exact same target and predicates"))
    }

    @Test
    func `generated prompt requires structured verify state predicates`() {
        guard #available(macOS 14.0, *) else { return }
        let prompt = AgentSystemPrompt.generate()

        #expect(prompt.contains("predicates are structured JSON objects"))
        #expect(prompt.contains("never prose strings or AX expressions"))
        #expect(prompt.contains("predicate schema and examples exactly"))
    }

    @Test
    func `generated prompt limits each response to one desktop mutation`() {
        guard #available(macOS 14.0, *) else { return }
        let prompt = AgentSystemPrompt.generate()

        #expect(prompt.contains("at most one desktop-mutating tool call in each model response"))
        #expect(prompt.contains("skips later mutations until a fresh successful `see`"))
        #expect(prompt.contains("You may batch read-only"))
    }

    @Test
    func `generated prompt keeps launch navigation and observation in background`() {
        guard #available(macOS 14.0, *) else { return }
        let prompt = AgentSystemPrompt.generate()

        #expect(prompt.contains(#""action": "launch", "name": "Safari", "foreground": false"#))
        #expect(prompt.contains(#""action": "open", "name": "Safari""#))
        #expect(prompt.contains("`new_page` and `select_page` stay in the background by default"))
        #expect(prompt.contains("Observation never focuses the target by default"))
        #expect(prompt.contains("Only set `web_focus: true`"))
        #expect(!prompt.contains("capture and focus background apps"))
        #expect(!prompt.contains("`launch_app` tool"))
    }
}
