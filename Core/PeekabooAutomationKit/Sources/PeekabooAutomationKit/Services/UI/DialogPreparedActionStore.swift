import AXorcist
import Foundation
import PeekabooFoundation

/// Bounded, one-shot storage for the raw AX identities that cannot safely cross the Bridge wire.
@MainActor
final class DialogPreparedActionStore {
    struct Entry {
        let receipt: PreparedDialogActionReceipt
        let request: DialogActionPreparationRequest
        let window: Element
        let dialog: Element
        let button: Element
        let resolvedButtonTitle: String
        let resolvedButtonIdentifier: String?
        let createdAt: Date
    }

    private let capacity: Int
    private let timeToLive: TimeInterval
    private let now: () -> Date
    private var entries: [UUID: Entry] = [:]

    init(
        capacity: Int = 64,
        timeToLive: TimeInterval = 5,
        now: @escaping () -> Date = Date.init)
    {
        precondition(capacity > 0)
        precondition(timeToLive > 0)
        self.capacity = capacity
        self.timeToLive = timeToLive
        self.now = now
    }

    func insert(_ entry: Entry) {
        self.pruneExpired()
        while self.entries.count >= self.capacity,
              let oldest = self.entries.min(by: { $0.value.createdAt < $1.value.createdAt })?.key
        {
            self.entries.removeValue(forKey: oldest)
        }
        self.entries[entry.receipt.token] = entry
    }

    func consume(_ receipt: PreparedDialogActionReceipt) throws -> Entry {
        self.pruneExpired()
        guard let entry = self.entries.removeValue(forKey: receipt.token) else {
            throw Self.refusal(
                "Prepared dialog receipt is missing, expired, or already consumed.",
                hint: "List the dialog again and prepare a fresh action before retrying.")
        }
        guard entry.receipt == receipt else {
            throw Self.refusal(
                "Prepared dialog receipt fields do not match the host-retained action.",
                hint: "Discard the receipt and prepare the dialog action again.")
        }
        return entry
    }

    private func pruneExpired() {
        let cutoff = self.now().addingTimeInterval(-self.timeToLive)
        self.entries = self.entries.filter { $0.value.createdAt >= cutoff }
    }

    private static func refusal(_ message: String, hint: String) -> DesktopActionFailure {
        .preDispatchRefusal(
            reason: .targetUnavailable,
            message: message,
            hint: hint)
    }
}
