import Foundation
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation

@MainActor
final class InteractionMutationTracker {
    private let desktopMutationWatermarkStore: DesktopMutationWatermarkStore
    private var pendingDesktopMutation: DesktopMutationWatermarkStore.PendingMutation?
    private var durableMutationLeaseCount = 0
    private(set) var mutationStartedAt: Date?
    private(set) var mutationSequence: UInt64 = 0
    private var successfulCompletionCutoff: Date?
    private var failedInvalidationCutoff: Date?
    private(set) var preservedSnapshotID: String?
    private(set) var preservedAt: Date?

    init(desktopMutationWatermarkStore: DesktopMutationWatermarkStore = DesktopMutationWatermarkStore()) {
        self.desktopMutationWatermarkStore = desktopMutationWatermarkStore
    }

    var hasFailedInvalidationAttempt: Bool {
        self.failedInvalidationCutoff != nil
    }

    var hasPendingDurableMutation: Bool {
        self.pendingDesktopMutation != nil
    }

    @discardableResult
    func begin(
        at cutoff: Date = Date(),
        preservingSnapshotsCreatedAfterBoundary: Bool = false
    ) -> Date {
        if self.mutationSequence < UInt64.max {
            self.mutationSequence += 1
        }
        if let failedInvalidationCutoff, cutoff > failedInvalidationCutoff {
            self.failedInvalidationCutoff = nil
        }
        if self.mutationStartedAt == nil {
            self.mutationStartedAt = cutoff
        }
        if preservingSnapshotsCreatedAfterBoundary {
            self.successfulCompletionCutoff = max(self.successfulCompletionCutoff ?? cutoff, cutoff)
        } else {
            self.successfulCompletionCutoff = nil
        }
        self.preservedSnapshotID = nil
        self.preservedAt = nil
        return self.mutationStartedAt ?? cutoff
    }

    func preserveFreshObservation(
        snapshotId: String,
        startedAt: Date,
        preservedAt: Date,
        preservationAllowed: Bool = true
    ) {
        guard self.mutationStartedAt != nil else { return }
        guard preservationAllowed else {
            self.successfulCompletionCutoff = nil
            self.preservedSnapshotID = nil
            self.preservedAt = nil
            return
        }
        self.successfulCompletionCutoff = max(self.successfulCompletionCutoff ?? startedAt, startedAt)
        self.preservedSnapshotID = snapshotId
        self.preservedAt = preservedAt
    }

    @discardableResult
    func beginDurableMutation(at startedAt: Date = Date()) throws -> Bool {
        guard self.pendingDesktopMutation == nil else { return false }
        self.pendingDesktopMutation = try self.desktopMutationWatermarkStore.beginMutation(at: startedAt)
        self.durableMutationLeaseCount = 1
        return true
    }

    func retainDurableMutationLease(at startedAt: Date = Date()) throws {
        if self.pendingDesktopMutation == nil {
            self.pendingDesktopMutation = try self.desktopMutationWatermarkStore.beginMutation(at: startedAt)
            self.durableMutationLeaseCount = 1
        } else {
            self.durableMutationLeaseCount += 1
        }
    }

    func completeDurableMutation(
        through cutoff: Date
    ) throws -> DesktopMutationWatermarkStore.MutationCompletion? {
        guard let pendingDesktopMutation else { return nil }
        if self.durableMutationLeaseCount > 1 {
            self.durableMutationLeaseCount -= 1
            return nil
        }
        let completion = try self.desktopMutationWatermarkStore.completeMutation(
            pendingDesktopMutation,
            through: cutoff
        )
        self.pendingDesktopMutation = nil
        self.durableMutationLeaseCount = 0
        return completion
    }

    func cancelDurableMutation() throws {
        guard let pendingDesktopMutation else { return }
        if self.durableMutationLeaseCount > 1 {
            self.durableMutationLeaseCount -= 1
            return
        }
        try self.desktopMutationWatermarkStore.cancelMutation(pendingDesktopMutation)
        self.pendingDesktopMutation = nil
        self.durableMutationLeaseCount = 0
    }

    func withPendingDurableMutationVisible<T>(
        createdByCurrentCommand: Bool,
        operation: () async throws -> T
    ) async rethrows -> T {
        guard createdByCurrentCommand, let pendingDesktopMutation else {
            return try await operation()
        }
        return try await DesktopMutationWatermarkStore.withPendingMutationVisible(
            pendingDesktopMutation,
            operation: operation
        )
    }

