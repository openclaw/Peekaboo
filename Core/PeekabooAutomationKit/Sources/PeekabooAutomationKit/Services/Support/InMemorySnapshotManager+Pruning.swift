import Foundation

extension InMemorySnapshotManager {
    func pruneIfNeeded() {
        let cutoff = Date().addingTimeInterval(-self.options.snapshotValidityWindow)
        let expired = self.entries.filter { $0.value.lastAccessedAt < cutoff }.map(\.key)
        for id in expired {
            self.removeEntry(forSnapshotId: id)
        }

        if self.entries.count <= self.options.maxSnapshots { return }

        let ordered = self.entries.sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
        let overflow = self.entries.count - self.options.maxSnapshots
        for pair in ordered.prefix(overflow) {
            self.removeEntry(forSnapshotId: pair.key)
        }
    }

    func removeEntry(forSnapshotId snapshotId: String) {
        guard let entry = self.entries.removeValue(forKey: snapshotId) else { return }
        if self.implicitLatestPreservation?.snapshotId == snapshotId {
            self.implicitLatestPreservation = nil
        }
        if self.options.deleteArtifactsOnCleanup {
            self.deleteArtifacts(for: entry.snapshotData)
        } else {
            self.deleteManagedTemporaryArtifacts(for: entry.snapshotData)
        }
    }

    func screenshotCount(for snapshotData: UIAutomationSnapshot) -> Int {
        var count = 0
        if snapshotData.screenshotPath != nil { count += 1 }
        if let annotated = snapshotData.annotatedPath, annotated != snapshotData.screenshotPath { count += 1 }
        return count
    }

    func deleteArtifacts(for snapshotData: UIAutomationSnapshot) {
        let fm = FileManager.default
        if let screenshotPath = snapshotData.screenshotPath {
            try? fm.removeItem(atPath: screenshotPath)
        }
        if let annotatedPath = snapshotData.annotatedPath, annotatedPath != snapshotData.screenshotPath {
            try? fm.removeItem(atPath: annotatedPath)
        }
    }

    func deleteManagedTemporaryArtifacts(for snapshotData: UIAutomationSnapshot) {
        let paths = [snapshotData.screenshotPath, snapshotData.annotatedPath]
            .compactMap(\.self)
            .filter(Self.isManagedTemporaryArtifact)
        let directories = Set(paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })

        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
        }
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func isManagedTemporaryArtifact(_ path: String) -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-see", isDirectory: true)
            .standardizedFileURL.path + "/"
        return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root)
    }
}
