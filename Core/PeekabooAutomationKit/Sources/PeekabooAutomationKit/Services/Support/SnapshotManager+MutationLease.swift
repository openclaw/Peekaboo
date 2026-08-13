import Foundation

extension SnapshotManager {
    public func beginSnapshotMutation(snapshotId: String) async throws -> SnapshotMutationLease {
        guard let snapshotPath = SnapshotPathValidator.directChildURL(
            for: snapshotId,
            in: self.getSnapshotStorageURL())
        else {
            throw SnapshotError.storageError("Invalid snapshot ID")
        }
        return try await self.snapshotActor.beginMutation(
            snapshotId: snapshotId,
            at: snapshotPath)
    }

    public func finishSnapshotMutation(
        _ lease: SnapshotMutationLease,
        requiresFreshObservation: Bool) async throws
    {
        guard let snapshotPath = SnapshotPathValidator.directChildURL(
            for: lease.snapshotId,
            in: self.getSnapshotStorageURL())
        else {
            throw SnapshotError.storageError("Invalid snapshot ID")
        }
        try await self.snapshotActor.finishMutation(
            lease,
            requiresFreshObservation: requiresFreshObservation,
            at: snapshotPath)
    }
}
