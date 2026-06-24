import Foundation

extension InMemorySnapshotManager {
    // MARK: - Snapshot lifecycle

    public func createSnapshot() async throws -> String {
        try await self.createSnapshotImpl(pendingAt: nil)
    }

    public func createSnapshot(pendingAt observationStartedAt: Date) async throws -> String {
        try await self.createSnapshotImpl(pendingAt: observationStartedAt)
    }

    private func createSnapshotImpl(pendingAt observationStartedAt: Date?) async throws -> String {
        self.pruneIfNeeded()

        let timestamp = Int(Date().timeIntervalSince1970 * 1000) // milliseconds
        let randomSuffix = Int.random(in: 1000...9999)
        let snapshotId = "\(timestamp)-\(randomSuffix)"

        let now = Date()
        self.entries[snapshotId] = Entry(
            createdAt: observationStartedAt ?? now,
            lastAccessedAt: now,
            processId: getpid(),
            isPending: observationStartedAt != nil,
            detectionResult: nil,
            snapshotData: UIAutomationSnapshot(creatorProcessId: getpid()))
        self.pruneIfNeeded()

        return snapshotId
    }

    public func storeDetectionResult(snapshotId: String, result: ElementDetectionResult) async throws {
        self.pruneIfNeeded()

        var entry = self.entries[snapshotId] ?? Entry(
            createdAt: Date(),
            lastAccessedAt: Date(),
            processId: getpid(),
            isPending: false,
            detectionResult: nil,
            snapshotData: UIAutomationSnapshot(creatorProcessId: getpid()))

        entry.lastAccessedAt = Date()
        entry.detectionResult = result
        self.applyDetectionResult(result, to: &entry.snapshotData)
        self.entries[snapshotId] = entry
        self.pruneIfNeeded()
    }

    public func getDetectionResult(snapshotId: String) async throws -> ElementDetectionResult? {
        guard var entry = self.entries[snapshotId] else { return nil }
        entry.lastAccessedAt = Date()
        self.entries[snapshotId] = entry

        if let detection = entry.detectionResult {
            return detection
        }

        // Best-effort fallback for snapshots that were created via `storeScreenshot` without a stored detection result.
        return self.detectionResult(from: entry.snapshotData, snapshotId: snapshotId)
    }

    public func getMostRecentSnapshot() async -> String? {
        self.pruneIfNeeded()

        let cutoff = Date().addingTimeInterval(-self.options.snapshotValidityWindow)
        let effectiveWatermark = self.effectiveImplicitLatestInvalidationWatermark
        let normalLatest = self.entries
            .filter { _, entry in
                !entry.isPending
                    && entry.createdAt >= cutoff
                    && (effectiveWatermark.map { entry.createdAt > $0 } ?? true)
            }
            .max(by: { $0.value.createdAt < $1.value.createdAt })
        if let preservation = self.implicitLatestPreservation,
           self.entries[preservation.snapshotId]?.isPending == false,
           preservation.preservedAt >= cutoff,
           effectiveWatermark.map({ $0 <= preservation.invalidatedThrough }) ?? true,
           normalLatest.map({ $0.value.createdAt <= preservation.preservedAt }) ?? true
        {
            return preservation.snapshotId
        }
        return normalLatest?.key
    }

    public func getMostRecentSnapshot(applicationBundleId: String) async -> String? {
        self.pruneIfNeeded()

        let cutoff = Date().addingTimeInterval(-self.options.snapshotValidityWindow)
        let effectiveWatermark = self.effectiveImplicitLatestInvalidationWatermark
        let normalLatest = self.entries
            .filter { _, entry in
                !entry.isPending
                    && entry.createdAt >= cutoff
                    && (effectiveWatermark.map { entry.createdAt > $0 } ?? true)
                    && entry.snapshotData.applicationBundleId == applicationBundleId
            }
            .max(by: { $0.value.createdAt < $1.value.createdAt })
        if let preservation = self.implicitLatestPreservation,
           let preservedEntry = self.entries[preservation.snapshotId],
           !preservedEntry.isPending,
           preservation.preservedAt >= cutoff,
           effectiveWatermark.map({ $0 <= preservation.invalidatedThrough }) ?? true,
           preservedEntry.snapshotData.applicationBundleId == applicationBundleId,
           normalLatest.map({ $0.value.createdAt <= preservation.preservedAt }) ?? true
        {
            return preservation.snapshotId
        }
        return normalLatest?.key
    }

