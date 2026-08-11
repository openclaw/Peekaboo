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
        let resolved = try await self.resolveBackgroundProcess(
            target: target,
            snapshotId: snapshotId,
            services: services
        )
        let selectedIdentity: ApplicationProcessIdentity
        switch resolved {
        case let .pid(processIdentifier):
            selectedIdentity = try await self.requireCurrentProcessIdentity(
                processIdentifier: processIdentifier,
                services: services
            )
        case let .application(app, description):
            selectedIdentity = try self.requireProcessIdentity(app, targetDescription: description)
        case let .snapshot(processIdentifier, capturedWindowIdentity, snapshotId):
            return try await self.requireSnapshotProcessIdentity(
                processIdentifier: processIdentifier,
                capturedWindowIdentity: capturedWindowIdentity,
                snapshotId: snapshotId,
                services: services
            )
        }

        if let snapshotId {
            let snapshot = try await self.resolveSnapshotProcess(snapshotId: snapshotId, services: services)
            let snapshotIdentity = try await self.requireSnapshotProcessIdentity(
                processIdentifier: snapshot.processIdentifier,
                capturedWindowIdentity: snapshot.windowIdentity,
                snapshotId: snapshotId,
                services: services
            )
            guard snapshotIdentity == selectedIdentity else {
                throw ValidationError(
                    "The selected snapshot belongs to a different process generation. Capture fresh UI state."
                )
            }
        }
        return selectedIdentity
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

        if let snapshotId {
            let snapshot = try await self.resolveSnapshotProcess(snapshotId: snapshotId, services: services)
            return .snapshot(
                snapshot.processIdentifier,
                capturedWindowIdentity: snapshot.windowIdentity,
                snapshotId: snapshotId
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
        case snapshot(Int32, capturedWindowIdentity: WindowMutationIdentity, snapshotId: String)

        var processIdentifier: Int32 {
            switch self {
            case let .pid(processIdentifier), let .snapshot(processIdentifier, _, _):
                processIdentifier
            case let .application(app, _):
                app.processIdentifier
            }
        }
    }

    private struct ResolvedSnapshotProcess {
        let processIdentifier: Int32
        let windowIdentity: WindowMutationIdentity
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
        capturedWindowIdentity: WindowMutationIdentity,
        snapshotId: String,
        services: any PeekabooServiceProviding
    ) async throws -> ApplicationProcessIdentity {
        let currentIdentity = try await self.requireCurrentProcessIdentity(
            processIdentifier: processIdentifier,
            services: services
        )
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

    private static func resolveSnapshotProcess(
        snapshotId: String,
        services: any PeekabooServiceProviding
    ) async throws -> ResolvedSnapshotProcess {
        var capturedProcessIdentifier: Int32?
        var capturedWindowIdentity: WindowMutationIdentity?

        if let snapshot = try await services.snapshots.getUIAutomationSnapshot(snapshotId: snapshotId),
           let processIdentifier = snapshot.applicationProcessId,
           processIdentifier > 0
        {
            capturedProcessIdentifier = processIdentifier
            if let identity = snapshot.windowMutationIdentity {
                guard identity.ownerProcessIdentifier == processIdentifier else {
                    throw ValidationError("Snapshot '\(snapshotId)' has inconsistent process metadata.")
                }
                capturedWindowIdentity = identity
            }
        }

        if let detectionResult = try await services.snapshots.getDetectionResult(snapshotId: snapshotId),
           let context = detectionResult.metadata.windowContext,
           let processIdentifier = context.applicationProcessId,
           processIdentifier > 0
        {
            if let capturedProcessIdentifier, capturedProcessIdentifier != processIdentifier {
                throw ValidationError("Snapshot '\(snapshotId)' has inconsistent process metadata.")
            }
            capturedProcessIdentifier = processIdentifier
            if let identity = context.windowMutationIdentity {
                guard identity.ownerProcessIdentifier == processIdentifier else {
                    throw ValidationError("Snapshot '\(snapshotId)' has inconsistent process metadata.")
                }
                if let existingIdentity = capturedWindowIdentity, existingIdentity != identity {
                    throw ValidationError("Snapshot '\(snapshotId)' has inconsistent process metadata.")
                }
                capturedWindowIdentity = identity
            }
        }

        guard let capturedProcessIdentifier else {
            throw ValidationError(
                "The selected snapshot does not identify a target process. " +
                    "Capture a window/app snapshot or add --foreground for intentional global input."
            )
        }
        guard let capturedWindowIdentity else {
            throw ValidationError(
                "The selected snapshot has no capture-time process-generation receipt. Capture fresh UI state."
            )
        }
        return ResolvedSnapshotProcess(
            processIdentifier: capturedProcessIdentifier,
            windowIdentity: capturedWindowIdentity
        )
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
