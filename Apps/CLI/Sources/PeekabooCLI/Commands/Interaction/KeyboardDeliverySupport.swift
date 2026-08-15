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
            let merged: DesktopTargetIdentity?
            do {
                merged = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.coalesce([
                    DesktopTargetIdentity(exactWindow: snapshot),
                    DesktopTargetIdentity(exactWindow: selected),
                ])
            } catch {
                throw ValidationError(
                    "The selected snapshot and window selector identify different exact windows. " +
                        "Capture fresh UI state."
                )
            }
            guard let mergedWindow = merged?.exactWindow else {
                throw ValidationError("The selected exact-window receipts are incomplete.")
            }
            exactWindow = mergedWindow
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
        var evidence: [DesktopTargetIdentity.Evidence] = []
        if let snapshot = try await services.snapshots.getUIAutomationSnapshot(snapshotId: snapshotId) {
            evidence.append(.init(
                processIdentifier: snapshot.applicationProcessId,
                windowID: snapshot.windowID.map(Int.init),
                windowIdentity: snapshot.windowMutationIdentity,
                windowBounds: snapshot.windowBounds,
                focusedElement: snapshot.focusedElement
            ))
        }
        if let detectionResult = try await services.snapshots.getDetectionResult(snapshotId: snapshotId),
           let context = detectionResult.metadata.windowContext {
            evidence.append(.init(
                processIdentifier: context.applicationProcessId,
                windowID: context.windowID,
                windowIdentity: context.windowMutationIdentity,
                windowBounds: context.windowBounds,
                focusedElement: context.focusedElement
            ))
        }

        do {
            let receipt = try SnapshotTargetReceipt(snapshotID: snapshotId, evidence: evidence)
            guard let exactWindow = try receipt.requireIdentity().exactWindow else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            return exactWindow
        } catch DesktopTargetIdentityError.missingProcessGeneration,
            DesktopTargetIdentityError.incompleteExactWindow {
            throw ValidationError(
                "Snapshot '\(snapshotId)' has no exact process-generation, window, and bounds receipt. " +
                    "Capture fresh UI state."
            )
        } catch {
            throw ValidationError("Snapshot '\(snapshotId)' has inconsistent process/window metadata.")
        }
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
        do {
            return try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.exactWindow(from: window)
        } catch {
            throw ValidationError(
                "The selected window has no valid process-generation, window ID, and capture-bounds receipt. " +
                    "Capture fresh UI state."
            )
        }
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
        let identities = try [selected, snapshot, window].map { identity throws -> DesktopTargetIdentity? in
            guard let identity else { return nil }
            return try DesktopTargetIdentity(processIdentity: identity)
        }
        let targetIdentity: DesktopTargetIdentity?
        do {
            targetIdentity = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.coalesce(identities)
        } catch {
            throw ValidationError(
                "The selected app, window, and snapshot do not identify the same process generation. " +
                    "Capture fresh UI state."
            )
        }
        guard let identity = targetIdentity?.processIdentity else {
            throw PreDispatchActionError(
                message: "Keyboard input requires --app, --pid, --window-id, or --snapshot for background delivery.",
                code: .VALIDATION_ERROR,
                hint: "Use --foreground for intentional global input.",
                reason: .invalidRequest
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
