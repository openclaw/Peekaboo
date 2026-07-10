import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
enum InteractionTargetPointResolver {
    static func elementCenterResolution(
        element: DetectedElement,
        elementId: String,
        snapshotId: String?,
        snapshots: any SnapshotManagerProtocol
    ) async throws -> InteractionTargetPointResolution {
        let originalPoint = CGPoint(x: element.bounds.midX, y: element.bounds.midY)
        return try await self.resolve(
            originalPoint: originalPoint,
            source: .element,
            elementId: elementId,
            snapshotId: snapshotId,
            snapshots: snapshots
        )
    }

    static func elementCenter(
        elementId: String,
        snapshotId: String?,
        snapshots: any SnapshotManagerProtocol
    ) async throws -> CGPoint? {
        guard let snapshotId,
              let detectionResult = try await snapshots.getDetectionResult(snapshotId: snapshotId),
              let element = detectionResult.elements.findById(elementId)
        else {
            return nil
        }

        return try await self.elementCenterResolution(
            element: element,
            elementId: elementId,
            snapshotId: snapshotId,
            snapshots: snapshots
        ).point
    }

    static func coordinate(
        _ point: CGPoint,
        source: InteractionTargetPointSource
    ) -> InteractionTargetPointResolution {
        InteractionTargetPointResolution(
            point: point,
            diagnostics: InteractionTargetPointDiagnostics(
                source: source.rawValue,
                elementId: nil,
                snapshotId: nil,
                original: InteractionPoint(point),
                resolved: InteractionPoint(point),
                windowAdjustment: nil
            )
        )
    }

    static func elementOrCoordinateResolution(
        _ request: InteractionTargetPointRequest,
        services: any PeekabooServiceProviding
    ) async throws -> InteractionTargetPointResolution {
        if let coordinateString = request.coordinates {
            return try self.parsedCoordinateResolution(coordinateString)
        }

        guard let elementId = request.elementId else {
            throw Commander.ValidationError("No \(request.description) point specified")
        }

        guard let snapshotId = request.snapshotId else {
            throw PeekabooError.snapshotNotAvailable(
                """
                No UI snapshot is available to resolve the \(request.description) element \
                '\(elementId)'. Run 'peekaboo see' first, or pass coordinates instead.
                """
            )
        }

        // Validate the snapshot before waiting so stale/missing snapshot diagnostics stay explicit.
        _ = try await SnapshotValidation.requireDetectionResult(
            snapshotId: snapshotId,
            snapshots: services.snapshots
        )

        let waitResult = try await AutomationServiceBridge.waitForElement(
            automation: services.automation,
            target: .elementId(elementId),
            timeout: request.waitTimeout,
            snapshotId: snapshotId
        )

        guard waitResult.found else {
            throw PeekabooError.elementNotFound("Element with ID '\(elementId)' not found")
        }

        guard let foundElement = waitResult.element else {
            throw PeekabooError.elementNotFound("Element '\(elementId)' found but has no bounds")
        }

        return try await self.elementCenterResolution(
            element: foundElement,
            elementId: elementId,
            snapshotId: snapshotId,
            snapshots: services.snapshots
        )
    }

    private static func parsedCoordinateResolution(_ coordinateString: String) throws
    -> InteractionTargetPointResolution {
        let components = coordinateString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard components.count == 2,
              let x = Double(components[0]),
              let y = Double(components[1])
        else {
            throw Commander.ValidationError("Invalid coordinates format: '\(coordinateString)'. Expected 'x,y'")
        }

        return self.coordinate(
            CGPoint(x: x, y: y),
            source: .coordinates
        )
    }

    private static func resolve(
        originalPoint: CGPoint,
        source: InteractionTargetPointSource,
        elementId: String?,
        snapshotId: String?,
        snapshots: any SnapshotManagerProtocol
    ) async throws -> InteractionTargetPointResolution {
        guard let snapshotId,
              let snapshot = try await snapshots.getUIAutomationSnapshot(snapshotId: snapshotId)
        else {
            return InteractionTargetPointResolution(
                point: originalPoint,
                diagnostics: InteractionTargetPointDiagnostics(
                    source: source.rawValue,
                    elementId: elementId,
                    snapshotId: snapshotId,
                    original: InteractionPoint(originalPoint),
                    resolved: InteractionPoint(originalPoint),
                    windowAdjustment: nil
                )
            )
        }

        // Keep diagnostics next to the same movement-adjustment decision used by execution.
        switch WindowMovementTracking.adjustPoint(originalPoint, snapshot: snapshot) {
        case let .unchanged(point):
            return InteractionTargetPointResolution(
                point: point,
                diagnostics: InteractionTargetPointDiagnostics(
                    source: source.rawValue,
                    elementId: elementId,
                    snapshotId: snapshotId,
                    original: InteractionPoint(originalPoint),
                    resolved: InteractionPoint(point),
                    windowAdjustment: InteractionWindowAdjustmentDiagnostics(
                        status: "unchanged",
                        delta: nil
                    )
                )
            )
        case let .adjusted(point, delta):
            return InteractionTargetPointResolution(
                point: point,
                diagnostics: InteractionTargetPointDiagnostics(
                    source: source.rawValue,
                    elementId: elementId,
                    snapshotId: snapshotId,
                    original: InteractionPoint(originalPoint),
                    resolved: InteractionPoint(point),
                    windowAdjustment: InteractionWindowAdjustmentDiagnostics(
                        status: "adjusted",
                        delta: InteractionPoint(delta)
                    )
                )
            )
        case let .stale(message):
            throw PeekabooError.snapshotStale(message)
        }
    }
}

enum InteractionTargetPointSource: String {
    case element
    case coordinates
    case screenCenter = "screen_center"
    case application
    case pointer
}

struct InteractionTargetPointResolution {
    let point: CGPoint
    let diagnostics: InteractionTargetPointDiagnostics
}

struct InteractionTargetPointRequest {
    let elementId: String?
    let coordinates: String?
    let snapshotId: String?
    let description: String
    let waitTimeout: TimeInterval
}

struct InteractionTargetPointDiagnostics: Codable, Equatable {
    let source: String
    let elementId: String?
    let snapshotId: String?
    let original: InteractionPoint
    let resolved: InteractionPoint
    let windowAdjustment: InteractionWindowAdjustmentDiagnostics?
    let coordinate: InteractionCoordinateDiagnostics?

    init(
        source: String,
        elementId: String?,
        snapshotId: String?,
        original: InteractionPoint,
        resolved: InteractionPoint,
        windowAdjustment: InteractionWindowAdjustmentDiagnostics?,
        coordinate: InteractionCoordinateDiagnostics? = nil
    ) {
        self.source = source
        self.elementId = elementId
        self.snapshotId = snapshotId
        self.original = original
        self.resolved = resolved
        self.windowAdjustment = windowAdjustment
        self.coordinate = coordinate
    }
}

struct InteractionWindowAdjustmentDiagnostics: Codable, Equatable {
    let status: String
    let delta: InteractionPoint?
}

struct InteractionPoint: Codable, Equatable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        self.x = Double(point.x)
        self.y = Double(point.y)
    }
}
