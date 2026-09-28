import AppKit
import Testing
@testable import Playground

@MainActor
struct KeyboardEventLogContextTests {
    @Test(arguments: [NSEvent.EventType.keyDown, .keyUp, .flagsChanged])
    func `native event projection keeps flags on every event type without posting`(_ type: NSEvent.EventType) throws {
        let event = try #require(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 12,
            windowNumber: 41,
            context: nil,
            characters: "unlogged fixture characters",
            charactersIgnoringModifiers: "unlogged fixture characters",
            isARepeat: false,
            keyCode: 0))
        let context = KeyboardEventLogContext(event: event, application: NSApplication.shared)

        #expect(context.modifierFlags == NSEvent.ModifierFlags([.command, .shift]).rawValue)
        #expect(context.eventWindowID == 41)
        #expect(!context.message.contains("unlogged"))
        #expect(event.modifierFlags == [.command, .shift])
    }

    @Test(arguments: [NSEvent.ModifierFlags.command, .shift, [.command, .shift], []])
    func `metadata preserves received modifier flags and distinguishes both windows`(_ flags: NSEvent.ModifierFlags) {
        let context = KeyboardEventLogContext(
            modifierFlags: flags.rawValue,
            eventWindowID: 41,
            keyWindowID: 42,
            applicationIsActive: false,
            selection: NSRange(location: 2, length: 4))

        #expect(context.message == "modifiers: \(flags.rawValue), eventWindow: 41, " +
            "keyWindow: 42, active: false, keySelection: 2/4")
    }

    @Test
    func `missing receiver evidence stays unavailable rather than implying an empty selection`() {
        let context = KeyboardEventLogContext(
            modifierFlags: 0,
            eventWindowID: 0,
            keyWindowID: nil,
            applicationIsActive: true,
            selection: nil)

        #expect(context.message == "modifiers: 0, eventWindow: 0, " +
            "keyWindow: unavailable, active: true, keySelection: unavailable")
        #expect(KeyboardEventLogContext.selection(of: nil) == nil)
        #expect(KeyboardEventLogContext.selection(of: NSResponder()) == nil)
    }

    @Test
    func `selection reads UTF16 offsets without including the editable value`() {
        let editor = NSTextView(frame: .zero)
        editor.string = "A😀B"
        editor.setSelectedRange(NSRange(location: 1, length: 2))
        let selection = KeyboardEventLogContext.selection(of: editor)
        #expect(selection == NSRange(location: 1, length: 2))

        let context = KeyboardEventLogContext(
            modifierFlags: NSEvent.ModifierFlags.command.rawValue,
            eventWindowID: 41,
            keyWindowID: 41,
            applicationIsActive: false,
            selection: selection)
        #expect(!context.message.contains(editor.string))
        #expect(editor.selectedRange() == NSRange(location: 1, length: 2))
        #expect(editor.string == "A😀B")
    }

    @Test
    func `secure field editor selection is unavailable`() {
        let field = SecureFieldEditorDelegate(frame: .zero)
        let editor = NSTextView(frame: .zero)
        editor.delegate = field
        editor.string = "synthetic"
        editor.setSelectedRange(NSRange(location: 0, length: 9))

        #expect(KeyboardEventLogContext.selection(of: editor) == nil)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 9))
    }
}

private final class SecureFieldEditorDelegate: NSSecureTextField, NSTextViewDelegate {}