    func invalidationCutoff(commandCompletedAt completion: Date, succeeded: Bool) -> Date? {
        guard self.mutationStartedAt != nil else { return nil }
        if let failedInvalidationCutoff {
            return failedInvalidationCutoff
        }
        if succeeded, let successfulCompletionCutoff {
            return successfulCompletionCutoff
        }
        return completion
    }

    func markInvalidationFailed(through cutoff: Date) {
        guard let mutationStartedAt, mutationStartedAt <= cutoff else { return }
        self.failedInvalidationCutoff = min(self.failedInvalidationCutoff ?? cutoff, cutoff)
    }

    func markInvalidated(through cutoff: Date) {
        guard let mutationStartedAt, mutationStartedAt <= cutoff else { return }
        self.mutationStartedAt = nil
        self.successfulCompletionCutoff = nil
        self.failedInvalidationCutoff = nil
        self.preservedSnapshotID = nil
        self.preservedAt = nil
    }
}

@MainActor
extension InteractionObservationContext {
    @discardableResult
    func invalidateAfterMutation(
        using snapshots: any SnapshotManagerProtocol,
        through cutoff: Date = Date()
    ) async throws -> String? {
        guard source == .latest, let snapshotId else {
            return nil
        }

        guard try await snapshots.invalidateImplicitLatestSnapshot(through: cutoff) != nil else {
            return nil
        }
        return snapshotId
    }

    static func invalidateLatestSnapshot(
        using snapshots: any SnapshotManagerProtocol,
        through cutoff: Date = Date(),
        preserving snapshotId: String? = nil,
        preservedAt: Date? = nil
    ) async throws -> String? {
        try await snapshots.invalidateImplicitLatestSnapshot(
            through: cutoff,
            preserving: snapshotId,
            preservedAt: preservedAt
        )
    }
}

@MainActor
enum InteractionObservationInvalidator {
    struct MutationTargets {
        let snapshots: any SnapshotManagerProtocol
        let selectedRemoteSocketPath: String?
        let remoteSocketPaths: [String]
        let socketExists: (String) -> Bool
        let makeLocalSnapshotManager: () -> any SnapshotManagerProtocol
        let makeRemoteSnapshotManager: (String) async throws -> (any SnapshotManagerProtocol)?
        let mutationTracker: InteractionMutationTracker?

        init(
            snapshots: any SnapshotManagerProtocol,
            selectedRemoteSocketPath: String?,
            remoteSocketPaths: [String],
            socketExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
            makeLocalSnapshotManager: @escaping () -> any SnapshotManagerProtocol = {
                SnapshotManager(desktopMutationWatermarkStore: DesktopMutationWatermarkStore())
            },
            makeRemoteSnapshotManager: @escaping (String) async throws -> (any SnapshotManagerProtocol)? = {
                try await InteractionObservationInvalidator.makeRemoteSnapshotManager(socketPath: $0)
            },
            mutationTracker: InteractionMutationTracker? = nil
        ) {
            self.snapshots = snapshots
            self.selectedRemoteSocketPath = selectedRemoteSocketPath
            self.remoteSocketPaths = remoteSocketPaths
            self.socketExists = socketExists
            self.makeLocalSnapshotManager = makeLocalSnapshotManager
            self.makeRemoteSnapshotManager = makeRemoteSnapshotManager
            self.mutationTracker = mutationTracker
        }
    }

    @discardableResult
    static func invalidateAfterClickMutation(
        targets: MutationTargets,
        logger: Logger,
        reason: String,
        through cutoff: Date = Date()
    ) async -> Bool {
        await self.invalidateAfterMutation(
            targets: targets,
            logger: logger,
            reason: reason,
            through: cutoff
        )
    }

    @discardableResult
    static func invalidateAfterMutation(
        targets: MutationTargets,
        logger: Logger,
        reason: String,
        through cutoff: Date = Date(),
        preserving snapshotId: String? = nil,
        preservedAt: Date? = nil
    ) async -> Bool {
        let succeeded = await invalidateLatestSnapshotsAcrossKnownHosts(
            using: targets.snapshots,
            selectedRemoteSocketPath: targets.selectedRemoteSocketPath,
            remoteSocketPaths: targets.remoteSocketPaths,
            logger: logger,
            reason: reason,
            through: cutoff,
            preserving: snapshotId,
            preservedAt: preservedAt,
            logFailures: targets.mutationTracker?.mutationStartedAt == nil,
            socketExists: targets.socketExists,
            makeLocalSnapshotManager: targets.makeLocalSnapshotManager,
            makeRemoteSnapshotManager: targets.makeRemoteSnapshotManager
        )
        if succeeded {
            targets.mutationTracker?.markInvalidated(through: cutoff)
        } else {
            targets.mutationTracker?.markInvalidationFailed(through: cutoff)
        }
        return succeeded
    }

