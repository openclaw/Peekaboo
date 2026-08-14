import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation

/// In-memory implementation of `SnapshotManagerProtocol`.
///
/// Unlike `SnapshotManager`, this manager does not persist snapshot state to disk and is ideal for long-lived host apps
/// (e.g. a macOS menubar app) where automation state can be kept in-process for speed and fidelity.
@MainActor
public final class InMemorySnapshotManager: SnapshotManagerProtocol {
    public let supportsImplicitLatestSnapshotInvalidation = true
    public let supportsSnapshotMutationLeases = true
    public let supportsExplicitSnapshotPublication = true
    public var copiesScreenshotArtifactsIntoStorage: Bool {
        self.options.copyArtifactsOnStore
    }

    public let supportsAtomicObservationSnapshotPublication = true

    public var effectiveImplicitLatestInvalidationWatermark: Date? {
        SnapshotManager.latestWatermark(
            self.implicitLatestInvalidatedAt,
            self.desktopMutationWatermarkStore?.effectiveWatermark())
    }

    public struct Options: Sendable {
        /// How long snapshots are considered valid for `getMostRecentSnapshot()` and pruning.
        public var snapshotValidityWindow: TimeInterval

        /// Maximum number of snapshots kept in memory (LRU eviction).
        public var maxSnapshots: Int

        /// If enabled, attempts to delete any referenced screenshot artifacts on snapshot cleanup.
        public var deleteArtifactsOnCleanup: Bool

        /// Copy screenshot artifacts into a manager-owned temporary directory before storing paths.
        public var copyArtifactsOnStore: Bool

        public init(
            snapshotValidityWindow: TimeInterval = 600,
            maxSnapshots: Int = 25,
            deleteArtifactsOnCleanup: Bool = false,
            copyArtifactsOnStore: Bool = false)
        {
            self.snapshotValidityWindow = snapshotValidityWindow
            self.maxSnapshots = max(1, maxSnapshots)
            self.deleteArtifactsOnCleanup = deleteArtifactsOnCleanup
            self.copyArtifactsOnStore = copyArtifactsOnStore
        }
    }

    struct Entry {
        // Immutable observation order; reads only refresh `lastAccessedAt` for LRU pruning.
        let createdAt: Date
        var lastAccessedAt: Date
        var processId: Int32
        var isPending: Bool
        var isImplicitLatestEligible: Bool
        var detectionResult: ElementDetectionResult?
        var snapshotData: UIAutomationSnapshot
    }

    struct ImplicitLatestPreservation {
        let snapshotId: String
        let invalidatedThrough: Date
        let preservedAt: Date
    }

    enum MutationLeaseState {
        case pending(SnapshotMutationLease)
        case requiresFreshObservation(SnapshotMutationLease)

        var lease: SnapshotMutationLease {
            switch self {
            case let .pending(lease), let .requiresFreshObservation(lease): lease
            }
        }
    }

    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "InMemorySnapshotManager")
    let options: Options
    let desktopMutationWatermarkStore: DesktopMutationWatermarkStore?
    var entries: [String: Entry] = [:]
    var implicitLatestInvalidatedAt: Date?
    var implicitLatestPreservation: ImplicitLatestPreservation?
    var mutationLeases: [String: MutationLeaseState] = [:]

    public init(
        detectionResult: ElementDetectionResult? = nil,
        options: Options = Options(),
        desktopMutationWatermarkStore: DesktopMutationWatermarkStore? = nil)
    {
        self.options = options
        self.desktopMutationWatermarkStore = desktopMutationWatermarkStore

        if let detectionResult {
            let now = Date()
            let snapshotId = detectionResult.snapshotId
            var entry = Entry(
                createdAt: now,
                lastAccessedAt: now,
                processId: getpid(),
                isPending: false,
                isImplicitLatestEligible: true,
                detectionResult: detectionResult,
                snapshotData: UIAutomationSnapshot(creatorProcessId: getpid()))
            self.applyDetectionResult(detectionResult, to: &entry.snapshotData)
            self.entries[snapshotId] = entry
        }
    }
}
