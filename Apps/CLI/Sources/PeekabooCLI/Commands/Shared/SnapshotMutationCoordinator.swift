import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
enum SnapshotMutationCoordinator {
    static func perform<Value>(
        snapshotId: String?,
        snapshots: any SnapshotManagerProtocol,
        operation: () async throws -> Value,
        outcome: (Value) -> DesktopActionOutcome?
    ) async throws -> Value {
        guard let snapshotId = snapshotId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !snapshotId.isEmpty
        else {
            return try await operation()
        }

        let lease: SnapshotMutationLease
        do {
            lease = try await snapshots.beginSnapshotMutation(snapshotId: snapshotId)
        } catch let error as PeekabooError {
            guard case .snapshotStale = error else { throw error }
            throw PreDispatchActionError(
                message: error.localizedDescription,
                code: .SNAPSHOT_STALE,
                hint: "Run 'peekaboo see' again and use the new snapshot ID.",
                reason: .targetUnavailable
            )
        }

        do {
            let value = try await operation()
            try await snapshots.finishSnapshotMutation(
                lease,
                requiresFreshObservation: outcome(value)?.projection.requiresFreshObservation ?? true
            )
            return value
        } catch let failure as DesktopActionFailure {
            // A typed failure says whether dispatch occurred. If lease finalization itself fails, the
            // still-present pending receipt remains the safer state and the original action failure
            // remains the most useful user-facing result.
            try? await snapshots.finishSnapshotMutation(
                lease,
                requiresFreshObservation: failure.outcome.projection.requiresFreshObservation
            )
            throw failure
        } catch {
            // Completion without a canonical outcome is unknown. Keep the pending lease so a retry
            // cannot replay a mutation that may already have reached the application.
            throw error
        }
    }
}
