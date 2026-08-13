import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

enum KeyboardDeliveryMode: String {
    case background
    case foreground
}

enum KeyboardDeliverySupport {
    static func requireBackgroundKeyboardTarget(
        target: InteractionTargetOptions,
        snapshotId: String?,
        services: any PeekabooServiceProviding,
        requiresExplicitExactWindow: Bool = false
    ) async throws -> UIAutomationTarget {
        let snapshotTarget: UIAutomationTarget.ExactWindow? = if let snapshotId {
            try await self.resolveSnapshotTarget(snapshotId: snapshotId, services: services)
        } else {
            nil
        }
        let selectedWindow = try await self.resolveSelectedWindow(target: target, services: services)
        let selectedProcessIdentity = try await self.resolveSelectedProcessIdentity(
            target: target,
            services: services
        )

        let exactWindow: UIAutomationTarget.ExactWindow?
        switch (snapshotTarget, selectedWindow) {
        case let (snapshot?, selected?):
            guard snapshot == selected else {
                throw ValidationError(
                    "The selected snapshot and window selector identify different exact windows. " +
                        "Capture fresh UI state."
                )
            }
            exactWindow = snapshot
        case let (snapshot?, nil):
            exactWindow = snapshot
        case let (nil, selected?):
            exactWindow = selected
        case (nil, nil):
            exactWindow = nil
        }

        let processIdentity = try self.requireConsistentProcessIdentity(
            selected: selectedProcessIdentity,
            snapshot: snapshotTarget?.identity.processIdentity,
            window: selectedWindow?.identity.processIdentity
        )
        try await self.requireBackgroundInputEligibility(
            processIdentity: processIdentity,
            services: services
        )
        let process = try UIAutomationTarget.Process(
            processIdentifier: processIdentity.processIdentifier,
            identity: processIdentity
        )

        if let exactWindow {
            return try UIAutomationTarget.backgroundKeyboard(
                process: process,
                exactWindow: exactWindow
            )
        }

        let eligibleWindows: [UIAutomationTarget.ExactWindow]
        if requiresExplicitExactWindow {
            eligibleWindows = []
        } else {
            let windows = try await services.windows.listWindows(
                target: .application("PID:\(processIdentity.processIdentifier)")
            )
            eligibleWindows = try ObservationTargetResolver.captureCandidates(from: windows).map {
                try UIAutomationTarget.ExactWindow(window: $0)
            }
        }
        return try UIAutomationTarget.backgroundKeyboard(
            process: process,
            eligibleWindows: eligibleWindows,
            requiresExplicitExactWindow: requiresExplicitExactWindow
        )
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

    private static func resolveSnapshotTarget(
        snapshotId: String,
        services: any PeekabooServiceProviding
    ) async throws -> UIAutomationTarget.ExactWindow {
        var processIdentifier: Int32?
        var windowIdentity: WindowMutationIdentity?
        var windowBounds: CGRect?

        func merge(
            process incomingProcess: Int32?,
            identity incomingIdentity: WindowMutationIdentity?,
            bounds incomingBounds: CGRect?
        ) throws {
            if let incomingProcess {
                guard processIdentifier.map({ $0 == incomingProcess }) ?? true else {
                    throw ValidationError("Snapshot '\(snapshotId)' has inconsistent process metadata.")
                }
                processIdentifier = incomingProcess
            }
            if let incomingIdentity {
                guard windowIdentity.map({ $0 == incomingIdentity }) ?? true else {
                    throw ValidationError("Snapshot '\(snapshotId)' has inconsistent window metadata.")
                }
                windowIdentity = incomingIdentity
            }
            if let incomingBounds {
                guard windowBounds.map({ $0 == incomingBounds }) ?? true else {
                    throw ValidationError("Snapshot '\(snapshotId)' has inconsistent window bounds.")
                }
                windowBounds = incomingBounds
            }
        }

        if let snapshot = try await services.snapshots.getUIAutomationSnapshot(snapshotId: snapshotId) {
            try merge(
                process: snapshot.applicationProcessId,
                identity: snapshot.windowMutationIdentity,
                bounds: snapshot.windowBounds
            )
        }
        if let detectionResult = try await services.snapshots.getDetectionResult(snapshotId: snapshotId),
           let context = detectionResult.metadata.windowContext {
            try merge(
                process: context.applicationProcessId,
                identity: context.windowMutationIdentity,
                bounds: context.windowBounds
            )
        }

        guard let processIdentifier, processIdentifier > 0,
              let windowIdentity,
              let windowBounds,
              windowIdentity.ownerProcessIdentifier == processIdentifier,
              windowIdentity.windowID > 0,
              windowIdentity.capturedBounds == windowBounds
        else {
            throw ValidationError(
                "Snapshot '\(snapshotId)' has no exact process-generation, window, and bounds receipt. " +
                    "Capture fresh UI state."
            )
        }
        return try UIAutomationTarget.ExactWindow(identity: windowIdentity, bounds: windowBounds)
    }

    private static func resolveSelectedWindow(
        target: InteractionTargetOptions,
        services: any PeekabooServiceProviding
    ) async throws -> UIAutomationTarget.ExactWindow? {
        guard target.windowId != nil || target.windowTitle != nil || target.windowIndex != nil else {
            return nil
        }
        guard let windowTarget = try target.toWindowTarget() else {
            throw ValidationError("Could not resolve the requested exact window.")
        }
        let matches = try await services.windows.listWindows(target: windowTarget)
        guard matches.count == 1, let window = matches.first else {
            let detail = matches.isEmpty ? "no matching window" : "multiple matching windows"
            throw ValidationError("Could not resolve one exact background keyboard target: \(detail).")
        }
        return try UIAutomationTarget.ExactWindow(window: window)
    }

    private static func resolveSelectedProcessIdentity(
        target: InteractionTargetOptions,
        services: any PeekabooServiceProviding
    ) async throws -> ApplicationProcessIdentity? {
        if let pid = target.pid {
            guard pid > 0 else { throw ValidationError("--pid must be greater than 0") }
            return try await self.requireCurrentProcessIdentity(
                processIdentifier: pid,
                services: services
            )
        }
        guard let appIdentifier = target.app?.trimmingCharacters(in: .whitespacesAndNewlines),
              !appIdentifier.isEmpty
        else { return nil }
        let app = try await services.applications.findApplication(identifier: appIdentifier)
        return try self.requireProcessIdentity(app, targetDescription: "--app '\(appIdentifier)'")
    }

    private static func requireConsistentProcessIdentity(
        selected: ApplicationProcessIdentity?,
        snapshot: ApplicationProcessIdentity?,
        window: ApplicationProcessIdentity?
    ) throws -> ApplicationProcessIdentity {
        let identities = [selected, snapshot, window].compactMap(\.self)
        guard let identity = identities.first else {
            throw PreDispatchActionError(
                message: "Keyboard input requires --app, --pid, --window-id, or --snapshot for background delivery.",
                code: .VALIDATION_ERROR,
                hint: "Use --foreground for intentional global input.",
                reason: .invalidRequest
            )
        }
        guard identities.allSatisfy({ $0 == identity }) else {
            throw ValidationError(
                "The selected app, window, and snapshot do not identify the same process generation. " +
                    "Capture fresh UI state."
            )
        }
        return identity
    }

    private static func requireBackgroundInputEligibility(
        processIdentity: ApplicationProcessIdentity,
        services: any PeekabooServiceProviding
    ) async throws {
        let app = try await services.applications.findApplication(
            identifier: "PID:\(processIdentity.processIdentifier)"
        )
        guard app.processIdentity == processIdentity else {
            throw ValidationError(
                "Target process PID \(processIdentity.processIdentifier) changed identity while " +
                    "resolving keyboard input."
            )
        }
        guard app.isEligibleForBackgroundInput else {
            throw ValidationError(
                "Target process PID \(processIdentity.processIdentifier) cannot receive background input because it " +
                    "is a prohibited helper or its application metadata is incomplete."
            )
        }
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
