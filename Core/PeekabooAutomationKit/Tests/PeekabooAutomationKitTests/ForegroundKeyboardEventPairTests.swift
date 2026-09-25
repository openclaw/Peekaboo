import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct ForegroundKeyboardEventPairTests {
    @Test(arguments: [false, true])
    func `prepared foreground pair replaces seeded flags and preserves its source`(modified: Bool) throws {
        let source = try #require(CGEventSource(stateID: .hidSystemState))
        let requestedFlags: CGEventFlags = modified ? [.maskCommand, .maskShift] : []
        var createdDownStates: [Bool] = []

        let preparedEvents = ForegroundKeyboardEventPair(
            source: source,
            keyCode: 0x30,
            keyDownFlags: requestedFlags,
            makeEvent: { receivedSource, keyCode, keyDown in
                #expect(receivedSource === source)
                #expect(keyCode == 0x30)
                createdDownStates.append(keyDown)
                return Self.seededEvent(source: receivedSource, keyCode: keyCode, keyDown: keyDown)
            })
        let events = try #require(preparedEvents)

        #expect(createdDownStates == [true, false])
        #expect(events.keyDown.type == .keyDown)
        #expect(events.keyUp.type == .keyUp)
        #expect(events.keyDown.flags == requestedFlags)
        #expect(events.keyUp.flags == [])
    }

    @Test(arguments: [SpecialKey.return, .enter, .tab, .forwardDelete, .capsLock, .clear, .help])
    func `foreground special key posts a complete unmodified pair with its original keycode`(key: SpecialKey) throws {
        let expectedKeyCode: CGKeyCode = switch key {
        case .return: 0x24
        case .enter: 0x4C
        case .tab: 0x30
        case .forwardDelete: 0x75
        case .capsLock: 0x39
        case .clear: 0x47
        default: 0x72
        }
        var steps: [String] = []
        var postedKeyCodes: [Int64] = []
        var postedFlags: [CGEventFlags] = []

        try TypeServiceSpecialKeyMapping.postKey(
            TypeServiceSpecialKeyMapping.keyCode(for: key),
            makeEvent: { source, keyCode, keyDown in
                #expect(source == nil)
                #expect(keyCode == expectedKeyCode)
                steps.append(keyDown ? "create down" : "create up")
                return Self.seededEvent(source: source, keyCode: keyCode, keyDown: keyDown)
            },
            eventPoster: { event in
                steps.append("post")
                postedKeyCodes.append(event.getIntegerValueField(.keyboardEventKeycode))
                postedFlags.append(event.flags)
            },
            interEventDelay: { steps.append("delay") })

        #expect(steps == ["create down", "create up", "post", "delay", "post"])
        #expect(postedKeyCodes == [Int64(expectedKeyCode), Int64(expectedKeyCode)])
        #expect(postedFlags == [[], []])
    }

    @Test(arguments: [1, 2])
    func `foreground special key allocation failure posts nothing`(failedCreation: Int) throws {
        var creationCount = 0
        var postedCount = 0
        var delayCount = 0

        do {
            try TypeServiceSpecialKeyMapping.postKey(
                0x30,
                makeEvent: { source, keyCode, keyDown in
                    creationCount += 1
                    guard creationCount != failedCreation else { return nil }
                    return Self.seededEvent(source: source, keyCode: keyCode, keyDown: keyDown)
                },
                eventPoster: { _ in postedCount += 1 },
                interEventDelay: { delayCount += 1 })
            Issue.record("Expected foreground keyboard event allocation failure")
        } catch let PeekabooError.operationError(message) {
            #expect(message == "Failed to create keyboard event")
        }

        #expect(creationCount == failedCreation)
        #expect(postedCount == 0)
        #expect(delayCount == 0)
    }

    private static func seededEvent(source: CGEventSource?, keyCode: CGKeyCode, keyDown: Bool) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            return nil
        }
        event.flags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        return event
    }
}
