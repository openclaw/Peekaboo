import Testing
@testable import PeekabooAgentRuntime

struct KeyboardShortcutFormattingTests {
    @Test(arguments: ["forwarddelete", "forward_delete", "ForwardDelete"])
    func `forward delete cannot be presented as backward delete`(_ key: String) {
        #expect(FormattingUtilities.formatKeyboardShortcut("CMD+\(key)") == "⌘⌦")
    }

    @Test(arguments: ["delete", "backspace", "del", "Delete"])
    func `backward delete aliases retain their distinction`(_ key: String) {
        #expect(FormattingUtilities.formatKeyboardShortcut("control,option,\(key)") == "⌃⌥⌫")
    }

    @Test
    func `public hotkey formatter displays the correct delete direction`() {
        let formatter = UIAutomationToolFormatter(toolType: .hotkey)
        let summary = formatter.formatResultSummary(result: ["keys": "Command,forwarddelete"])
        #expect(summary == "→ Pressed ⌘⌦")
        print("public hotkey summary: \(summary)")
    }

    @Test
    func `only complete key names become symbols`() {
        #expect(FormattingUtilities.formatKeyboardShortcut("cmd+shift+t") == "⌘⇧t")
        #expect(FormattingUtilities.formatKeyboardShortcut("command + Shift + Return") == "⌘⇧↩")
        #expect(FormattingUtilities.formatKeyboardShortcut("enterprise") == "enterprise")
    }
}
