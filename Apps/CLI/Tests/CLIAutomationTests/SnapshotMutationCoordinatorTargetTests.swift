import CoreGraphics
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
@Suite(.serialized, .tags(.safe))
struct SnapshotMutationCoordinatorTargetTests {
    @Test(arguments: [false, true])
    func `typed stale refusal retains canonical evidence through coordination and CLI rendering`(
        usesSnapshot: Bool
    ) async throws {
        let snapshots = StubSnapshotManager()
        let snapshotID = usesSnapshot ? try await snapshots.createSnapshot() : nil
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
        let expected = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "The captured wheel target is stale.",
            hint: "Observe an in-window target before retrying.",
            causeDescription: "The selected Bridge host rejected the captured point.",
            standardErrorCode: .snapshotStale
        ).attributed(to: targetIdentity.actionTargetReceipt)

        let caught = await #expect(throws: DesktopActionFailure.self) {
            _ = try await SnapshotMutationCoordinator.perform(
                snapshotId: snapshotID,
                snapshots: snapshots,
                targetIdentity: targetIdentity,
                operation: { () async throws -> String in throw expected },
                outcome: { _ in nil }
            )
        }
        let failure = try #require(caught)
        #expect(failure == expected)

        let rendered = try await InProcessCommandRunner.captureCommandOutput { @MainActor in
            defer { Logger.shared.setJsonOutputMode(false) }
            renderDesktopActionFailure(failure, jsonOutput: true, logger: .shared)
        }
        let response = try ExternalCommandRunner.decodeJSONResponse(from: rendered, as: JSONResponse.self)
        #expect(response.success == false)
        #expect(response.error?.code == ErrorCode.SNAPSHOT_STALE.rawValue)
        #expect(response.error?.message == expected.message)
        #expect(response.error?.hint == expected.hint)
        #expect(response.error?.details == expected.causeDescription)
        #expect(response.outcome == expected.outcome.projection)
        #expect(response.target_receipt == expected.targetReceipt)
    }

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
