import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation

@MainActor
private final class SeededSnapshotReferenceGenerator {
    private let initial: SnapshotReference
    private var usedInitial = false

    init(initial: SnapshotReference) {
        self.initial = initial
    }

    func next() -> SnapshotReference {
        if !self.usedInitial {
            self.usedInitial = true
            return self.initial
        }
        return SnapshotReference.generate()
    }
}

/// In-memory implementation of `SnapshotManagerProtocol`.
///
/// Unlike `SnapshotManager`, this manager does not persist snapshot state to disk and is ideal for long-lived host apps
/// (e.g. a macOS menubar app) where automation state can be kept in-process for speed and fidelity.
@MainActor
public final class InMemorySnapshotManager: SnapshotManagerProtocol {
    public let supportsImplicitLatestSnapshotInvalidation = true
    public let supportsSnapshotMutationLeases = true
    public let supportsExplicitSnapshotPublication = true
    public let supportsProducerBoundSnapshotReferences = true
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
    let snapshotReferenceGenerator: SnapshotReferenceGenerator
    var entries: [String: Entry] = [:]
    var implicitLatestInvalidatedAt: Date?
    var implicitLatestPreservation: ImplicitLatestPreservation?
    var mutationLeases: [String: MutationLeaseState] = [:]

    public init(
        options: Options = Options(),
        desktopMutationWatermarkStore: DesktopMutationWatermarkStore? = nil,
        snapshotReferenceGenerator: @escaping SnapshotReferenceGenerator = SnapshotReference.generate)
    {
        self.options = options
        self.desktopMutationWatermarkStore = desktopMutationWatermarkStore
        self.snapshotReferenceGenerator = snapshotReferenceGenerator
    }

    @available(*, deprecated, message: "Use await InMemorySnapshotManager.containing(_:) for seeded state")
    public convenience init(
        detectionResult: ElementDetectionResult?,
        options: Options = Options(),
        desktopMutationWatermarkStore: DesktopMutationWatermarkStore? = nil)
    {
        self.init(
            options: options,
            desktopMutationWatermarkStore: desktopMutationWatermarkStore)
        guard let detectionResult else { return }
        do {
            try SnapshotPublicationBinding.validate(
                snapshotId: detectionResult.snapshotId,
                detectionResult: detectionResult)
        } catch {
            self.logger.error("Refusing invalid compatibility snapshot publication: \(error.localizedDescription)")
            return
        }

        let now = Date()
        var entry = Entry(
            createdAt: now,
            lastAccessedAt: now,
            processId: getpid(),
            isPending: false,
            isImplicitLatestEligible: true,
            detectionResult: detectionResult,
            snapshotData: UIAutomationSnapshot(creatorProcessId: getpid()))
        self.applyDetectionResult(detectionResult, to: &entry.snapshotData)
        self.entries[detectionResult.snapshotId] = entry
    }

    /// Creates a manager through the same create-before-store path used by production observation.
    public static func containing(
        _ detectionResult: ElementDetectionResult,
        options: Options = Options(),
        desktopMutationWatermarkStore: DesktopMutationWatermarkStore? = nil) async throws
        -> InMemorySnapshotManager
    {
        guard let reference = SnapshotReference(rawValue: detectionResult.snapshotId) else {
            throw SnapshotError.invalidSnapshotReference(detectionResult.snapshotId)
        }
        let generator = SeededSnapshotReferenceGenerator(initial: reference)
        let manager = InMemorySnapshotManager(
            options: options,
            desktopMutationWatermarkStore: desktopMutationWatermarkStore,
            snapshotReferenceGenerator: { generator.next() })
        let snapshotId = try await manager.createSnapshot()
        try await manager.storeDetectionResult(snapshotId: snapshotId, result: detectionResult)
        return manager
    }

    func validateSnapshotReference(_ snapshotId: String) throws {
        guard SnapshotReference(rawValue: snapshotId) != nil else {
            throw SnapshotError.invalidSnapshotReference(snapshotId)
        }
    }

    func requireEntry(for snapshotId: String) throws -> Entry {
        try self.validateSnapshotReference(snapshotId)
        guard let entry = self.entries[snapshotId] else {
            throw SnapshotError.snapshotNotFound
        }
        return entry
    }
}
