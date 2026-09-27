import Testing
@testable import PeekabooAutomationKit

struct HotkeySelectionPolicyTests {
    @Test(arguments: ["cmd,a", "command+A", " META a ", "win,a", "windows,a", "cmdOrCtrl,a", "cmd,cmd,a"])
    func `selection policy uses the canonical hotkey parser`(_ keys: String) {
        #expect(HotkeyService.isSelectAllShortcut(keys))
    }

    @Test(arguments: [
        "cmd,b",
        "ctrl,a",
        "cmd,shift,a",
        "cmd,alt,a",
        "cmd,fn,a",
        "cmd+ctrl,a",
        "a",
        "cmd",
        "cmd,a,b",
        ""
    ])
    func `selection policy refuses other modifiers keys and malformed chords`(_ keys: String) {
        #expect(!HotkeyService.isSelectAllShortcut(keys))
    }
}
