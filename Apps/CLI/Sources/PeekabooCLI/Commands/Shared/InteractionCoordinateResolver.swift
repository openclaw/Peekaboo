import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
enum InteractionCoordinateResolver {
    static func resolveClickCoordinates(
        _ inputPoint: CGPoint,
        target: InteractionTargetOptions,
        services: any PeekabooServiceProviding,
        forceGlobal: Bool = false
    ) async throws -> InteractionCoordinateResolution {
        guard target.hasAnyTarget else {
            return InteractionCoordinateResolution(
                inputPoint: inputPoint,
                screenPoint: inputPoint,
                coordinateSpace: .global,
                windowInfo: nil,
                targetApplication: nil
            )
        }

        let hasWindowSelector = target.windowId != nil || target.windowTitle != nil || target.windowIndex != nil
        if forceGlobal, !hasWindowSelector {
            return InteractionCoordinateResolution(
                inputPoint: inputPoint,
                screenPoint: inputPoint,
                coordinateSpace: .global,
                windowInfo: nil,
                targetApplication: nil
            )
        }

        let windowResolution = try await self.resolveTargetWindow(target: target, services: services)

        return try self.resolveTargetWindowCoordinates(
            inputPoint,
            windowInfo: windowResolution.windowInfo,
            targetApplication: windowResolution.targetApplication,
            forceGlobal: forceGlobal
        )
    }

    static func resolveTargetWindow(
        target: InteractionTargetOptions,
        services: any PeekabooServiceProviding
    ) async throws -> InteractionWindowResolution {
        guard let windowTarget = try target.toWindowTarget() else {
            throw ValidationError("Window target could not be resolved from the supplied target options.")
        }

        let windowInfo = try await self.resolveWindowInfo(
            windowTarget: windowTarget,
            target: target,
            services: services
        )
        let targetApplication = try await self.resolveTargetApplication(
            windowInfo: windowInfo,
            target: target,
            services: services
        )
        return InteractionWindowResolution(windowInfo: windowInfo, targetApplication: targetApplication)
    }

    static func resolveTargetWindowCoordinates(
        _ inputPoint: CGPoint,
        windowInfo: ServiceWindowInfo?,
        targetApplication: ServiceApplicationInfo?,
        forceGlobal: Bool = false
    ) throws -> InteractionCoordinateResolution {
        guard let windowInfo else {
            return InteractionCoordinateResolution(
                inputPoint: inputPoint,
                screenPoint: inputPoint,
                coordinateSpace: .global,
                windowInfo: nil,
                targetApplication: nil
            )
        }

        if forceGlobal {
            return InteractionCoordinateResolution(
                inputPoint: inputPoint,
                screenPoint: inputPoint,
                coordinateSpace: .global,
                windowInfo: windowInfo,
                targetApplication: targetApplication
            )
        }

        try self.validate(inputPoint: inputPoint, within: windowInfo)

        let screenPoint = CGPoint(
            x: windowInfo.bounds.minX + inputPoint.x,
            y: windowInfo.bounds.minY + inputPoint.y
        )

        return InteractionCoordinateResolution(
            inputPoint: inputPoint,
            screenPoint: screenPoint,
            coordinateSpace: .windowRelative,
            windowInfo: windowInfo,
            targetApplication: targetApplication
        )
    }

    private static func resolveWindowInfo(
        windowTarget: WindowTarget,
        target: InteractionTargetOptions,
        services: any PeekabooServiceProviding
    ) async throws -> ServiceWindowInfo {
        let windows = try await services.windows.listWindows(target: windowTarget)
        guard let window = ObservationTargetResolver.bestWindow(from: windows) else {
            throw PeekabooError.windowNotFound(criteria: self.targetDescription(target))
        }
        return window
    }

    private static func validate(inputPoint: CGPoint, within windowInfo: ServiceWindowInfo) throws {
        guard inputPoint.x >= 0, inputPoint.y >= 0,
              inputPoint.x < windowInfo.bounds.width,
              inputPoint.y < windowInfo.bounds.height
        else {
            let x = Self.clean(inputPoint.x)
            let y = Self.clean(inputPoint.y)
            let width = Self.clean(windowInfo.bounds.width)
            let height = Self.clean(windowInfo.bounds.height)
            throw ValidationError(
                "Coordinates \(x),\(y) are outside target window \(windowInfo.windowID) " +
                    "bounds 0,0-\(width),\(height). Use --global-coords for screen coordinates."
            )
        }
    }

    private static func resolveTargetApplication(
        windowInfo: ServiceWindowInfo,
        target: InteractionTargetOptions,
        services: any PeekabooServiceProviding
    ) async throws -> ServiceApplicationInfo? {
        if let identifier = try target.resolveApplicationIdentifierOptional() {
            let application = try await services.applications.findApplication(identifier: identifier)
            if target.windowId != nil {
                let applicationWindows = try await services.windows.listWindows(
                    target: .application("PID:\(application.processIdentifier)")
                )
                try self.validateWindowOwnership(
                    windowInfo: windowInfo,
                    application: application,
                    applicationWindows: applicationWindows
                )
            }
            return application
        }

        guard let output = try? await services.applications.listApplications() else {
            return nil
        }

        for application in output.data.applications {
            let identifiers = [
                application.name,
                application.bundleIdentifier,
                "PID:\(application.processIdentifier)",
            ].compactMap(\.self)

            for identifier in identifiers {
                guard let windows = try? await services.windows.listWindows(target: .application(identifier)),
                      windows.contains(where: { $0.windowID == windowInfo.windowID })
                else { continue }
                return application
            }
        }

        return nil
    }