    @discardableResult
    static func invalidateLatestSnapshotsAcrossKnownHosts(
        using snapshots: any SnapshotManagerProtocol,
        selectedRemoteSocketPath: String?,
        remoteSocketPaths: [String],
        logger: Logger,
        reason: String,
        through cutoff: Date = Date(),
        preserving snapshotId: String? = nil,
        preservedAt: Date? = nil,
        logFailures: Bool = true,
        socketExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        makeLocalSnapshotManager: () -> any SnapshotManagerProtocol = {
            SnapshotManager(desktopMutationWatermarkStore: DesktopMutationWatermarkStore())
        },
        makeRemoteSnapshotManager: (String) async throws -> (any SnapshotManagerProtocol)? = {
            try await InteractionObservationInvalidator.makeRemoteSnapshotManager(socketPath: $0)
        }
    ) async -> Bool {
        var requiredManagers: [any SnapshotManagerProtocol] = [snapshots]
        let selectedPath = selectedRemoteSocketPath.map { NSString(string: $0).standardizingPath }
        if selectedPath != nil {
            requiredManagers.append(makeLocalSnapshotManager())
        }

        let requiredSucceeded = await self.invalidateLatestSnapshots(
            using: requiredManagers,
            logger: logger,
            reason: reason,
            through: cutoff,
            preserving: snapshotId,
            preservedAt: preservedAt,
            logFailures: logFailures
        )

        var alternateManagers: [(path: String, manager: any SnapshotManagerProtocol)] = []
        var seenPaths = Set<String>()
        for rawPath in remoteSocketPaths {
            let path = NSString(string: rawPath).standardizingPath
            guard !path.isEmpty,
                  path != selectedPath,
                  seenPaths.insert(path).inserted,
                  socketExists(path)
            else { continue }
            do {
                if let manager = try await makeRemoteSnapshotManager(path) {
                    alternateManagers.append((path: path, manager: manager))
                }
            } catch {
                if self.isStaleSocketProbeFailure(
                    error,
                    socketPath: path,
                    socketExists: socketExists
                ) {
                    logger.debug(
                        "Skipping stale snapshot invalidation endpoint at \(path) after \(reason)"
                    )
                    continue
                }
                if logFailures {
                    logger.warn(
                        "Skipping unavailable alternate snapshot endpoint at \(path) after \(reason): " +
                            error.localizedDescription
                    )
                } else {
                    logger.debug(
                        "Skipping unavailable alternate snapshot endpoint at \(path) after \(reason)"
                    )
                }
            }
        }

        for alternate in alternateManagers {
            let succeeded = await self.invalidateLatestSnapshot(
                using: alternate.manager,
                logger: logger,
                reason: reason,
                through: cutoff,
                preserving: snapshotId,
                preservedAt: preservedAt,
                logFailures: false
            )
            if !succeeded {
                logger.debug(
                    "Skipping unavailable alternate snapshot endpoint at \(alternate.path) after \(reason)"
                )
            }
        }
        return requiredSucceeded
    }

    private static func isStaleSocketProbeFailure(
        _ error: any Error,
        socketPath: String,
        socketExists: (String) -> Bool
    ) -> Bool {
        guard socketExists(socketPath) else {
            return true
        }
        guard let posixError = error as? POSIXError else {
            return false
        }
        return switch posixError.code {
        case .ECONNREFUSED, .ENOENT, .ENOTSOCK:
            true
        default:
            false
        }
    }

