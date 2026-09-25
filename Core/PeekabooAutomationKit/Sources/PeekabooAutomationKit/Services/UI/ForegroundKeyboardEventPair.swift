import CoreGraphics

@MainActor
struct ForegroundKeyboardEventPair {
    typealias EventFactory = @MainActor (CGEventSource?, CGKeyCode, Bool) -> CGEvent?

    let keyDown: CGEvent
    let keyUp: CGEvent

    init?(
        source: CGEventSource?,
        keyCode: CGKeyCode,
        keyDownFlags: CGEventFlags,
        makeEvent: EventFactory = ForegroundKeyboardEventPair.makeCGEvent)
    {
        guard let keyDown = makeEvent(source, keyCode, true),
              let keyUp = makeEvent(source, keyCode, false)
        else { return nil }

        keyDown.flags = keyDownFlags
        // These pairs have no separate modifier key-ups; the terminal event clears the chord flags.
        keyUp.flags = []
        self.keyDown = keyDown
        self.keyUp = keyUp
    }

    static func makeCGEvent(source: CGEventSource?, keyCode: CGKeyCode, keyDown: Bool) -> CGEvent? {
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
    }
}