    static func validateWindowOwnership(
        windowInfo: ServiceWindowInfo,
        application: ServiceApplicationInfo,
        applicationWindows: [ServiceWindowInfo]
    ) throws {
        guard applicationWindows.contains(where: { $0.windowID == windowInfo.windowID }) else {
            throw ValidationError(
                "Window \(windowInfo.windowID) does not belong to \(application.name) " +
                    "(PID \(application.processIdentifier))"
            )
        }
    }

    private static func targetDescription(_ target: InteractionTargetOptions) -> String {
        if let windowId = target.windowId {
            return "window id \(windowId)"
        }
        if let windowTitle = target.windowTitle {
            return "window title '\(windowTitle)'"
        }
        if let windowIndex = target.windowIndex {
            return "window index \(windowIndex)"
        }
        if let pid = target.pid {
            return "PID \(pid)"
        }
        if let app = target.app {
            return "app '\(app)'"
        }
        return "target"
    }

    private static func clean(_ value: CGFloat) -> String {
        let doubleValue = Double(value)
        if doubleValue.rounded() == doubleValue {
            return String(Int(doubleValue))
        }
        return String(format: "%.2f", doubleValue)
    }
}

struct InteractionWindowResolution {
    let windowInfo: ServiceWindowInfo
    let targetApplication: ServiceApplicationInfo?

    var targetProcessIdentifier: Int32? {
        self.targetApplication?.processIdentifier
    }
}

enum InteractionWindowSelectionValidator {
    static func validate(
        resolution: InteractionWindowResolution,
        snapshotContext: WindowContext?,
        snapshotId: String
    ) throws {
        guard let snapshotWindowID = snapshotContext?.windowID else {
            throw ValidationError(
                "Snapshot '\(snapshotId)' does not identify an exact window; " +
                    "capture a fresh snapshot for the selected window"
            )
        }

        guard snapshotWindowID == resolution.windowInfo.windowID else {
            throw ValidationError(
                "Snapshot '\(snapshotId)' belongs to window \(snapshotWindowID), but the explicit selector " +
                    "resolved window \(resolution.windowInfo.windowID)"
            )
        }

        if let snapshotPID = snapshotContext?.applicationProcessId,
           let selectedPID = resolution.targetProcessIdentifier,
           snapshotPID != selectedPID {
            throw ValidationError(
                "Snapshot '\(snapshotId)' belongs to PID \(snapshotPID), but the selected window " +
                    "belongs to PID \(selectedPID)"
            )
        }
    }
}

struct InteractionCoordinateResolution {
    let inputPoint: CGPoint
    let screenPoint: CGPoint
    let coordinateSpace: InteractionCoordinateSpace
    let windowInfo: ServiceWindowInfo?
    let targetApplication: ServiceApplicationInfo?

    var targetApplicationName: String? {
        self.targetApplication?.name
    }

    var targetProcessIdentifier: Int32? {
        self.targetApplication?.processIdentifier
    }

    var targetApplicationIdentifier: String? {
        if let bundleIdentifier = self.targetApplication?.bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }
        if let name = self.targetApplication?.name, !name.isEmpty {
            return name
        }
        if let processIdentifier = self.targetProcessIdentifier {
            return "PID:\(processIdentifier)"
        }
        return nil
    }

    var targetWindowTitle: String? {
        self.windowInfo?.title
    }

    var targetWindowID: Int? {
        self.windowInfo?.windowID
    }

    var diagnostics: InteractionCoordinateDiagnostics {
        InteractionCoordinateDiagnostics(
            coordinateSpace: self.coordinateSpace.rawValue,
            input: InteractionPoint(self.inputPoint),
            resolved: InteractionPoint(self.screenPoint),
            targetWindow: self.windowInfo.map(InteractionTargetWindowDiagnostics.init),
            targetApp: self.targetApplicationName,
            targetPID: self.targetProcessIdentifier
        )
    }
}

enum InteractionCoordinateSpace: String {
    case global
    case windowRelative = "window_relative"
}

struct InteractionCoordinateDiagnostics: Codable, Equatable {
    let coordinateSpace: String
    let input: InteractionPoint
    let resolved: InteractionPoint
    let targetWindow: InteractionTargetWindowDiagnostics?
    let targetApp: String?
    let targetPID: Int32?
}

struct InteractionTargetWindowDiagnostics: Codable, Equatable {
    let windowID: Int
    let title: String
    let bounds: InteractionRect

    init(_ windowInfo: ServiceWindowInfo) {
        self.windowID = windowInfo.windowID
        self.title = windowInfo.title
        self.bounds = InteractionRect(windowInfo.bounds)
    }
}

struct InteractionRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.width)
        self.height = Double(rect.height)
    }
}
