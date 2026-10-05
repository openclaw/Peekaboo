import Testing
@testable import PeekabooAgentRuntime

struct KeyboardShortcutFormattingTests {
    @Test(arguments: ["forwarddelete", "forward_delete", "ForwardDelete", "FORWARD_DELETE"])
    func `forward delete cannot be presented as backward delete`(_ key: String) {
        #expect(FormattingUtilities.formatKeyboardShortcut("CMD+\(key)") == "⌘⌦")
        #expect(UIAutomationToolFormatter(toolType: .press).formatResultSummary(result: ["key": key]) ==
            "→ Pressed ⌦ Forward Delete")
    }

    @Test(arguments: ["delete", "backspace", "del", "Delete", "DEL"])
    func `backward delete aliases retain their distinction`(_ key: String) {
        #expect(FormattingUtilities.formatKeyboardShortcut("control,option,\(key)") == "⌃⌥⌫")
        #expect(UIAutomationToolFormatter(toolType: .press).formatResultSummary(result: ["key": key]) ==
            "→ Pressed ⌫ Delete")
    }

    @Test
    func `public hotkey formatter displays the correct delete direction`() {
        let formatter = UIAutomationToolFormatter(toolType: .hotkey)
        let summary = formatter.formatResultSummary(result: ["keys": "Command,forwarddelete"])
        #expect(summary == "→ Pressed ⌘⌦")
        let menu = MenuSystemToolFormatter(toolType: .menuClick)
        #expect(menu.formatResultSummary(result: [
            "menuPath": ["Edit", "Delete Forward"], "shortcut": "command+forward_delete",
        ]).contains("shortcut: ⌘⌦"))
    }

    @Test
    func `only complete key names become symbols`() {
        #expect(FormattingUtilities.formatKeyboardShortcut("cmd+shift+t") == "⌘⇧t")
        #expect(FormattingUtilities.formatKeyboardShortcut("command + Shift + Return") == "⌘⇧↩")
        #expect(FormattingUtilities.formatKeyboardShortcut("enterprise") == "enterprise")
        #expect(FormattingUtilities.formatKeyboardShortcut("cmd+enterprise+mydelete") == "⌘enterprisemydelete")
        #expect(FormattingUtilities.formatKeyboardShortcut("  cmd\tshift\nT  ") == "⌘⇧T")
        #expect(FormattingUtilities.formatKeyboardShortcut("⌘+⇧+T") == "⌘⇧T")
        #expect(FormattingUtilities.formatKeyboardShortcut("").isEmpty)
        #expect(UIAutomationToolFormatter(toolType: .press).formatResultSummary(result: ["key": "owned-key"]) ==
            "→ Pressed owned-key")
    }
}
