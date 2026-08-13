import Foundation
import PeekabooFoundation

private struct StoredSnapshotMutationLease: Codable {
    enum State: String, Codable {
        case pending
        case requiresFreshObservation
    }

    let lease: SnapshotMutationLease
    let state: State
    let updatedAt: Date
}

extension SnapshotStorageActor {
    func beginMutation(snapshotId: String, at snapshotPath: URL) throws -> SnapshotMutationLease {
        let snapshotFile = snapshotPath.appendingPathComponent("snapshot.json")
        guard FileManager.default.fileExists(atPath: snapshotFile.path) else {
            throw SnapshotError.snapshotNotFound
        }

        let lease = SnapshotMutationLease(snapshotId: snapshotId)
        let record = StoredSnapshotMutationLease(lease: lease, state: .pending, updatedAt: Date())
        let receiptFile = Self.mutationReceiptFile(at: snapshotPath)
        do {
            let data = try JSONCoding.makeEncoder().encode(record)
            try data.write(to: receiptFile, options: .withoutOverwriting)
            return lease
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw PeekabooError.snapshotStale(Self.consumedSnapshotMessage(snapshotId))
        } catch let error as PeekabooError {
            throw error
        } catch {
            // A present but unreadable/contended receipt is unsafe to ignore. If the receipt path
            // exists, refuse as consumed; otherwise surface the storage failure that prevented the
            // atomic reservation.
            if FileManager.default.fileExists(atPath: receiptFile.path) {
                throw PeekabooError.snapshotStale(Self.consumedSnapshotMessage(snapshotId))
            }
            throw SnapshotError.storageError(
                "Could not reserve snapshot '\(snapshotId)' for mutation: \(error.localizedDescription)")
        }
    }

    func finishMutation(
        _ lease: SnapshotMutationLease,
        requiresFreshObservation: Bool,
        at snapshotPath: URL) throws
    {
        let receiptFile = Self.mutationReceiptFile(at: snapshotPath)
        guard FileManager.default.fileExists(atPath: receiptFile.path) else {
            throw SnapshotError.storageError(
                "Mutation lease for snapshot '\(lease.snapshotId)' disappeared before completion")
        }

        let record: StoredSnapshotMutationLease
        do {
            let data = try Data(contentsOf: receiptFile)
            record = try JSONCoding.makeDecoder().decode(StoredSnapshotMutationLease.self, from: data)
        } catch {
            throw SnapshotError.storageError(
                "Mutation lease for snapshot '\(lease.snapshotId)' is unreadable; the snapshot remains blocked")
        }
        guard record.lease == lease else {
            throw SnapshotError.storageError(
                "Mutation lease for snapshot '\(lease.snapshotId)' changed before completion")
        }
        // Consumption is terminal. Duplicate or reordered Bridge completions must never downgrade
        // a receipt that already requires a fresh observation.
        if record.state == .requiresFreshObservation {
            return
        }

        if requiresFreshObservation {
            let consumed = StoredSnapshotMutationLease(
                lease: lease,
                state: .requiresFreshObservation,
                updatedAt: Date())
            do {
                let data = try JSONCoding.makeEncoder().encode(consumed)
                try data.write(to: receiptFile, options: .atomic)
            } catch {
                // The pending receipt remains in place, so subsequent mutation still fails closed.
                throw SnapshotError.storageError(
                    "Could not finalize snapshot '\(lease.snapshotId)' consumption; the snapshot remains blocked")
            }
        } else {
            do {
                try FileManager.default.removeItem(at: receiptFile)
            } catch {
                // A failed release is conservative: the existing receipt continues blocking reuse.
                throw SnapshotError.storageError(
                    "Could not release snapshot '\(lease.snapshotId)' mutation lease; the snapshot remains blocked")
            }
        }
    }

    private static func mutationReceiptFile(at snapshotPath: URL) -> URL {
        snapshotPath.appendingPathComponent("mutation-receipt.json")
    }

    private static func consumedSnapshotMessage(_ snapshotId: String) -> String {
        "Snapshot '\(snapshotId)' already drove a mutation whose result requires a fresh observation. " +
            "Run 'peekaboo see' again before another mutation. Read-only snapshot inspection is still available."
    }
}
