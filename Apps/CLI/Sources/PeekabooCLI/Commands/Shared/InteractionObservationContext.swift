import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

enum InteractionSnapshotSource: String {
    case explicit
    case latest
    case none
}

/// Why implicit "latest snapshot" resolution came back empty.
enum InteractionSnapshotUnavailability {
    /// No usable snapshot exists at all (never captured, expired, or cleaned).
    case noSnapshotCaptured
    /// Snapshots exist on disk but the newest one sits at or below the invalidation watermark,
    /// i.e. an earlier desktop mutation (such as a click) marked it stale.
    case invalidatedByMutation
}

@MainActor
struct InteractionObservationContext {
    let explicitSnapshotId: String?
    let snapshotId: String?
    let source: InteractionSnapshotSource
    let unavailability: InteractionSnapshotUnavailability?

    init(
        explicitSnapshotId: String?,
        snapshotId: String?,
        source: InteractionSnapshotSource,
        unavailability: InteractionSnapshotUnavailability? = nil
    ) {
        self.explicitSnapshotId = explicitSnapshotId
        self.snapshotId = snapshotId
        self.source = source
        self.unavailability = unavailability
    }

    var hasSnapshot: Bool {
        self.snapshotId != nil
    }

    func focusSnapshotId(for target: InteractionTargetOptions) -> String? {
        if self.source == .explicit || !target.hasAnyTarget {
            return self.snapshotId
        }
        return nil
    }

    func requireSnapshot() throws -> String {
        guard let snapshotId else {
            throw self.snapshotUnavailableError()
        }
        return snapshotId
    }

    /// Distinguishes "nothing was ever captured" from "the latest snapshot was invalidated by a
    /// prior desktop mutation" so the failure is actionable instead of a misleading not-found.
    func snapshotUnavailableError() -> PeekabooError {
        switch self.unavailability {
        case .invalidatedByMutation:
            .snapshotStale(
                "the most recent UI snapshot was invalidated because an earlier command changed the desktop"
            )
        case .noSnapshotCaptured, nil:
            .snapshotNotAvailable(
                "No UI snapshot is available. Run 'peekaboo see' first to capture the current screen."
            )
        }
    }

    func validateIfExplicit(using snapshots: any SnapshotManagerProtocol) async throws {
        if let explicitSnapshotId {
            _ = try await SnapshotValidation.requireDetectionResult(
                snapshotId: explicitSnapshotId,
                snapshots: snapshots
            )
        }
    }

    func requireDetectionResult(using snapshots: any SnapshotManagerProtocol) async throws -> ElementDetectionResult {
        let snapshotId = try self.requireSnapshot()
        return try await SnapshotValidation.requireDetectionResult(snapshotId: snapshotId, snapshots: snapshots)
    }

    static func resolve(
        explicitSnapshot rawSnapshot: String?,
        fallbackToLatest: Bool,
        snapshots: any SnapshotManagerProtocol
    ) async -> InteractionObservationContext {
        if let explicitSnapshotId = normalizedSnapshotId(rawSnapshot) {
            guard self.isLatestAlias(explicitSnapshotId) else {
                return InteractionObservationContext(
                    explicitSnapshotId: explicitSnapshotId,
                    snapshotId: explicitSnapshotId,
                    source: .explicit
                )
            }
            return await self.latestSnapshotContext(from: snapshots)
        }

        guard fallbackToLatest else {
            return InteractionObservationContext(
                explicitSnapshotId: nil,
                snapshotId: nil,
                source: .none
            )
        }

        return await self.latestSnapshotContext(from: snapshots)
    }

    private static func latestSnapshotContext(from snapshots: any SnapshotManagerProtocol) async
    -> InteractionObservationContext {
        if let latestSnapshotId = await snapshots.getMostRecentSnapshot() {
            return InteractionObservationContext(
                explicitSnapshotId: nil,
                snapshotId: latestSnapshotId,
                source: .latest
            )
        }

        return await InteractionObservationContext(
            explicitSnapshotId: nil,
            snapshotId: nil,
            source: .none,
            unavailability: self.latestSnapshotUnavailability(from: snapshots)
        )
    }

    private static func latestSnapshotUnavailability(
        from snapshots: any SnapshotManagerProtocol
    ) async -> InteractionSnapshotUnavailability {
        // `listSnapshots` ignores the invalidation watermark, so snapshots that exist there but did
        // not resolve as "latest" were hidden by a prior mutation rather than missing.
        guard let watermark = snapshots.effectiveImplicitLatestInvalidationWatermark,
              let newestCreatedAt = await (try? snapshots.listSnapshots())?.map(\.createdAt).max(),
              newestCreatedAt <= watermark
        else {
            return .noSnapshotCaptured
        }
        return .invalidatedByMutation
    }

