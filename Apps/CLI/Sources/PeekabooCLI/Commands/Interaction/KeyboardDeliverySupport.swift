import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

enum KeyboardDeliveryMode: String {
    case background
    case foreground
}

enum KeyboardDeliverySupport {
    static func requireBackgroundProcessIdentity(
        target: InteractionTargetOptions,
        snapshotId: String?,
        services: any PeekabooServiceProviding
    ) async throws -> ApplicationProcessIdentity {
        switch try await self.resolveBackgroundProcess(
            target: target,
            snapshotId: snapshotId,
            services: services
        ) {
        case let .pid(processIdentifier):
            try await self.requireCurrentProcessIdentity(
                processIdentifier: processIdentifier,
                services: services
            )
        case let .application(app, description):
            try self.requireProcessIdentity(app, targetDescription: description)
        case let .snapshot(processIdentifier, capturedWindowIdentity, snapshotId):
            try await self.requireSnapshotProcessIdentity(
                processIdentifier: processIdentifier,
                capturedWindowIdentity: capturedWindowIdentity,
                snapshotId: snapshotId,
                services: services
            )
        }
    }

    static func requireBackgroundProcessIdentifier(
        target: InteractionTargetOptions,
        snapshotId: String?,
        services: any PeekabooServiceProviding
    ) async throws -> pid_t {
        try await pid_t(self.resolveBackgroundProcess(
            target: target,
            snapshotId: snapshotId,
            services: services
        ).processIdentifier)
    }

    private static func resolveBackgroundProcess(
        target: InteractionTargetOptions,
        snapshotId: String?,
        services: any PeekabooServiceProviding
    ) async throws -> ResolvedBackgroundProcess {
        if target.windowTitle != nil || target.windowIndex != nil || target.windowId != nil {
            throw ValidationError(
                "Background keyboard delivery cannot safely target a specific window. " +
                    "Use --app/--pid without a window selector, or add --foreground to focus the window first."
            )
        }

        if let pid = target.pid {
            guard pid > 0 else {
                throw ValidationError("--pid must be greater than 0")
            }
            return .pid(pid)
        }

        if let appIdentifier = target.app?.trimmingCharacters(in: .whitespacesAndNewlines),
           !appIdentifier.isEmpty {
            let app = try await services.applications.findApplication(identifier: appIdentifier)
            guard app.processIdentifier > 0 else {
                throw ValidationError("Could not resolve a running process for --app '\(appIdentifier)'.")
            }
            return .application(app, description: "--app '\(appIdentifier)'")
        }

        if let snapshotId,
           let snapshot = try await services.snapshots.getUIAutomationSnapshot(snapshotId: snapshotId),
           let processIdentifier = snapshot.applicationProcessId,
           processIdentifier > 0 {
            return .snapshot(
                processIdentifier,
                capturedWindowIdentity: snapshot.windowMutationIdentity,
                snapshotId: snapshotId
            )
        }

        if let snapshotId,
           let detectionResult = try await services.snapshots.getDetectionResult(snapshotId: snapshotId),
           let processIdentifier = detectionResult.metadata.windowContext?.applicationProcessId,
           processIdentifier > 0 {
            return .snapshot(
                processIdentifier,
                capturedWindowIdentity: detectionResult.metadata.windowContext?.windowMutationIdentity,
                snapshotId: snapshotId
            )
        }

        if snapshotId != nil {
            throw ValidationError(
                "The selected snapshot does not identify a target process. " +
                    "Capture a window/app snapshot or add --foreground for intentional global input."
            )
        }

        throw ValidationError(
            "Keyboard input requires --app, --pid, or --snapshot for background delivery. " +
                "Use --foreground for intentional global input."
        )
    }

    private enum ResolvedBackgroundProcess {
        case pid(Int32)
        case application(ServiceApplicationInfo, description: String)
        case snapshot(Int32, capturedWindowIdentity: WindowMutationIdentity?, snapshotId: String)

        var processIdentifier: Int32 {
            switch self {
            case let .pid(processIdentifier), let .snapshot(processIdentifier, _, _):
                processIdentifier
            case let .application(app, _):
                app.processIdentifier
            }
        }
    }

    static func validateForegroundFlags(
        foreground: Bool,
        focusOptions: FocusCommandOptions,
        backgroundFlagName: String? = nil
    ) throws {
        if foreground, focusOptions.backgroundDeliveryExplicitlyRequested {
            throw ValidationError("--foreground cannot be combined with \(backgroundFlagName ?? "--focus-background")")
        }

        if focusOptions.backgroundDeliveryExplicitlyRequested, focusOptions.hasForegroundFocusOverrides {
            throw ValidationError("\(backgroundFlagName ?? "--focus-background") cannot be combined with focus options")
        }
    }

    private static func requireSnapshotProcessIdentity(
        processIdentifier: Int32,
        capturedWindowIdentity: WindowMutationIdentity?,
        snapshotId: String,
        services: any PeekabooServiceProviding
    ) async throws -> ApplicationProcessIdentity {
        let currentIdentity = try await self.requireCurrentProcessIdentity(
            processIdentifier: processIdentifier,
            services: services
        )
        guard let capturedWindowIdentity else { return currentIdentity }

        let capturedIdentity = ApplicationProcessIdentity(
            processIdentifier: capturedWindowIdentity.ownerProcessIdentifier,
            processStartIdentity: capturedWindowIdentity.ownerProcessStartIdentity
        )
        guard capturedIdentity.processIdentifier == processIdentifier,
              capturedIdentity == currentIdentity
        else {
            throw ValidationError(
                "Snapshot '\(snapshotId)' is stale: its target application exited or changed process generation."
            )
        }
        return capturedIdentity
    }

    private static func requireCurrentProcessIdentity(
        processIdentifier: Int32,
        services: any PeekabooServiceProviding
    ) async throws -> ApplicationProcessIdentity {
        let app = try await services.applications.findApplication(identifier: "PID:\(processIdentifier)")
        guard app.processIdentifier == processIdentifier else {
            throw ValidationError("Could not resolve running process PID:\(processIdentifier).")
        }
        return try self.requireProcessIdentity(app, targetDescription: "PID:\(processIdentifier)")
    }

    private static func requireProcessIdentity(
        _ app: ServiceApplicationInfo,
        targetDescription: String
    ) throws -> ApplicationProcessIdentity {
        guard app.processIdentifier > 0 else {
            throw ValidationError("Could not resolve a running process for \(targetDescription).")
        }
        guard let processIdentity = app.processIdentity else {
            throw ValidationError(
                "The runtime host could not pin \(targetDescription) to a process generation; update the host."
            )
        }
        return processIdentity
    }
}
