import CoreGraphics
import Foundation
import PeekabooFoundation

public typealias SnapshotReferenceGenerator = @MainActor @Sendable () -> SnapshotReference

/// Durable, single-use claim acquired immediately before a snapshot-backed UI mutation.
public struct SnapshotMutationLease: Codable, Equatable, Sendable {
    public let snapshotId: String
    public let token: UUID

    public init(snapshotId: String, token: UUID = UUID()) {
        self.snapshotId = snapshotId
        self.token = token
    }
}

public struct SnapshotScreenshotRequest: Sendable, Equatable {
    public let snapshotId: String
    public let screenshotPath: String
    public let applicationBundleId: String?
    public let applicationProcessId: Int32?
    public let applicationName: String?
    public let windowTitle: String?
    public let windowBounds: CGRect?
    public let windowID: Int?
    public let windowMutationIdentity: WindowMutationIdentity?
    public let captureCoordinateContext: CaptureCoordinateContext?

    public init(
        snapshotId: String,
        screenshotPath: String,
        applicationBundleId: String?,
        applicationProcessId: Int32?,
        applicationName: String?,
        windowTitle: String?,
        windowBounds: CGRect?,
        windowID: Int? = nil,
        windowMutationIdentity: WindowMutationIdentity? = nil,
        captureCoordinateContext: CaptureCoordinateContext? = nil)
    {
        self.snapshotId = snapshotId
        self.screenshotPath = screenshotPath
        self.applicationBundleId = applicationBundleId
        self.applicationProcessId = applicationProcessId
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.windowBounds = windowBounds
        self.windowID = windowID
        self.windowMutationIdentity = windowMutationIdentity
        self.captureCoordinateContext = captureCoordinateContext
    }
}

public struct SnapshotObservationPublicationRequest: Sendable {
    public let screenshot: SnapshotScreenshotRequest
    public let detectionResult: ElementDetectionResult?
    public let annotatedScreenshotPath: String?

    public init(
        screenshot: SnapshotScreenshotRequest,
        detectionResult: ElementDetectionResult?,
        annotatedScreenshotPath: String?)
    {
        self.screenshot = screenshot
        self.detectionResult = detectionResult
        self.annotatedScreenshotPath = annotatedScreenshotPath
    }
}

/// Protocol defining UI automation snapshot management operations.
@MainActor
public protocol SnapshotManagerProtocol: Sendable {
    /// Whether this manager applies cutoff-aware, non-destructive implicit-latest invalidation.
    var supportsImplicitLatestSnapshotInvalidation: Bool { get }

    /// Whether `storeScreenshot` copies source artifacts into independently managed storage.
    var copiesScreenshotArtifactsIntoStorage: Bool { get }

    /// Whether this manager can replace a complete observation snapshot as one transaction.
    var supportsAtomicObservationSnapshotPublication: Bool { get }

    /// Whether this manager atomically blocks replay of snapshot-backed mutations.
    var supportsSnapshotMutationLeases: Bool { get }

    /// Whether this manager can publish snapshots that remain excluded from implicit latest lookup.
    var supportsExplicitSnapshotPublication: Bool { get }

    /// Whether every created snapshot uses a producer-bound `ps1_` authority and strict ownership checks.
    var supportsProducerBoundSnapshotReferences: Bool { get }

    /// Effective desktop-wide cutoff applied to implicit latest-snapshot lookup.
    /// Managers without a shared watermark can rely on the default `nil` implementation.
    var effectiveImplicitLatestInvalidationWatermark: Date? { get }

    /// Create a new snapshot container.
    /// - Returns: Unique snapshot identifier
    func createSnapshot() async throws -> String

    /// Reserve a snapshot hidden from implicit lookup until a successful observation publishes it.
    func createSnapshot(pendingAt observationStartedAt: Date) async throws -> String

    /// Create a published snapshot that is addressable only by its explicit ID.
    ///
    /// Explicit-only snapshots participate in normal retention, cleanup, and mutation leasing, but never replace
    /// the element-producing snapshot returned by implicit latest lookup.
    func createExplicitSnapshot() async throws -> String

    /// Return whether this manager created and still owns the canonical snapshot reference.
    ///
    /// A syntactically invalid reference throws ``SnapshotError/invalidSnapshotReference(_:)``;
    /// a canonical reference owned by another producer returns `false`.
    func ownsSnapshot(snapshotId: String) async throws -> Bool

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

    /// Atomically publish the raster, element map, and optional annotation produced by one observation.
    func storeObservationSnapshot(_ request: SnapshotObservationPublicationRequest) async throws

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

    /// Atomically reserve a snapshot for one mutation.
    ///
    /// Read-only snapshot APIs remain available while a lease exists. A second mutation must fail
    /// until the first lease is resolved, and a lease resolved as requiring observation remains
    /// permanently unavailable for mutation.
    func beginSnapshotMutation(snapshotId: String) async throws -> SnapshotMutationLease

    /// Resolve a mutation lease from the canonical action outcome.
    ///
    /// When `requiresFreshObservation` is true, the snapshot remains readable but cannot drive
    /// another mutation. Otherwise the lease is released for compatible confirmed/no-op flows.
    func finishSnapshotMutation(
        _ lease: SnapshotMutationLease,
        requiresFreshObservation: Bool) async throws
}

extension SnapshotManagerProtocol {
    public var copiesScreenshotArtifactsIntoStorage: Bool {
        false
    }

    public var supportsImplicitLatestSnapshotInvalidation: Bool {
        false
    }

    public var supportsAtomicObservationSnapshotPublication: Bool {
        false
    }

    public var supportsSnapshotMutationLeases: Bool {
        false
    }

    public var supportsExplicitSnapshotPublication: Bool {
        false
    }

    public var supportsProducerBoundSnapshotReferences: Bool {
        false
    }

    public var effectiveImplicitLatestInvalidationWatermark: Date? {
        nil
    }

    public func createSnapshot(pendingAt observationStartedAt: Date) async throws -> String {
        _ = observationStartedAt
        return try await self.createSnapshot()
    }

    public func createExplicitSnapshot() async throws -> String {
        throw SnapshotError.storageError(
            "This snapshot manager does not support explicit-reference-only snapshots")
    }

    public func ownsSnapshot(snapshotId: String) async throws -> Bool {
        guard SnapshotReference(rawValue: snapshotId) != nil else {
            throw SnapshotError.invalidSnapshotReference(snapshotId)
        }
        return false
    }

    public func storeObservationSnapshot(_ request: SnapshotObservationPublicationRequest) async throws {
        _ = request
        throw SnapshotError.storageError(
            "This snapshot manager does not support atomic observation publication")
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

    public func beginSnapshotMutation(snapshotId: String) async throws -> SnapshotMutationLease {
        _ = snapshotId
        throw SnapshotError.storageError(
            "This snapshot manager does not support fail-closed mutation leases")
    }

    public func finishSnapshotMutation(
        _ lease: SnapshotMutationLease,
        requiresFreshObservation: Bool) async throws
    {
        _ = lease
        _ = requiresFreshObservation
        throw SnapshotError.storageError(
            "This snapshot manager does not support fail-closed mutation leases")
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
