import AppKit
import Testing
@testable import Playground

@MainActor
struct ActionLoggerTests {
    @Test
    func `pointer event log contract has an exact six-event mask and closed mapping`() {
        let expectedMask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
        ]
        #expect(PointerEventLogContract.eventMask.rawValue == expectedMask.rawValue)

        let cases: [(NSEvent.EventType, Int, PointerEventLogContract.Button, PointerEventLogContract.Phase)] = [
            (.leftMouseDown, 0, .left, .down),
            (.leftMouseUp, 0, .left, .up),
            (.rightMouseDown, 1, .right, .down),
            (.rightMouseUp, 1, .right, .up),
            (.otherMouseDown, 2, .middle, .down),
            (.otherMouseUp, 2, .middle, .up),
        ]
        for (eventType, buttonNumber, button, phase) in cases {
            let contract = PointerEventLogContract.resolve(
                eventType: eventType,
                buttonNumber: buttonNumber)
            #expect(contract == .init(button: button, phase: phase))
        }

        #expect(PointerEventLogContract.resolve(eventType: .mouseMoved, buttonNumber: 0) == nil)
        #expect(PointerEventLogContract.resolve(eventType: .otherMouseDown, buttonNumber: 3) == nil)
        #expect(PointerEventLogContract.resolve(eventType: .leftMouseDown, buttonNumber: 1) == nil)
    }

    @Test
    func `pointer records form consecutive closed down-up pairs for one exact window`() throws {
        let cases: [(NSEvent.EventType, NSEvent.EventType, Int, PointerEventLogContract.Button)] = [
            (.leftMouseDown, .leftMouseUp, 0, .left),
            (.rightMouseDown, .rightMouseUp, 1, .right),
            (.otherMouseDown, .otherMouseUp, 2, .middle),
        ]
        for (downType, upType, buttonNumber, button) in cases {
            let sequencer = PointerEventLogSequencer(firstSequence: 41)
            let down = try #require(PointerEventLogContract.resolve(
                eventType: downType,
                buttonNumber: buttonNumber))
            let up = try #require(PointerEventLogContract.resolve(
                eventType: upType,
                buttonNumber: buttonNumber))

            let downRecord = try #require(sequencer.next(contract: down, windowID: 1234))
            let upRecord = try #require(sequencer.next(contract: up, windowID: 1234))

            #expect(downRecord == .init(sequence: 41, button: button, phase: .down, windowID: 1234))
            #expect(upRecord == .init(sequence: 42, button: button, phase: .up, windowID: 1234))
            #expect(
                downRecord.message ==
                    "{\"sequence\":41,\"button\":\"\(button.rawValue)\",\"phase\":\"down\",\"window_id\":1234}")
            #expect(
                upRecord.message ==
                    "{\"sequence\":42,\"button\":\"\(button.rawValue)\",\"phase\":\"up\",\"window_id\":1234}")
            #expect(sequencer.next(contract: down, windowID: 0) == nil)
        }
    }

    @Test
    func `log records entries and updates derived state`() {
        let logger = ActionLogger.shared
        logger.clearLogs()

        logger.log(.click, "Clicked button", details: "Primary CTA")

        #expect(logger.entries.count == 1)
        #expect(logger.actionCount == 1)
        #expect(logger.lastAction == "Clicked button")
        #expect(logger.entries.first?.details == "Primary CTA")
        #expect(logger.entries.first?.category == .click)
        #expect(logger.categoryCounts[.click] == 1)
    }

    @Test
    func `clearLogs resets counters and appends status message`() {
        let logger = ActionLogger.shared
        logger.clearLogs()
        logger.log(.text, "Typed name")

        logger.clearLogs()

        #expect(logger.entries.isEmpty)
        #expect(logger.actionCount == 0)
        #expect(logger.lastAction == "Logs cleared")
        #expect(logger.categoryCounts.values.allSatisfy { $0 == 0 })
    }

    @Test
    func `exportLogs emits human readable lines`() {
        let logger = ActionLogger.shared
        logger.clearLogs()

        logger.log(.menu, "Opened File menu")
        logger.log(.control, "Toggled switch", details: "Dark Mode")

        let exported = logger.exportLogs()

        #expect(exported.contains("Peekaboo Playground Action Log"))
        #expect(exported.contains("Opened File menu"))
        #expect(exported.contains("Toggled switch"))
    }

    @Test
    func `log enforces bounded history`() {
        let logger = ActionLogger.shared
        logger.clearLogs()

        for index in 0...ActionLogger.entryLimit {
            logger.log(.click, "Event \(index)")
        }

        #expect(logger.entries.count == ActionLogger.entryLimit)
        #expect(logger.categoryCounts[.click] == ActionLogger.entryLimit)
        #expect(logger.actionCount == ActionLogger.entryLimit + 1)
        #expect(logger.entries.first?.message == "Event 1")
    }
}
