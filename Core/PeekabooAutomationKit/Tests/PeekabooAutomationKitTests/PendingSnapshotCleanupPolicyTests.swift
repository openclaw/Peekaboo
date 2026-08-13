import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct PendingSnapshotCleanupPolicyTests {
    @Test
    func `transport timeout and disconnect preserve pending reservations`() {
        #expect(PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: POSIXError(.ETIMEDOUT)))
        #expect(PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: POSIXError(.ECONNRESET)))
        #expect(PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: POSIXError(.EPIPE)))
    }

    @Test
    func `definite failures can clean pending reservations`() {
        #expect(!PendingSnapshotCleanupPolicy.shouldPreserveReservation(
            after: PeekabooError.permissionDeniedAccessibility))
        #expect(!PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: POSIXError(.ENOENT)))
    }

    @Test
    func `wrapped timeout preserves pending reservation`() {
        let error = CaptureError.captureCreationFailed(POSIXError(.ETIMEDOUT))
        #expect(PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: error))
    }

    @Test
    func `canonical action failure owns pending reservation disposition`() {
        let dispatched = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            evidence: .completionUnknown,
            message: "Completion is unknown")
        let refused = DesktopActionFailure.refused(
            reason: .targetUnavailable,
            message: "Target is unavailable")

        #expect(Self.pendingReservationDisposition(for: dispatched))
        #expect(!Self.pendingReservationDisposition(for: refused))
        #expect(PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: dispatched))
        #expect(!PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: refused))
    }

    private static func pendingReservationDisposition(
        for failure: some PendingSnapshotFailureDispositionProviding) -> Bool
    {
        failure.mayCompleteSnapshotWorkAfterFailure
    }
}
