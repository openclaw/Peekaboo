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
        let planner = DesktopTargetPlanning.BackgroundKeyboardTargetPlanner(
            applications: services.applications,
            windows: services.windows
        )
        do {
            return try await planner.plan(
                selector: target.selector,
                snapshotExactWindow: snapshotTarget,
                requiresExplicitExactWindow: requiresExplicitExactWindow
            ).target
        } catch DesktopTargetPlanning.BackgroundKeyboardTargetPlanningError.targetRequired {
            throw PreDispatchActionError(
                message: "Keyboard input requires --app, --pid, --window-id, or --snapshot for background delivery.",
                code: .VALIDATION_ERROR,
                hint: "Use --foreground for intentional global input.",
                reason: .invalidRequest
            )
        } catch let error as DesktopTargetPlanning.BackgroundKeyboardTargetPlanningError {
            throw ValidationError(error.localizedDescription)
        } catch let error as DesktopTargetPlanningError {
            if case let .applicationNotFound(identifier, _) = error {
                throw PeekabooError.appNotFound(identifier)
            }
            throw self.validationError(for: error)
        } catch let error as DesktopTargetIdentityError {
            throw ValidationError(
                "The selected app, window, and snapshot do not identify the same process generation or exact " +
                    "window receipt. " +
                    "Capture fresh UI state. (\(error.localizedDescription))"
            )
        }
    }

    private static func validationError(for error: DesktopTargetPlanningError) -> Commander.ValidationError {
        switch error {
        case .windowNotFound:
            ValidationError("Could not resolve one exact background keyboard target: no matching window.")
        case .ambiguousWindow:
            ValidationError("Could not resolve one exact background keyboard target: multiple matching windows.")
        case let .missingProcessIdentity(processIdentifier):
            ValidationError(
                "The runtime host could not pin PID:\(processIdentifier) to a process generation; update the host."
            )
        default:
            ValidationError(error.localizedDescription)
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
}
