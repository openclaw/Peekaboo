import CoreGraphics
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
struct SnapshotMutationCoordinatorTargetTests {
    @Test(arguments: ActionOutcomeCommandTests.LeaseFinalizationFailure.allCases)
    func `lease finalization failure retains exact target attribution`(
        failureFixture: ActionOutcomeCommandTests.LeaseFinalizationFailure
    ) async throws {
        let snapshots = StubSnapshotManager()
        let snapshotID = try await snapshots.createSnapshot()
        snapshots.mutationFinishError = failureFixture.error
        let bounds = CGRect(x: 20, y: 30, width: 400, height: 240)
        let targetIdentity = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 77,
                ownerProcessIdentifier: 701,
                ownerProcessStartIdentity: 7001,
                capturedBounds: bounds
            ),
            bounds: bounds
        ))
        let expectedOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2)
        )

        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await SnapshotMutationCoordinator.perform(
                snapshotId: snapshotID,
                snapshots: snapshots,
                targetIdentity: targetIdentity,
                operation: { "delivered" },
                outcome: { _ in expectedOutcome }
            )
        }

        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.retrySafety == .unsafe)
        #expect(failure?.targetReceipt == targetIdentity.actionTargetReceipt)
    }
}
