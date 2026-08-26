import Foundation
import PeekabooFoundation

/// Actor for thread-safe snapshot storage operations.
actor SnapshotStorageActor {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        self.encoder = JSONCoding.makeEncoder()
        self.decoder = JSONCoding.makeDecoder()
    }

    func saveSnapshot(snapshotId: String, data: UIAutomationSnapshot, at snapshotPath: URL) throws {
        guard let snapshotFile = SnapshotPathValidator.producerOwnedSnapshotPayloadURL(
            for: snapshotId,
            in: snapshotPath.deletingLastPathComponent(),
            allowMissing: true)
        else {
            throw SnapshotError.snapshotNotFound
        }

        let jsonData = try self.encoder.encode(data)
        try jsonData.write(to: snapshotFile, options: .atomic)
    }

    func loadSnapshot(snapshotId: String, from snapshotPath: URL) -> UIAutomationSnapshot? {
        guard let snapshotFile = SnapshotPathValidator.producerOwnedSnapshotPayloadURL(
            for: snapshotId,
            in: snapshotPath.deletingLastPathComponent(),
            allowMissing: false)
        else {
            return nil
        }

        do {
            let data = try Data(contentsOf: snapshotFile)
            let snapshotData = try self.decoder.decode(UIAutomationSnapshot.self, from: data)

            if snapshotData.version != UIAutomationSnapshot.currentVersion {
                try? FileManager.default.removeItem(at: snapshotFile)
                return nil
            }

            return snapshotData
        } catch {
            _ = error.asPeekabooError(context: "Failed to load snapshot \(snapshotId)")
            try? FileManager.default.removeItem(at: snapshotFile)
            return nil
        }
    }
}
