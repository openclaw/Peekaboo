import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation

/// Default implementation of snapshot management operations.
/// Migrated from the legacy CLI automation cache with a thread-safe actor-based design.
@MainActor
public final class SnapshotManager: SnapshotManagerProtocol {
    public let supportsImplicitLatestSnapshotInvalidation = true
    public let copiesScreenshotArtifactsIntoStorage = true

    public var effectiveImplicitLatestInvalidationWatermark: Date? {
        let shared = self.desktopMutationWatermarkStore?.effectiveWatermark()
        let local = self.implicitLatestInvalidationWatermark()
        return Self.latestWatermark(local, shared)
    }

    let logger = Logger(subsystem: "boo.peekaboo.core", category: "SnapshotManager")
    let snapshotActor = SnapshotStorageActor()
    let snapshotStorageURLOverride: URL?
    let desktopMutationWatermarkStore: DesktopMutationWatermarkStore?

    /// Snapshot validity window (10 minutes)
    let snapshotValidityWindow: TimeInterval = 600

    public init(desktopMutationWatermarkStore: DesktopMutationWatermarkStore? = nil) {
        self.snapshotStorageURLOverride = nil
        self.desktopMutationWatermarkStore = desktopMutationWatermarkStore
    }

    init(
        snapshotStorageURL: URL,
        desktopMutationWatermarkStore: DesktopMutationWatermarkStore? = nil)
    {
        self.snapshotStorageURLOverride = snapshotStorageURL
        self.desktopMutationWatermarkStore = desktopMutationWatermarkStore
    }

    public func createSnapshot() async throws -> String {
        // Generate timestamp-based snapshot ID for cross-process compatibility
        let snapshotId = self.makeSnapshotID()

        self.logger.debug("Creating new snapshot: \(snapshotId)")

        // Create snapshot directory
        let snapshotPath = self.getSnapshotPath(for: snapshotId)
        try FileManager.default.createDirectory(at: snapshotPath, withIntermediateDirectories: true)

        // Initialize empty snapshot data
        let snapshotData = UIAutomationSnapshot(creatorProcessId: getpid())
        try await self.snapshotActor.saveSnapshot(snapshotId: snapshotId, data: snapshotData, at: snapshotPath)

        return snapshotId
    }

    public func createSnapshot(pendingAt observationStartedAt: Date) async throws -> String {
        let snapshotId = self.makeSnapshotID()
        let storageURL = self.getSnapshotStorageURL()
        let snapshotPath = self.getSnapshotPath(for: snapshotId)
        let stagingPath = storageURL.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)

