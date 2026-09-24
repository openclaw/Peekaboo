import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
enum SnapshotMutationCoordinator {
    static func perform<Value>(
        snapshotId: String?,
        snapshots: any SnapshotManagerProtocol,
        targetIdentity: DesktopTargetIdentity? = nil,
        operation: () async throws -> Value,
        outcome: (Value) -> DesktopActionOutcome?
    ) async throws -> Value {
        do {
            return try await snapshots.withSnapshotMutation(
                snapshotId: snapshotId,
                targetIdentity: targetIdentity,
                operation: operation,
                outcome: outcome
            )
        } catch let failure as DesktopActionFailure {
            guard failure.standardErrorCode == .snapshotStale,
                  !failure.outcome.dispatchState.mutationDispatched
            else { throw failure }
            throw PreDispatchActionError(
                message: failure.message,
                code: .SNAPSHOT_STALE,
                hint: failure.hint,
                reason: .targetUnavailable
            )
        }
    }
}