    private static func makeRemoteSnapshotManager(
        socketPath: String
    ) async throws -> (any SnapshotManagerProtocol)? {
        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1)
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: Host.current().name
        )
        let handshake = try await client.handshake(client: identity, requestedHost: nil)
        guard BridgeCapabilityPolicy.supportsImplicitSnapshotInvalidation(for: handshake) else {
            return nil
        }
        return RemoteSnapshotManager(
            client: client,
            supportsImplicitLatestSnapshotInvalidation: true,
            desktopMutationWatermarkStore: DesktopMutationWatermarkStore()
        )
    }

    @discardableResult
    static func invalidateLatestSnapshots(
        using snapshotManagers: [any SnapshotManagerProtocol],
        logger: Logger,
        reason: String,
        through cutoff: Date = Date(),
        preserving snapshotId: String? = nil,
        preservedAt: Date? = nil,
        logFailures: Bool = true
    ) async -> Bool {
        var succeeded = true
        for snapshots in snapshotManagers {
            guard await self.invalidateLatestSnapshot(
                using: snapshots,
                logger: logger,
                reason: reason,
                through: cutoff,
                preserving: snapshotId,
                preservedAt: preservedAt,
                logFailures: logFailures
            ) else {
                succeeded = false
                continue
            }
        }
        return succeeded
    }

    static func invalidateAfterMutation(
        _ observation: InteractionObservationContext,
        snapshots: any SnapshotManagerProtocol,
        logger: Logger,
        reason: String,
        through cutoff: Date = Date()
    ) async {
        do {
            if let invalidatedSnapshotId = try await observation.invalidateAfterMutation(
                using: snapshots,
                through: cutoff
            ) {
                logger.debug(
                    "Invalidated implicit latest snapshot '\(invalidatedSnapshotId)' after \(reason)"
                )
            }
        } catch {
            logger.warn(
                "Failed to invalidate implicit latest snapshot after \(reason): \(error.localizedDescription)"
            )
        }
    }

    static func invalidateAfterMutationOrLatest(
        _ observation: InteractionObservationContext,
        snapshots: any SnapshotManagerProtocol,
        logger: Logger,
        reason: String,
        through cutoff: Date = Date()
    ) async {
        switch observation.source {
        case .explicit:
            return
        case .latest:
            await self.invalidateAfterMutation(
                observation,
                snapshots: snapshots,
                logger: logger,
                reason: reason,
                through: cutoff
            )
        case .none:
            await self.invalidateLatestSnapshot(
                using: snapshots,
                logger: logger,
                reason: reason,
                through: cutoff
            )
        }
    }

    @discardableResult
    static func invalidateLatestSnapshot(
        using snapshots: any SnapshotManagerProtocol,
        logger: Logger,
        reason: String,
        through cutoff: Date = Date(),
        preserving snapshotId: String? = nil,
        preservedAt: Date? = nil,
        logFailures: Bool = true
    ) async -> Bool {
        do {
            if let invalidatedSnapshotId = try await InteractionObservationContext.invalidateLatestSnapshot(
                using: snapshots,
                through: cutoff,
                preserving: snapshotId,
                preservedAt: preservedAt
            ) {
                logger.debug(
                    "Invalidated implicit latest snapshot '\(invalidatedSnapshotId)' after \(reason)"
                )
            }
            return true
        } catch {
            if logFailures {
                logger.warn(
                    "Failed to invalidate latest snapshot after \(reason): \(error.localizedDescription)"
                )
            }
            return false
        }
    }
}

@MainActor
extension CommandRuntime {
    func withCaptureFocusMutation(
        _ operation: () async throws -> Void
    ) async rethrows {
        self.beginInteractionMutation()
        try await operation()
        self.beginInteractionMutation(preservingSnapshotsCreatedAfterBoundary: true)
    }

    @discardableResult
    func beginInteractionMutation(
        at cutoff: Date = Date(),
        preservingSnapshotsCreatedAfterBoundary: Bool = false
    ) -> Date {
        interactionMutationTracker.begin(
            at: cutoff,
            preservingSnapshotsCreatedAfterBoundary: preservingSnapshotsCreatedAfterBoundary
        )
    }

    func preserveFreshObservation(
        snapshotId: String,
        startedAt: Date,
        preservedAt: Date,
        preservationAllowed: Bool = true
    ) {
        interactionMutationTracker.preserveFreshObservation(
            snapshotId: snapshotId,
            startedAt: startedAt,
            preservedAt: preservedAt,
            preservationAllowed: preservationAllowed
        )
    }

    var interactionMutationTargets: InteractionObservationInvalidator.MutationTargets {
        .init(
            snapshots: services.snapshots,
            selectedRemoteSocketPath: selectedRemoteSocketPath,
            remoteSocketPaths: snapshotInvalidationRemoteSocketPaths,
            mutationTracker: interactionMutationTracker
        )
    }

    var toolSnapshotMutationCoordinator: any MCPToolSnapshotMutationCoordinating {
        RuntimeMCPToolSnapshotMutationCoordinator(
            targets: .init(
                snapshots: services.snapshots,
                selectedRemoteSocketPath: selectedRemoteSocketPath,
                remoteSocketPaths: snapshotInvalidationRemoteSocketPaths
            ),
            logger: logger,
            mutationTracker: interactionMutationTracker
        )
    }
}

@MainActor
private final class RuntimeMCPToolSnapshotMutationCoordinator: MCPToolSnapshotMutationCoordinating {
    private let targets: InteractionObservationInvalidator.MutationTargets
    private let logger: Logger
    private let mutationTracker: InteractionMutationTracker
    private let hasRemoteSelection: Bool
    private var preparedLocalMutationIDs: Set<UUID> = []
    private var completedPreparedMutationIDs: Set<UUID> = []

