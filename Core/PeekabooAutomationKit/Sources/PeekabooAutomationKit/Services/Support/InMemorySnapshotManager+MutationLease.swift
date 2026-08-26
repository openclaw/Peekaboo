import Foundation
import PeekabooFoundation

extension InMemorySnapshotManager {
    public func beginSnapshotMutation(snapshotId: String) async throws -> SnapshotMutationLease {
        _ = try self.requireEntry(for: snapshotId)
        guard self.mutationLeases[snapshotId] == nil else {
            throw PeekabooError.snapshotStale(
                "Snapshot '\(snapshotId)' already drove a mutation whose result requires a fresh observation. " +
                    "Run 'peekaboo see' again before another mutation. " +
                    "Read-only snapshot inspection is still available.")
        }
        let lease = SnapshotMutationLease(snapshotId: snapshotId)
        self.mutationLeases[snapshotId] = .pending(lease)
        return lease
    }

    public func finishSnapshotMutation(
        _ lease: SnapshotMutationLease,
        requiresFreshObservation: Bool) async throws
    {
        try self.validateSnapshotReference(lease.snapshotId)
        guard let state = self.mutationLeases[lease.snapshotId], state.lease == lease else {
            throw SnapshotError.storageError(
                "Mutation lease for snapshot '\(lease.snapshotId)' changed before completion")
        }
        if case .requiresFreshObservation = state {
            return
        }
        if requiresFreshObservation {
            self.mutationLeases[lease.snapshotId] = .requiresFreshObservation(lease)
        } else {
            self.mutationLeases.removeValue(forKey: lease.snapshotId)
        }
    }
}
