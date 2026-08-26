import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation

/// Default implementation of snapshot management operations.
/// Migrated from the legacy CLI automation cache with a thread-safe actor-based design.
@MainActor
public final class SnapshotManager: SnapshotManagerProtocol {
    public let supportsImplicitLatestSnapshotInvalidation = true
    public let supportsSnapshotMutationLeases = true
    public let supportsExplicitSnapshotPublication = true
    public let supportsProducerBoundSnapshotReferences = true
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
    let snapshotReferenceGenerator: SnapshotReferenceGenerator
    let postLoadBarrier: @MainActor @Sendable () async -> Void

    /// Snapshot validity window (10 minutes)
    let snapshotValidityWindow: TimeInterval = 600

    public init(
        desktopMutationWatermarkStore: DesktopMutationWatermarkStore? = nil,
        snapshotReferenceGenerator: @escaping SnapshotReferenceGenerator = SnapshotReference.generate)
    {
        self.snapshotStorageURLOverride = nil
        self.desktopMutationWatermarkStore = desktopMutationWatermarkStore
        self.snapshotReferenceGenerator = snapshotReferenceGenerator
        self.postLoadBarrier = {}
    }

    init(
        snapshotStorageURL: URL,
        desktopMutationWatermarkStore: DesktopMutationWatermarkStore? = nil,
        snapshotReferenceGenerator: @escaping SnapshotReferenceGenerator = SnapshotReference.generate,
        postLoadBarrier: @escaping @MainActor @Sendable () async -> Void = {})
    {
        self.snapshotStorageURLOverride = snapshotStorageURL
        self.desktopMutationWatermarkStore = desktopMutationWatermarkStore
        self.snapshotReferenceGenerator = snapshotReferenceGenerator
        self.postLoadBarrier = postLoadBarrier
    }

    public func createSnapshot() async throws -> String {
        let reservation = try self.reserveOwnedSnapshotDirectory()
        self.logger.debug("Creating new snapshot: \(reservation.snapshotId)")
        return try await self.initializeReservedSnapshot(reservation)
    }

    public func createSnapshot(pendingAt observationStartedAt: Date) async throws -> String {
        let reservation = try self.reserveOwnedSnapshotDirectory()
        self.logger.debug("Reserving pending snapshot: \(reservation.snapshotId)")
        return try await self.initializeReservedSnapshot(reservation) { snapshotPath in
            try self.markSnapshotPending(at: snapshotPath, observationStartedAt: observationStartedAt)
        }
    }

    public func createExplicitSnapshot() async throws -> String {
        let reservation = try self.reserveOwnedSnapshotDirectory()
        self.logger.debug("Creating explicit-only snapshot: \(reservation.snapshotId)")
        return try await self.initializeReservedSnapshot(reservation) { snapshotPath in
            try self.markSnapshotExplicitOnly(at: snapshotPath)
        }
    }

    func initializeReservedSnapshot(
        _ reservation: (snapshotId: String, url: URL),
        configure: (URL) throws -> Void = { _ in }) async throws -> String
    {
        do {
            try configure(reservation.url)
            let snapshotData = UIAutomationSnapshot(creatorProcessId: getpid())
            try await self.snapshotActor.saveSnapshot(
                snapshotId: reservation.snapshotId,
                data: snapshotData,
                at: reservation.url)
            return reservation.snapshotId
        } catch {
            try? FileManager.default.removeItem(at: reservation.url)
            throw error
        }
    }