    public func invalidateImplicitLatestSnapshot(through cutoff: Date) async throws -> String? {
        try await self.invalidateImplicitLatestSnapshot(through: cutoff, preserving: nil)
    }

    public func invalidateImplicitLatestSnapshot(
        through cutoff: Date,
        preserving snapshotId: String?) async throws -> String?
    {
        try await self.invalidateImplicitLatestSnapshot(
            through: cutoff,
            preserving: snapshotId,
            preservedAt: snapshotId == nil ? nil : Date())
    }

    public func invalidateImplicitLatestSnapshot(
        through cutoff: Date,
        preserving snapshotId: String?,
        preservedAt: Date?) async throws -> String?
    {
        self.pruneIfNeeded()
        let validityCutoff = Date().addingTimeInterval(-self.options.snapshotValidityWindow)
        let previousEffectiveWatermark = self.effectiveImplicitLatestInvalidationWatermark
        let normalLatest = self.entries
            .filter { _, entry in
                !entry.isPending
                    && entry.createdAt >= validityCutoff
                    && entry.createdAt <= cutoff
                    && (previousEffectiveWatermark.map { entry.createdAt > $0 } ?? true)
            }
            .max(by: { $0.value.createdAt < $1.value.createdAt })
        let latestSnapshotId: String? = if let preservation = self.implicitLatestPreservation,
                                           self.entries[preservation.snapshotId]?.isPending == false,
                                           preservation.preservedAt >= validityCutoff,
                                           preservation.preservedAt <= cutoff,
                                           previousEffectiveWatermark.map({
                                               $0 <= preservation.invalidatedThrough
                                           }) ?? true,
                                           normalLatest.map({
                                               $0.value.createdAt <= preservation.preservedAt
                                           }) ?? true
        {
            preservation.snapshotId
        } else {
            normalLatest?.key
        }
        let sharedWatermark = try self.desktopMutationWatermarkStore?.advance(through: cutoff)
        let effectiveWatermark = max(
            SnapshotManager.latestWatermark(
                self.implicitLatestInvalidatedAt,
                sharedWatermark) ?? cutoff,
            cutoff)
        if let snapshotId, self.entries[snapshotId]?.isPending == true {
            self.entries[snapshotId]?.isPending = false
        }
        if let snapshotId,
           let preservedAt,
           self.entries[snapshotId] != nil,
           effectiveWatermark <= cutoff
        {
            self.implicitLatestPreservation = .init(
                snapshotId: snapshotId,
                invalidatedThrough: cutoff,
                preservedAt: preservedAt)
        } else if let preservation = self.implicitLatestPreservation,
                  effectiveWatermark > preservation.invalidatedThrough
        {
            self.implicitLatestPreservation = nil
        }
        self.implicitLatestInvalidatedAt = effectiveWatermark
        return latestSnapshotId
    }

    public func listSnapshots() async throws -> [SnapshotInfo] {
        self.pruneIfNeeded()

        let values = self.entries.compactMap { id, entry -> SnapshotInfo? in
            guard !entry.isPending else { return nil }
            return SnapshotInfo(
                id: id,
                processId: entry.processId,
                createdAt: entry.createdAt,
                lastAccessedAt: entry.lastAccessedAt,
                sizeInBytes: 0,
                screenshotCount: self.screenshotCount(for: entry.snapshotData),
                isActive: true)
        }
        return values.sorted { $0.createdAt > $1.createdAt }
    }

    public func cleanSnapshot(snapshotId: String) async throws {
        self.removeEntry(forSnapshotId: snapshotId)
    }

    public func cleanSnapshotsOlderThan(days: Int) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let toRemove = self.entries.filter { $0.value.createdAt < cutoff }.map(\.key)
        for id in toRemove {
            try await self.cleanSnapshot(snapshotId: id)
        }
        return toRemove.count
    }

    public func cleanAllSnapshots() async throws -> Int {
        let count = self.entries.count
        if self.options.deleteArtifactsOnCleanup {
            for entry in self.entries.values {
                self.deleteArtifacts(for: entry.snapshotData)
            }
        } else {
            for entry in self.entries.values {
                self.deleteManagedTemporaryArtifacts(for: entry.snapshotData)
            }
        }
        self.entries.removeAll()
        self.implicitLatestInvalidatedAt = nil
        self.implicitLatestPreservation = nil
        return count
    }

    public func getSnapshotStoragePath() -> String {
        "memory"
    }
}
