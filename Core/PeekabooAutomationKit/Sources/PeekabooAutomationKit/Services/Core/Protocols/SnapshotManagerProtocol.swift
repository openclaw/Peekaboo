import CoreGraphics
import Foundation

public struct SnapshotScreenshotRequest: Sendable, Equatable {
    public let snapshotId: String
    public let screenshotPath: String
    public let applicationBundleId: String?
    public let applicationProcessId: Int32?
    public let applicationName: String?
    public let windowTitle: String?
    public let windowBounds: CGRect?

    public init(
        snapshotId: String,
        screenshotPath: String,
        applicationBundleId: String?,
        applicationProcessId: Int32?,
        applicationName: String?,
        windowTitle: String?,
        windowBounds: CGRect?)
    {
        self.snapshotId = snapshotId
        self.screenshotPath = screenshotPath
        self.applicationBundleId = applicationBundleId
        self.applicationProcessId = applicationProcessId
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.windowBounds = windowBounds
    }
}

/// Protocol defining UI automation snapshot management operations.
@MainActor
public protocol SnapshotManagerProtocol: Sendable {
    /// Whether this manager applies cutoff-aware, non-destructive implicit-latest invalidation.
    var supportsImplicitLatestSnapshotInvalidation: Bool { get }

    /// Whether `storeScreenshot` copies source artifacts into independently managed storage.
    var copiesScreenshotArtifactsIntoStorage: Bool { get }

    /// Effective desktop-wide cutoff applied to implicit latest-snapshot lookup.
    /// Managers without a shared watermark can rely on the default `nil` implementation.
    var effectiveImplicitLatestInvalidationWatermark: Date? { get }

    /// Create a new snapshot container.
    /// - Returns: Unique snapshot identifier
    func createSnapshot() async throws -> String

    /// Reserve a snapshot hidden from implicit lookup until a successful observation publishes it.
    func createSnapshot(pendingAt observationStartedAt: Date) async throws -> String

    /// Store element detection results in a snapshot
    /// - Parameters:
    ///   - snapshotId: Snapshot identifier
    ///   - result: Element detection result to store
    func storeDetectionResult(snapshotId: String, result: ElementDetectionResult) async throws

    /// Retrieve element detection results from a snapshot
    /// - Parameter snapshotId: Snapshot identifier
    /// - Returns: Stored detection result if available
    func getDetectionResult(snapshotId: String) async throws -> ElementDetectionResult?

    /// Get the most recent snapshot ID
    /// - Returns: Snapshot ID if available
    func getMostRecentSnapshot() async -> String?

    /// Get the most recent snapshot ID scoped to an application.
    /// - Parameter applicationBundleId: Bundle identifier of the target application
    /// - Returns: Snapshot ID if available
    func getMostRecentSnapshot(applicationBundleId: String) async -> String?

    /// Invalidate implicit "latest" lookup through a mutation-completion cutoff.
    /// - Parameter cutoff: Snapshots created at or before this time become ineligible for implicit lookup
    /// - Returns: The snapshot ID that was latest immediately before invalidation, if any
    func invalidateImplicitLatestSnapshot(through cutoff: Date) async throws -> String?

    /// Invalidate implicit latest lookup while preserving one successfully refreshed snapshot ID.
    /// Concrete managers with atomic watermark support should override this overload.
    func invalidateImplicitLatestSnapshot(through cutoff: Date, preserving snapshotId: String?) async throws -> String?

    /// Preserve using a caller-supplied completion timestamp shared across hosts and retries.
    func invalidateImplicitLatestSnapshot(
        through cutoff: Date,
        preserving snapshotId: String?,
        preservedAt: Date?) async throws -> String?

    /// List all active snapshots
    /// - Returns: Array of snapshot information
    func listSnapshots() async throws -> [SnapshotInfo]

    /// Clean up a specific snapshot
    /// - Parameter snapshotId: Snapshot identifier to clean
    func cleanSnapshot(snapshotId: String) async throws

    /// Clean up snapshots older than specified days
    /// - Parameter days: Number of days
    /// - Returns: Number of snapshots cleaned
    func cleanSnapshotsOlderThan(days: Int) async throws -> Int

    /// Clean all snapshots
    /// - Returns: Number of snapshots cleaned
    func cleanAllSnapshots() async throws -> Int

    /// Get snapshot storage path
    /// - Returns: Path to snapshot storage directory
    func getSnapshotStoragePath() -> String

