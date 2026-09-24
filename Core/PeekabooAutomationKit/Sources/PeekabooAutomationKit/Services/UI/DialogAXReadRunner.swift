import ApplicationServices
import Foundation
import PeekabooFoundation

enum DialogAXReadRunner {
    static func run<Output: Sendable>(
        owner: ApplicationProcessIdentity,
        budget: DialogOperationDeadline,
        operation: @escaping @Sendable () throws -> Output) async throws -> Output
    {
        try budget.check()
        // Only C reads run here: no AXorcist caches, messaging-timeout changes, service state,
        // or mutation callbacks can outlive the caller.
        do {
            let result = try await ElementDetectionTimeoutRunner.runDetached(
                targetProcessIdentifier: owner.processIdentifier,
                targetProcessStartIdentity: owner.processStartIdentity,
                seconds: budget.remainingSeconds,
                maximumPendingOperationCount: 1)
            {
                try budget.check()
                return try operation()
            }
            try budget.check()
            return result
        } catch CaptureError.detectionTimedOut {
            throw budget.timeoutError
        }
    }
}

/// Immutable AX identities may outlive cancellation only on the read-only worker; no setters or
/// messaging-timeout changes are allowed. AXorcist wrappers remain on MainActor.
struct DialogAXReadIdentity: @unchecked Sendable, Hashable {
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(self.element))
    }
}
