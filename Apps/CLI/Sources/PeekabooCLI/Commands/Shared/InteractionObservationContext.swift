import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

enum InteractionSnapshotSource: String {
    case explicit
    case latest
    case none
}

@MainActor
struct InteractionObservationContext {
    let explicitSnapshotId: String?
    let snapshotId: String?
    let source: InteractionSnapshotSource

    var hasSnapshot: Bool {
        self.snapshotId != nil
    }

    func focusSnapshotId(for target: InteractionTargetOptions) -> String? {
        if self.source == .explicit || !target.hasAnyTarget {
            return self.snapshotId
        }
        return nil
    }

    func requireSnapshot(message: String = "No snapshot found") throws -> String {
        guard let snapshotId else {
            throw PeekabooError.snapshotNotFound(message)
        }
        return snapshotId
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

        return InteractionObservationContext(explicitSnapshotId: nil, snapshotId: nil, source: .none)
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
}

@MainActor
enum InteractionObservationRefresher {
    static func refreshForMissingElementsIfNeeded(
        _ observation: InteractionObservationContext,
        elementIds: [String?],
        target: InteractionTargetOptions,
        services: any PeekabooServiceProviding,
        logger: Logger
    ) async throws -> InteractionObservationContext {
        var refreshed = observation
        for elementId in elementIds.compactMap(\.self) {
            refreshed = try await self.refreshForMissingElementIfNeeded(
                refreshed,
                elementId: elementId,
                target: target,
                services: services,
                logger: logger
            )
        }
        return refreshed
    }

    static func refreshForMissingQueryIfNeeded(
        _ observation: InteractionObservationContext,
        query: String,
        target: InteractionTargetOptions,
        services: any PeekabooServiceProviding,
        logger: Logger
    ) async throws -> InteractionObservationContext {
        try await self.refreshForMissingQueryIfNeeded(
            observation,
            query: query,
            target: target,
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: services.desktopObservation,
                snapshots: services.snapshots
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
        logger: Logger
    ) async throws -> InteractionObservationContext {
        try await self.refreshForMissingElementIfNeeded(
            observation,
            elementId: elementId,
            target: target,
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: services.desktopObservation,
                snapshots: services.snapshots
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
        let result = try await dependencies.desktopObservation.observe(DesktopObservationRequest(
            target: requestTarget,
            capture: DesktopCaptureOptions(
                engine: .auto,
                scale: .logical1x,
                visualizerMode: .screenshotFlash
            ),
            detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: true),
            output: DesktopObservationOutputOptions(saveSnapshot: true)
        ))

        guard let refreshedSnapshotId = result.elements?.snapshotId else {
            return observation
        }

        logger.debug(
            "Refreshed implicit observation snapshot '\(refreshedSnapshotId)' for \(reason)"
        )
        return InteractionObservationContext(
            explicitSnapshotId: nil,
            snapshotId: refreshedSnapshotId,
            source: .latest
        )
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
