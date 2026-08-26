import Foundation

extension SnapshotManager {
    public func beginSnapshotMutation(snapshotId: String) async throws -> SnapshotMutationLease {
        guard let snapshotPath = try self.ownedSnapshotURL(for: snapshotId) else {
            throw SnapshotError.snapshotNotFound
        }
        return try await self.snapshotActor.beginMutation(
            snapshotId: snapshotId,
            at: snapshotPath)
    }

    public func finishSnapshotMutation(
        _ lease: SnapshotMutationLease,
        requiresFreshObservation: Bool) async throws
    {
        guard let snapshotPath = try self.ownedSnapshotURL(for: lease.snapshotId) else {
            throw SnapshotError.snapshotNotFound
        }
        try await self.snapshotActor.finishMutation(
            lease,
            requiresFreshObservation: requiresFreshObservation,
            at: snapshotPath)
    }
}