    public func storeDetectionResult(snapshotId: String, result: ElementDetectionResult) async throws {
        guard let snapshotPath = try self.ownedSnapshotURL(for: snapshotId) else {
            throw SnapshotError.snapshotNotFound
        }
        try SnapshotPublicationBinding.validate(
            snapshotId: snapshotId,
            detectionResult: result,
            captureCoordinateContext: result.metadata.captureCoordinateContext)

        guard var snapshotData = await self.snapshotActor
            .loadSnapshot(snapshotId: snapshotId, from: snapshotPath)
        else {
            throw SnapshotError.snapshotNotFound
        }
        await self.postLoadBarrier()
        if snapshotData.creatorProcessId == nil {
            snapshotData.creatorProcessId = getpid()
        }

        // Convert detection result to snapshot format (preserve any previously stored screenshot paths).
        if (snapshotData.screenshotPath ?? "").isEmpty, !result.screenshotPath.isEmpty {
            snapshotData.screenshotPath = result.screenshotPath
        }
        snapshotData.lastUpdateTime = Date()
        snapshotData.captureCoordinateContext = result.metadata.captureCoordinateContext ?? snapshotData
            .captureCoordinateContext

        // Convert detected elements to UI map
        var uiMap: [String: UIElement] = [:]
        for element in result.elements.all {
            let uiElement = UIElement(
                id: element.id,
                elementId: "element_\(uiMap.count)",
                role: element.attributes["role"] ?? self.convertElementTypeToRole(element.type),
                title: element.attributes["title"],
                label: element.label,
                value: element.value,
                description: element.attributes["description"],
                help: element.attributes["help"],
                roleDescription: element.attributes["roleDescription"],
                identifier: element.attributes["identifier"],
                confidence: element.attributes["confidence"].flatMap(Double.init),
                frame: element.bounds,
                isActionable: element.isActionable,
                isEnabled: element.knownIsEnabled,
                isSelected: element.isSelected,
                isValueSettable: element.isValueSettable,
                keyboardShortcut: element.attributes["keyboardShortcut"])
            uiMap[element.id] = uiElement
        }
        snapshotData.uiMap = uiMap

        if let context = result.metadata.windowContext {
            self.applyWindowContext(context, to: &snapshotData)
        } else {
            snapshotData.focusedElement = nil
            self.applyLegacyWarnings(result.metadata.warnings, to: &snapshotData)
        }

        // Save updated snapshot
        try await self.snapshotActor.saveSnapshot(snapshotId: snapshotId, data: snapshotData, at: snapshotPath)
    }

    public func getDetectionResult(snapshotId: String) async throws -> ElementDetectionResult? {
        guard let snapshotPath = try self.ownedSnapshotURL(for: snapshotId) else { return nil }

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
            attributes["role"] = uiElement.role
            if let title = uiElement.title {
                attributes["title"] = title
            }
            if let description = uiElement.description {
                attributes["description"] = description
            }
            if let help = uiElement.help {
                attributes["help"] = help
            }
            if let roleDescription = uiElement.roleDescription {
                attributes["roleDescription"] = roleDescription
            }
            if let confidence = uiElement.confidence {
                attributes["confidence"] = String(format: "%.2f", confidence)
            }
            attributes["isActionable"] = String(uiElement.isActionable)
            attributes["axEnabledKnown"] = String(uiElement.isEnabled != nil)
            if let isValueSettable = uiElement.isValueSettable {
                attributes["isValueSettable"] = String(isValueSettable)
            }
            let detectedElement = DetectedElement(
                id: uiElement.id,
                type: self.convertRoleToElementType(uiElement.role),
                label: uiElement.label ?? uiElement.title,
                value: uiElement.value,
                bounds: uiElement.frame,
                isEnabled: uiElement.isEnabled ?? uiElement.isActionable,
                isSelected: uiElement.isSelected,
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
            windowContext: self.windowContext(from: snapshotData),
            isDialog: false,
            truncationInfo: nil,
            captureCoordinateContext: snapshotData.captureCoordinateContext)

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

        for snapshotURL in try self.snapshotDirectoryURLs(includingPending: false) {
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

    public func ownsSnapshot(snapshotId: String) async throws -> Bool {
        // Disk ownership is the caller-local cache namespace, durable across short-lived CLI manager instances.
        // Long-lived Bridge hosts use InMemorySnapshotManager, so they do not claim this disk namespace.
        try self.ownedSnapshotURL(for: snapshotId, requiringSnapshotData: false) != nil
    }

    public func cleanSnapshotsOlderThan(days: Int) async throws -> Int {
        let cutoffDate = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let snapshotIDs = try self.cleanupEligibleSnapshotDirectoryURLs().compactMap { url -> String? in
            guard let createdAt = self.snapshotCreationDate(at: url), createdAt < cutoffDate else { return nil }
            return url.lastPathComponent
        }

        for snapshotID in snapshotIDs {
            try await self.cleanSnapshot(snapshotId: snapshotID)
        }

        return snapshotIDs.count
    }

    public func cleanAllSnapshots() async throws -> Int {
        let snapshotIDs = try self.cleanupEligibleSnapshotDirectoryURLs().map(\.lastPathComponent)

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