    init(
        targets: InteractionObservationInvalidator.MutationTargets,
        logger: Logger,
        mutationTracker: InteractionMutationTracker
    ) {
        self.targets = targets
        self.logger = logger
        self.mutationTracker = mutationTracker
        self.hasRemoteSelection = targets.selectedRemoteSocketPath != nil
    }

    func prepareMutation(_ scope: MCPToolSnapshotMutationScope) throws {
        guard scope.effect != .freshObservation else { return }
        let needsCallerBarrier = !self.hasRemoteSelection || scope.effect != .mutationProducingFreshObservation
        if needsCallerBarrier {
            guard try self.mutationTracker.beginDurableMutation(at: scope.startedAt) else {
                throw PeekabooError.operationError(
                    message: "A previous local desktop mutation barrier is still pending"
                )
            }
            self.preparedLocalMutationIDs.insert(scope.id)
        }
        self.mutationTracker.begin(
            at: scope.startedAt,
            preservingSnapshotsCreatedAfterBoundary: scope.effect == .mutationProducingFreshObservation
        )
    }

    func completeMutationBarrier(
        _ scope: MCPToolSnapshotMutationScope
    ) throws -> MCPToolMutationBarrierCompletion? {
        guard self.preparedLocalMutationIDs.contains(scope.id) else { return nil }
        let completion = try self.mutationTracker.completeDurableMutation(
            through: scope.completedAt ?? Date()
        )
        self.preparedLocalMutationIDs.remove(scope.id)
        self.completedPreparedMutationIDs.insert(scope.id)
        return completion.map {
            MCPToolMutationBarrierCompletion(
                cutoff: $0.cutoff,
                allowsObservationPreservation: $0.allowsObservationPreservation
            )
        }
    }

    @discardableResult
    func completeMutation(_ scope: MCPToolSnapshotMutationScope, succeeded: Bool) async -> Bool {
        let completedPreparedMutation = self.completedPreparedMutationIDs.remove(scope.id) != nil
        // `see` must observe publication failure before rendering its fresh snapshot.
        let defersToOuterCommandBarrier = !self.hasRemoteSelection &&
            scope.effect == .mutationProducingFreshObservation &&
            scope.toolName != "see" &&
            !completedPreparedMutation &&
            self.mutationTracker.hasPendingDurableMutation
        if defersToOuterCommandBarrier {
            if succeeded,
               let preservedSnapshotID = scope.preservedSnapshotID,
               let completedAt = scope.completedAt {
                self.mutationTracker.preserveFreshObservation(
                    snapshotId: preservedSnapshotID,
                    startedAt: scope.confirmedMutationCompletedAt ?? scope.startedAt,
                    preservedAt: completedAt
                )
            }
            return true
        }

        let sharedWatermark = self.targets.snapshots.effectiveImplicitLatestInvalidationWatermark
        let wantsPreservation = succeeded &&
            scope.effect == .mutationProducingFreshObservation &&
            scope.preservedSnapshotID != nil
        let preservationBoundary = scope.confirmedMutationCompletedAt ?? scope.startedAt
        let publicationAllowed = !wantsPreservation ||
            ((scope.observationPreservationAllowed ?? true) &&
                (sharedWatermark.map { $0 <= preservationBoundary } ?? true))
        let effectiveSucceeded = succeeded && publicationAllowed
        let requestedCutoff = scope.invalidationCutoff(succeeded: effectiveSucceeded)
        let cutoff = max(requestedCutoff, sharedWatermark ?? requestedCutoff)
        let preservedSnapshotID = effectiveSucceeded ? scope.preservedSnapshotID : nil
        if let preservedSnapshotID, let completedAt = scope.completedAt {
            self.mutationTracker.preserveFreshObservation(
                snapshotId: preservedSnapshotID,
                startedAt: cutoff,
                preservedAt: completedAt
            )
        }
        let invalidated = await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: self.targets,
            logger: self.logger,
            reason: "\(scope.toolName) tool execution",
            through: cutoff,
            preserving: preservedSnapshotID,
            preservedAt: preservedSnapshotID == nil ? nil : scope.completedAt
        )
        if !invalidated {
            let retried = await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.targets,
                logger: self.logger,
                reason: "\(scope.toolName) tool execution retry",
                through: cutoff,
                preserving: preservedSnapshotID,
                preservedAt: preservedSnapshotID == nil ? nil : scope.completedAt
            )
            return retried && (!succeeded || effectiveSucceeded)
        }
        return !succeeded || effectiveSucceeded
    }
}
