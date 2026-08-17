import AppKit

struct PointerEventLogContract: Equatable {
    enum Button: String {
        case left
        case right
        case middle
    }

    enum Phase: String {
        case down
        case up
    }

    static let eventMask: NSEvent.EventTypeMask = [
        .leftMouseDown,
        .leftMouseUp,
        .rightMouseDown,
        .rightMouseUp,
        .otherMouseDown,
        .otherMouseUp,
    ]

    let button: Button
    let phase: Phase

    static func resolve(eventType: NSEvent.EventType, buttonNumber: Int) -> Self? {
        switch (eventType, buttonNumber) {
        case (.leftMouseDown, 0): .init(button: .left, phase: .down)
        case (.leftMouseUp, 0): .init(button: .left, phase: .up)
        case (.rightMouseDown, 1): .init(button: .right, phase: .down)
        case (.rightMouseUp, 1): .init(button: .right, phase: .up)
        case (.otherMouseDown, 2): .init(button: .middle, phase: .down)
        case (.otherMouseUp, 2): .init(button: .middle, phase: .up)
        default: nil
        }
    }
}

struct PointerEventLogRecord: Equatable {
    let sequence: UInt64
    let button: PointerEventLogContract.Button
    let phase: PointerEventLogContract.Phase
    let windowID: Int

    var message: String {
        "{\"sequence\":\(self.sequence),\"button\":\"\(self.button.rawValue)\"," +
            "\"phase\":\"\(self.phase.rawValue)\",\"window_id\":\(self.windowID)}"
    }
}

final class PointerEventLogSequencer {
    private var nextSequence: UInt64?

    init(firstSequence: UInt64 = 1) {
        precondition(firstSequence > 0)
        self.nextSequence = firstSequence
    }

    func next(contract: PointerEventLogContract, windowID: Int) -> PointerEventLogRecord? {
        guard let sequence = self.nextSequence, windowID > 0 else { return nil }
        self.nextSequence = sequence == UInt64.max ? nil : sequence + 1
        return PointerEventLogRecord(
            sequence: sequence,
            button: contract.button,
            phase: contract.phase,
            windowID: windowID)
    }
}
