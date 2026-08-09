import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

enum KeyboardDeliveryMode: String {
    case background
    case foreground
}

enum KeyboardDeliverySupport {
    static func requireBackgroundProcessIdentifier(
        target: InteractionTargetOptions,
        snapshotId: String?,
        services: any PeekabooServiceProviding
    ) async throws -> pid_t {
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
            return pid_t(pid)
        }

        if let appIdentifier = target.app?.trimmingCharacters(in: .whitespacesAndNewlines),
           !appIdentifier.isEmpty {
            let app = try await services.applications.findApplication(identifier: appIdentifier)
            guard app.processIdentifier > 0 else {
                throw ValidationError("Could not resolve a running process for --app '\(appIdentifier)'.")
            }
            return pid_t(app.processIdentifier)
        }

        if let snapshotId,
           let snapshot = try await services.snapshots.getUIAutomationSnapshot(snapshotId: snapshotId),
           let processId = snapshot.applicationProcessId,
           processId > 0 {
            return pid_t(processId)
        }

        if let snapshotId,
           let detectionResult = try await services.snapshots.getDetectionResult(snapshotId: snapshotId),
           let processId = detectionResult.metadata.windowContext?.applicationProcessId,
           processId > 0 {
            return pid_t(processId)
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
}