    /// Store raw screenshot and build UI map
    /// - Parameter request: Screenshot metadata and storage location for the snapshot.
    func storeScreenshot(_ request: SnapshotScreenshotRequest) async throws

    /// Store an annotated screenshot for a snapshot (optional companion to `raw.png`).
    /// - Parameters:
    ///   - snapshotId: Snapshot identifier
    ///   - annotatedScreenshotPath: Path to the annotated screenshot file
    func storeAnnotatedScreenshot(
        snapshotId: String,
        annotatedScreenshotPath: String) async throws

    /// Get element by ID from snapshot
    /// - Parameters:
    ///   - snapshotId: Snapshot identifier
    ///   - elementId: Element ID to retrieve
    /// - Returns: UI element if found
    func getElement(snapshotId: String, elementId: String) async throws -> UIElement?

    /// Find elements matching a query
    /// - Parameters:
    ///   - snapshotId: Snapshot identifier
    ///   - query: Search query
    /// - Returns: Array of matching elements
    func findElements(snapshotId: String, matching query: String) async throws -> [UIElement]

    /// Get the full UI automation snapshot data
    /// - Parameter snapshotId: Snapshot identifier
    /// - Returns: UI automation snapshot if found
    func getUIAutomationSnapshot(snapshotId: String) async throws -> UIAutomationSnapshot?
}

extension SnapshotManagerProtocol {
    public var copiesScreenshotArtifactsIntoStorage: Bool {
        false
    }

    public var supportsImplicitLatestSnapshotInvalidation: Bool {
        false
    }

    public var effectiveImplicitLatestInvalidationWatermark: Date? {
        nil
    }

    public func createSnapshot(pendingAt observationStartedAt: Date) async throws -> String {
        _ = observationStartedAt
        return try await self.createSnapshot()
    }

    /// Source-compatible fallback for managers without watermark support.
    ///
    /// The default is intentionally non-destructive. Concrete managers override the cutoff-aware requirement.
    public func invalidateImplicitLatestSnapshot(through cutoff: Date) async throws -> String? {
        _ = cutoff
        return nil
    }

    public func invalidateImplicitLatestSnapshot(
        through cutoff: Date,
        preserving snapshotId: String?) async throws -> String?
    {
        _ = snapshotId
        return try await self.invalidateImplicitLatestSnapshot(through: cutoff)
    }

    public func invalidateImplicitLatestSnapshot(
        through cutoff: Date,
        preserving snapshotId: String?,
        preservedAt: Date?) async throws -> String?
    {
        _ = preservedAt
        return try await self.invalidateImplicitLatestSnapshot(through: cutoff, preserving: snapshotId)
    }

    public func invalidateImplicitLatestSnapshot() async throws -> String? {
        try await self.invalidateImplicitLatestSnapshot(through: Date())
    }
}

/// Information about a snapshot
public struct SnapshotInfo: Sendable, Codable {
    /// Unique snapshot identifier
    public let id: String

    /// Process ID that created the snapshot
    public let processId: Int32

    /// Creation timestamp
    public let createdAt: Date

    /// Last accessed timestamp
    public let lastAccessedAt: Date

    /// Size of snapshot data in bytes
    public let sizeInBytes: Int64

    /// Number of stored screenshots
    public let screenshotCount: Int

    /// Whether the snapshot is currently active
    public let isActive: Bool

    public init(
        id: String,
        processId: Int32,
        createdAt: Date,
        lastAccessedAt: Date,
        sizeInBytes: Int64,
        screenshotCount: Int,
        isActive: Bool)
    {
        self.id = id
        self.processId = processId
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.sizeInBytes = sizeInBytes
        self.screenshotCount = screenshotCount
        self.isActive = isActive
    }
}

/// Options for snapshot cleanup
public struct SnapshotCleanupOptions: Sendable {
    /// Perform dry run (don't actually delete)
    public let dryRun: Bool

    /// Only clean snapshots from inactive processes
    public let onlyInactive: Bool

    /// Maximum age in days (nil = no age limit)
    public let maxAgeInDays: Int?

    /// Maximum total size in MB (nil = no size limit)
    public let maxTotalSizeMB: Int?

    public init(
        dryRun: Bool = false,
        onlyInactive: Bool = true,
        maxAgeInDays: Int? = nil,
        maxTotalSizeMB: Int? = nil)
    {
        self.dryRun = dryRun
        self.onlyInactive = onlyInactive
        self.maxAgeInDays = maxAgeInDays
        self.maxTotalSizeMB = maxTotalSizeMB
    }
}
