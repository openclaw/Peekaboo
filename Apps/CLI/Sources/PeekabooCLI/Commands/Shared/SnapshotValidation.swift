import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
enum SnapshotValidation {
    static func requireDetectionResult(
        snapshotId: String,
        snapshots: any SnapshotManagerProtocol
    ) async throws -> ElementDetectionResult {
        guard let result = try await snapshots.getDetectionResult(snapshotId: snapshotId) else {
            throw PeekabooError.snapshotNotFound(
                """
                Snapshot '\(snapshotId)' was not found (or has no UI map). \
                Run 'peekaboo see' again, omit --snapshot, or pass --snapshot latest.
                """
            )
        }
        return result
    }
}