    private static func normalizedSnapshotId(_ snapshotId: String?) -> String? {
        let trimmed = snapshotId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func isLatestAlias(_ snapshotId: String) -> Bool {
        switch snapshotId.lowercased() {
        case "latest", "most-recent", "most_recent":
            true
        default:
            false
        }
    }
}

@MainActor
struct InteractionObservationRefreshDependencies {
    let desktopObservation: any DesktopObservationServiceProtocol
    let snapshots: any SnapshotManagerProtocol
    let beginMutation: ((Date) -> Void)?

    init(
        desktopObservation: any DesktopObservationServiceProtocol,
        snapshots: any SnapshotManagerProtocol,
        beginMutation: ((Date) -> Void)? = nil
    ) {
        self.desktopObservation = desktopObservation
        self.snapshots = snapshots
        self.beginMutation = beginMutation
    }
}

@MainActor
enum InteractionObservationRefresher {
    static func refreshForMissingElementsIfNeeded(
        _ observation: InteractionObservationContext,
        elementIds: [String?],
        target: InteractionTargetOptions,
        services: any PeekabooServiceProviding,
        logger: Logger,
        beforeRefresh: ((Date) -> Void)? = nil
    ) async throws -> InteractionObservationContext {
        var refreshed = observation
        for elementId in elementIds.compactMap(\.self) {
            refreshed = try await self.refreshForMissingElementIfNeeded(
                refreshed,
                elementId: elementId,
                target: target,
                services: services,
                logger: logger,
                beforeRefresh: beforeRefresh
            )
        }
        return refreshed
    }

    static func refreshForMissingQueryIfNeeded(
        _ observation: InteractionObservationContext,
        query: String,
        target: InteractionTargetOptions,
        services: any PeekabooServiceProviding,
        logger: Logger,
        beforeRefresh: ((Date) -> Void)? = nil
    ) async throws -> InteractionObservationContext {
        try await self.refreshForMissingQueryIfNeeded(
            observation,
            query: query,
            target: target,
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: services.desktopObservation,
                snapshots: services.snapshots,
                beginMutation: beforeRefresh
            ),
            logger: logger
        )
    }

    static func refreshForMissingQueryIfNeeded(
        _ observation: InteractionObservationContext,
        query: String,
        target: InteractionTargetOptions,
        dependencies: InteractionObservationRefreshDependencies,
        logger: Logger
    ) async throws -> InteractionObservationContext {
        guard observation.source == .latest else {
            return observation
        }

        if let snapshotId = observation.snapshotId,
           let detectionResult = try await dependencies.snapshots.getDetectionResult(snapshotId: snapshotId),
           containsElement(matching: query, in: detectionResult) {
            return observation
        }

        return try await self.refreshObservation(
            observation,
            reason: "missing query '\(query)'",
            target: target,
            dependencies: dependencies,
            logger: logger
        )
    }

