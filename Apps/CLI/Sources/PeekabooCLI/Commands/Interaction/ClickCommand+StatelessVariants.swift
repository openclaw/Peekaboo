import Commander
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation

extension ClickCommand {
    var requestedClickType: ClickType {
        if self.longPress {
            .longPress
        } else if self.middle {
            .middle
        } else if self.triple {
            .triple
        } else if self.right {
            .right
        } else if self.double {
            .double
        } else {
            .single
        }
    }

    func resolveStatelessClickWindowTarget(
        snapshotId: String,
        expectedProcessIdentity: ApplicationProcessIdentity?
    ) async throws -> UIAutomationTarget.ExactWindow {
        guard !snapshotId.isEmpty,
              let detection = try await self.services.snapshots.getDetectionResult(snapshotId: snapshotId),
              detection.metadata.windowContext != nil
        else {
            throw ValidationError(
                "Background middle- and triple-clicks require a fresh exact-window snapshot."
            )
        }
        let receipt: SnapshotTargetReceipt
        do {
            receipt = try SnapshotTargetReceiptPlanner.assemble(
                snapshotID: snapshotId,
                detectionResult: detection
            ).receipt
        } catch {
            throw ValidationError(
                "Background middle- and triple-clicks require a consistent exact-window snapshot."
            )
        }
        guard let exactWindow = try receipt.requireIdentity().exactWindow else {
            throw ValidationError(
                "Background middle- and triple-clicks require a capture-time window identity and bounds."
            )
        }
        if let expectedProcessIdentity,
           exactWindow.identity.processIdentity != expectedProcessIdentity {
            throw ValidationError(
                "Background click snapshot belongs to a different process generation; run see again before clicking."
            )
        }
        return exactWindow
    }
}
