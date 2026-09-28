import AppKit

struct KeyboardEventLogContext: Equatable {
    let modifierFlags: UInt
    let eventWindowID: Int
    let keyWindowID: Int?
    let applicationIsActive: Bool
    let selection: NSRange?

    @MainActor
    init(event: NSEvent, application: NSApplication) {
        self.modifierFlags = event.modifierFlags.rawValue
        self.eventWindowID = event.windowNumber
        let keyWindow = application.keyWindow
        self.keyWindowID = keyWindow?.windowNumber
        self.applicationIsActive = application.isActive
        self.selection = Self.selection(of: keyWindow?.firstResponder)
    }

    init(
        modifierFlags: UInt,
        eventWindowID: Int,
        keyWindowID: Int?,
        applicationIsActive: Bool,
        selection: NSRange?)
    {
        self.modifierFlags = modifierFlags
        self.eventWindowID = eventWindowID
        self.keyWindowID = keyWindowID
        self.applicationIsActive = applicationIsActive
        self.selection = selection
    }

    var message: String {
        let keyWindow = self.keyWindowID.map(String.init) ?? "unavailable"
        let selection = self.selection.map { "\($0.location)/\($0.length)" } ?? "unavailable"
        return "modifiers: \(self.modifierFlags), eventWindow: \(self.eventWindowID), " +
            "keyWindow: \(keyWindow), active: \(self.applicationIsActive), keySelection: \(selection)"
    }

    @MainActor
    static func selection(of responder: NSResponder?) -> NSRange? {
        guard let editor = responder as? NSTextView,
              !(editor.delegate is NSSecureTextField)
        else { return nil }
        let range = editor.selectedRange()
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return nil }
        return range
    }
}