    static func refreshForMissingElementIfNeeded(
        _ observation: InteractionObservationContext,
        elementId: String,
        target: InteractionTargetOptions,
        services: any PeekabooServiceProviding,
        logger: Logger,
        beforeRefresh: ((Date) -> Void)? = nil
    ) async throws -> InteractionObservationContext {
        try await self.refreshForMissingElementIfNeeded(
            observation,
            elementId: elementId,
            target: target,
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: services.desktopObservation,
                snapshots: services.snapshots,
                beginMutation: beforeRefresh
            ),
            logger: logger
        )
    }

    static func refreshForMissingElementIfNeeded(
        _ observation: InteractionObservationContext,
        elementId: String,
        target: InteractionTargetOptions,
        dependencies: InteractionObservationRefreshDependencies,
        logger: Logger
    ) async throws -> InteractionObservationContext {
        guard observation.source != .explicit else {
            return observation
        }

        if let snapshotId = observation.snapshotId,
           let detectionResult = try await dependencies.snapshots.getDetectionResult(snapshotId: snapshotId),
           detectionResult.elements.findById(elementId) != nil {
            return observation
        }

        return try await self.refreshObservation(
            observation,
            reason: "missing element '\(elementId)'",
            target: target,
            dependencies: dependencies,
            logger: logger
        )
    }

    private static func refreshObservation(
        _ observation: InteractionObservationContext,
        reason: String,
        target: InteractionTargetOptions,
        dependencies: InteractionObservationRefreshDependencies,
        logger: Logger
    ) async throws -> InteractionObservationContext {
        let requestTarget = try target.observationTargetRequest()
        let observationStartedAt = Date()
        dependencies.beginMutation?(observationStartedAt)
        let snapshotID = try await dependencies.snapshots.createSnapshot(pendingAt: observationStartedAt)
        let result: DesktopObservationResult
        do {
            result = try await dependencies.desktopObservation.observe(DesktopObservationRequest(
                target: requestTarget,
                capture: DesktopCaptureOptions(
                    engine: .auto,
                    scale: .logical1x,
                    visualizerMode: .screenshotFlash
                ),
                detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: true),
                output: DesktopObservationOutputOptions(
                    saveSnapshot: true,
                    snapshotID: snapshotID
                )
            ))
            guard result.elements != nil else {
                try? await dependencies.snapshots.cleanSnapshot(snapshotId: snapshotID)
                _ = try? await dependencies.snapshots.invalidateImplicitLatestSnapshot(through: Date())
                return observation
            }
            let publication = try self.certifiedPublicationBoundary(
                for: result,
                observationStartedAt: observationStartedAt
            )
            _ = try await dependencies.snapshots.invalidateImplicitLatestSnapshot(
                through: publication.cutoff,
                preserving: snapshotID,
                preservedAt: publication.preservedAt
            )
            guard await dependencies.snapshots.getMostRecentSnapshot() == snapshotID else {
                throw PeekabooError.snapshotStale(
                    "The refreshed observation was superseded before it could be published"
                )
            }
        } catch {
            if !PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: error) {
                try? await dependencies.snapshots.cleanSnapshot(snapshotId: snapshotID)
            }
            _ = try? await dependencies.snapshots.invalidateImplicitLatestSnapshot(through: Date())
            throw error
        }

        logger.debug(
            "Refreshed implicit observation snapshot '\(snapshotID)' for \(reason)"
        )
        return InteractionObservationContext(
            explicitSnapshotId: nil,
            snapshotId: snapshotID,
            source: .latest
        )
    }

    private static func certifiedPublicationBoundary(
        for result: DesktopObservationResult,
        observationStartedAt: Date
    ) throws -> (cutoff: Date, preservedAt: Date) {
        let completedAtValues = [
            result.diagnostics.desktopMutationCompletedAt,
            result.elements?.metadata.desktopMutationCompletedAt,
        ].compactMap(\.self)
        let preservationValues = [
            result.diagnostics.desktopMutationPreservationAllowed,
            result.elements?.metadata.desktopMutationPreservationAllowed,
        ].compactMap(\.self)
        let hasCertificate = !completedAtValues.isEmpty || !preservationValues.isEmpty
        guard hasCertificate else { return (observationStartedAt, Date()) }
        guard let completedAt = completedAtValues.max(),
              !preservationValues.isEmpty,
              preservationValues.allSatisfy(\.self)
        else {
            throw PeekabooError.snapshotStale(
                "The refreshed observation overlapped another desktop mutation"
            )
        }
        let cutoff = max(observationStartedAt, completedAt)
        return (cutoff, cutoff)
    }

    private static func containsElement(
        matching query: String,
        in detectionResult: ElementDetectionResult
    ) -> Bool {
        let queryLower = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !queryLower.isEmpty else { return false }

        return detectionResult.elements.all.contains { element in
            guard element.isEnabled else { return false }
            let candidates = [
                element.id,
                element.label,
                element.value,
                element.attributes["identifier"],
                element.attributes["title"],
                element.attributes["description"],
                element.attributes["role"],
                element.type.rawValue,
            ].compactMap { $0?.lowercased() }

            return candidates.contains { $0.contains(queryLower) }
        }
    }
}

extension InteractionTargetOptions {
    func observationTargetRequest() throws -> DesktopObservationTargetRequest {
        if let windowId {
            return .windowID(CGWindowID(windowId))
        }

        let windowSelection: WindowSelection? = if let windowTitle {
            .title(windowTitle)
        } else if let windowIndex {
            .index(windowIndex)
        } else {
            nil
        }

        if let pid {
            return .pid(pid, window: windowSelection)
        }

        if let app {
            return .app(identifier: app, window: windowSelection)
        }

        return .frontmost
    }
}
