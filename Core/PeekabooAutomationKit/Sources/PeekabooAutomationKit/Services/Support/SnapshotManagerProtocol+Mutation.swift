import Foundation
import PeekabooFoundation

extension SnapshotManagerProtocol {
    @MainActor
    public func withSnapshotMutation<Value>(
        snapshotId: String?,
        targetIdentity: DesktopTargetIdentity? = nil,
        operation: () async throws -> Value,
        outcome: (Value) -> DesktopActionOutcome?,
        fallbackRequiresFreshObservation: (Value) -> Bool = { _ in true }) async throws -> Value
    {
        guard let snapshotId = snapshotId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !snapshotId.isEmpty
        else {
            return try await operation()
        }

        let lease: SnapshotMutationLease
        do {
            lease = try await self.beginSnapshotMutation(snapshotId: snapshotId)
        } catch let error as PeekabooError {
            guard case .snapshotStale = error else { throw error }
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: error.localizedDescription,
                hint: "Run 'peekaboo see' again and use the new snapshot ID.",
                standardErrorCode: .snapshotStale)
                .attributed(to: targetIdentity?.actionTargetReceipt)
        }
        let value: Value
        do {
            value = try await operation()
        } catch let error as SnapshotTargetReceiptPreDispatchError {
            try? await self.finishSnapshotMutation(lease, requiresFreshObservation: false)
            throw error.actionFailure
        } catch let failure as DesktopActionFailure {
            try? await self.finishSnapshotMutation(
                lease,
                requiresFreshObservation: failure.outcome.projection.requiresFreshObservation)
            throw failure
        } catch {
            // Unknown completion leaves the pending lease in place to prevent replay.
            throw error
        }

        let canonicalOutcome = outcome(value)
        do {
            try await self.finishSnapshotMutation(
                lease,
                requiresFreshObservation: canonicalOutcome?.projection.requiresFreshObservation ??
                    fallbackRequiresFreshObservation(value))
        } catch {
            throw DesktopActionFailure.indeterminate(
                route: canonicalOutcome?.route ?? .local,
                delivery: canonicalOutcome?.delivery,
                evidence: .completionUnknown,
                unitCount: canonicalOutcome?.dispatchState.unitCount,
                message: "Action completed, but Peekaboo could not finalize its snapshot mutation lease.",
                hint: "Observe the target before any retry and do not reuse this snapshot.",
                causeDescription: error.localizedDescription)
                .attributed(to: targetIdentity?.actionTargetReceipt)
        }
        return value
    }
}