        self.logger.debug("Reserving pending snapshot: \(snapshotId)")
        try FileManager.default.createDirectory(at: stagingPath, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stagingPath) }

        try self.markSnapshotPending(at: stagingPath, observationStartedAt: observationStartedAt)
        let snapshotData = UIAutomationSnapshot(creatorProcessId: getpid())
        try await self.snapshotActor.saveSnapshot(snapshotId: snapshotId, data: snapshotData, at: stagingPath)
        try FileManager.default.moveItem(at: stagingPath, to: snapshotPath)
        return snapshotId
    }

    public func storeDetectionResult(snapshotId: String, result: ElementDetectionResult) async throws {
        let snapshotPath = self.getSnapshotPath(for: snapshotId)

        // Load existing snapshot or create new
        var snapshotData = await self.snapshotActor
            .loadSnapshot(snapshotId: snapshotId, from: snapshotPath) ?? UIAutomationSnapshot()
        if snapshotData.creatorProcessId == nil {
            snapshotData.creatorProcessId = getpid()
        }

        // Convert detection result to snapshot format (preserve any previously stored screenshot paths).
        if (snapshotData.screenshotPath ?? "").isEmpty, !result.screenshotPath.isEmpty {
            snapshotData.screenshotPath = result.screenshotPath
        }
        snapshotData.lastUpdateTime = Date()

        // Convert detected elements to UI map
        var uiMap: [String: UIElement] = [:]
        for element in result.elements.all {
            let uiElement = UIElement(
                id: element.id,
                elementId: "element_\(uiMap.count)",
                role: self.convertElementTypeToRole(element.type),
                title: element.label,
                label: element.label,
                value: element.value,
                identifier: element.attributes["identifier"],
                frame: element.bounds,
                isActionable: self.isActionableType(element.type),
                keyboardShortcut: element.attributes["keyboardShortcut"])
            uiMap[element.id] = uiElement
        }
        snapshotData.uiMap = uiMap

        if let context = result.metadata.windowContext {
            self.applyWindowContext(context, to: &snapshotData)
        } else {
            self.applyLegacyWarnings(result.metadata.warnings, to: &snapshotData)
        }

        // Save updated snapshot
        try await self.snapshotActor.saveSnapshot(snapshotId: snapshotId, data: snapshotData, at: snapshotPath)
    }

    public func getDetectionResult(snapshotId: String) async throws -> ElementDetectionResult? {
        let snapshotPath = self.getSnapshotPath(for: snapshotId)

        guard let snapshotData = await self.snapshotActor.loadSnapshot(snapshotId: snapshotId, from: snapshotPath)
        else {
            return nil
        }

        // Convert snapshot data back to detection result
        var elements = DetectedElements()
        var allElements: [DetectedElement] = []

        for (_, uiElement) in snapshotData.uiMap {
            var attributes: [String: String] = [:]
            if let identifier = uiElement.identifier {
                attributes["identifier"] = identifier
            }
            if let shortcut = uiElement.keyboardShortcut {
                attributes["keyboardShortcut"] = shortcut
            }
            let detectedElement = DetectedElement(
                id: uiElement.id,
                type: self.convertRoleToElementType(uiElement.role),
                label: uiElement.label ?? uiElement.title,
                value: uiElement.value,
                bounds: uiElement.frame,
                isEnabled: uiElement.isActionable,
                attributes: attributes)
            allElements.append(detectedElement)
        }

        // Organize by type
        elements = self.organizeElementsByType(allElements)

        let metadata = DetectionMetadata(
            detectionTime: Date().timeIntervalSince(snapshotData.lastUpdateTime),
            elementCount: snapshotData.uiMap.count,
            method: "snapshot-cache",
            warnings: self.buildWarnings(from: snapshotData),
            windowContext: self.windowContext(from: snapshotData))

        return ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: snapshotData.annotatedPath ?? snapshotData.screenshotPath ?? "",
            elements: elements,
            metadata: metadata)
    }

    public func getMostRecentSnapshot() async -> String? {
        await self.findLatestValidSnapshot()
    }

    public func getMostRecentSnapshot(applicationBundleId: String) async -> String? {
        await self.findLatestValidSnapshot(applicationBundleId: applicationBundleId)
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
        let latestSnapshotId = await self.findLatestValidSnapshot(createdAtOrBefore: cutoff)
        try self.writeImplicitLatestInvalidationState(
            through: cutoff,
            preserving: snapshotId,
            preservedAt: preservedAt)
        return latestSnapshotId
    }

    public func listSnapshots() async throws -> [SnapshotInfo] {
        var snapshotInfos: [SnapshotInfo] = []

        for snapshotURL in self.snapshotDirectoryURLs(includingPending: false) {
            let snapshotId = snapshotURL.lastPathComponent

            // Get snapshot metadata
            let resourceValues = try? snapshotURL.resourceValues(forKeys: [.creationDateKey])
            let creationDate = self.snapshotCreationDate(
                at: snapshotURL,
                fallback: resourceValues?.creationDate) ?? Date()

            // Load snapshot data to get details
            let snapshotData = await self.snapshotActor.loadSnapshot(snapshotId: snapshotId, from: snapshotURL)

            // Count screenshots
            let screenshotCount = self.countScreenshots(in: snapshotURL)

            // Calculate size
            let sizeInBytes = self.calculateDirectorySize(snapshotURL)

            // Check if process is still active
            let processId = snapshotData?.creatorProcessId ?? self.extractProcessId(from: snapshotId)
            let isActive = self.isProcessActive(processId)

            let info = SnapshotInfo(
                id: snapshotId,
                processId: processId,
                createdAt: creationDate,
                lastAccessedAt: snapshotData?.lastUpdateTime ?? creationDate,
                sizeInBytes: sizeInBytes,
                screenshotCount: screenshotCount,
                isActive: isActive)
            snapshotInfos.append(info)
        }

        return snapshotInfos.sorted { $0.createdAt > $1.createdAt }
    }

    public func cleanSnapshot(snapshotId: String) async throws {
        if try self.removeSnapshotAndPreservation(snapshotId: snapshotId) {
            self.logger.info("Cleaned snapshot: \(snapshotId)")
        } else {
            self.logger.debug("Snapshot \(snapshotId) does not exist, skipping cleanup")
        }
    }

    public func cleanSnapshotsOlderThan(days: Int) async throws -> Int {
        let cutoffDate = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let snapshotIDs = self.snapshotDirectoryURLs(
            includingPending: true,
            requiringSnapshotData: false).compactMap { url -> String? in
            guard let createdAt = self.snapshotCreationDate(at: url), createdAt < cutoffDate else { return nil }
            return url.lastPathComponent
        }

        for snapshotID in snapshotIDs {
            try await self.cleanSnapshot(snapshotId: snapshotID)
        }

        return snapshotIDs.count
    }

    public func cleanAllSnapshots() async throws -> Int {
        let snapshotIDs = self.snapshotDirectoryURLs(
            includingPending: true,
            requiringSnapshotData: false).map(\.lastPathComponent)

        for snapshotID in snapshotIDs {
            try await self.cleanSnapshot(snapshotId: snapshotID)
        }

        try self.clearImplicitLatestInvalidationWatermark()

        return snapshotIDs.count
    }

    public func getSnapshotStoragePath() -> String {
        self.getSnapshotStorageURL().path
    }
}
