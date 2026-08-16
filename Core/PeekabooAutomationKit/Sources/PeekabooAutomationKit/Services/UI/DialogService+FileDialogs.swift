import AppKit
import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    public func handleFileDialog(
        path: String?,
        filename: String?,
        actionButton: String?,
        ensureExpanded: Bool = false,
        appName: String?) async throws -> DialogActionResult
    {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            self.logger.info("Handling file dialog")
            if let path {
                self.logger.debug("Path: \(path)")
            }
            if let filename {
                self.logger.debug("Filename: \(filename)")
            }
            if let actionButton {
                self.logger.debug("Action button: \(actionButton)")
            } else {
                self.logger.debug("Action button: (default/OKButton)")
            }

            var actionSequence = DesktopActionSequenceAccumulator()
            var failureTarget: UIAutomationTarget.ExactWindow?
            do {
                let saveStartTime = Date()
                var resolution = try await self.resolveFileDialogElementResolution(appName: appName)
                var retainedTarget = resolution.target
                failureTarget = retainedTarget
                var dialog = resolution.element
                var details = Self.dialogTargetDetails(retainedTarget).merging([
                    "dialog_identifier": resolution.dialogIdentifier,
                    "found_via": resolution.foundVia,
                ]) { _, new in new }

                if let outcome = try await self.ensureDialogFocus(dialog: dialog, appName: appName) {
                    actionSequence.record(.outcome(outcome))
                }

                if ensureExpanded {
                    if let outcome = try await self.ensureFileDialogExpandedIfNeeded(dialog: dialog) {
                        actionSequence.record(.outcome(outcome))
                    }
                    // Expanding can rebuild the AX tree; re-resolve.
                    resolution = try await self.resolveFileDialogElementResolution(appName: appName)
                    retainedTarget = try Self.refreshFileDialogTargetAfterVerifiedExpansion(
                        resolution.target,
                        retained: retainedTarget)
                    failureTarget = retainedTarget
                    dialog = resolution.element
                    details["dialog_identifier"] = resolution.dialogIdentifier
                    details["found_via"] = resolution.foundVia
                    details["ensure_expanded"] = "true"
                }

                if let filePath = path {
                    let navigation = try await self.navigateToPath(
                        filePath,
                        in: dialog,
                        ensureExpanded: ensureExpanded,
                        appName: appName)
                    details["path"] = filePath
                    details["path_navigation_method"] = navigation.method
                    if let outcome = navigation.outcome {
                        actionSequence.record(.outcome(outcome))
                    }

                    // Navigating the path can expand/collapse the panel and rebuild the sheet tree. Re-resolve the
                    // active
                    // file dialog after navigation so subsequent actions (filename + action button) target fresh AX
                    // handles.
                    resolution = try await self.resolveFileDialogElementResolution(appName: appName)
                    retainedTarget = try Self.fileDialogTargetAfterNavigation(
                        resolution.target,
                        retained: retainedTarget,
                        disposition: navigation.targetDisposition)
                    failureTarget = retainedTarget
                    dialog = resolution.element
                    details["dialog_identifier"] = resolution.dialogIdentifier
                    details["found_via"] = resolution.foundVia
                }

                if let fileName = filename {
                    if let outcome = try self.updateFilename(fileName, in: dialog) {
                        actionSequence.record(.outcome(outcome))
                    }
                    details["filename"] = fileName
                }

                let shouldCapturePriorDocumentPath = actionButton == nil ||
                    self.isSaveLikeAction(actionButton ?? "")

                let priorDocumentPath: String? = if shouldCapturePriorDocumentPath {
                    self.documentPathForApp(appName: appName)
                } else {
                    nil
                }

                // The file panel can swap sheets (e.g. Go to Folder) or rebuild its button tree after typing.
                // Re-resolve the active file dialog right before clicking to avoid stale AX element handles.
                resolution = try await self.resolveFileDialogElementResolution(appName: appName)
                try Self.requireSameFileDialogTarget(resolution.target, retained: retainedTarget)
                dialog = resolution.element
                details["dialog_identifier"] = resolution.dialogIdentifier
                details["found_via"] = resolution.foundVia

                let requestedButton = actionButton?.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedRequested = requestedButton.map(self.normalizedDialogButtonTitle)
                let resolvedActionButton: String = if normalizedRequested == "default" || requestedButton == nil {
                    "default"
                } else {
                    requestedButton ?? "default"
                }

                let clickResult = try await self.clickButton(
                    in: dialog,
                    buttonText: resolvedActionButton,
                    allowFallbackToDefaultAction: true,
                    allowGlobalFallback: true)
                if let outcome = clickResult.outcome {
                    actionSequence.record(.outcome(outcome))
                }
                details["button_clicked"] = clickResult.details["button"] ?? resolvedActionButton
                if let buttonIdentifier = clickResult.details["button_identifier"] {
                    details["button_identifier"] = buttonIdentifier
                }

                let clickedTitle = clickResult.details["button"] ?? resolvedActionButton
                if self.isSaveLikeAction(clickedTitle) {
                    let expectedPath = self.expectedSavedPath(path: path, filename: filename)
                    let expectedBaseName = self.expectedSavedBaseName(filename: filename, expectedPath: expectedPath)
                    let completed = try await self.verifySavedFileAfterAction(
                        request: .init(
                            appName: appName,
                            priorDocumentPath: priorDocumentPath,
                            expectedPath: expectedPath,
                            expectedBaseName: expectedBaseName,
                            startedAt: saveStartTime,
                            timeout: 5.0,
                            retainedTarget: retainedTarget),
                        actionSequence: &actionSequence)
                    retainedTarget = completed.target
                    failureTarget = retainedTarget
                    try self.recordSavedFileVerification(
                        completed,
                        expectedPath: expectedPath,
                        details: &details)
                }

                let result = DialogActionResult(
                    success: true,
                    action: .handleFileDialog,
                    details: details,
                    outcome: actionSequence.successResolution().outcome,
                    targetReceipt: Self.desktopActionTargetReceipt(retainedTarget),
                    targetWindowIdentity: retainedTarget.identity,
                    targetWindowBounds: retainedTarget.bounds,
                    focusedElement: nil)

                self.logger.info("\(AgentDisplayTokens.Status.success) Successfully handled file dialog")
                return result
            } catch {
                throw Self.preservingFileDialogFailure(
                    error,
                    after: actionSequence,
                    target: failureTarget)
            }
        }
    }

    private static func requireSameFileDialogTarget(
        _ current: UIAutomationTarget.ExactWindow,
        retained: UIAutomationTarget.ExactWindow) throws
    {
        guard current.identity.hasSameStableReceipt(as: retained.identity),
              current.bounds == retained.bounds
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "File dialog changed its exact owning window before foreground dispatch.",
                hint: "List the file dialog again and retry against its current window.")
        }
    }

    static func refreshFileDialogTargetAfterVerifiedExpansion(
        _ current: UIAutomationTarget.ExactWindow,
        retained: UIAutomationTarget.ExactWindow) throws -> UIAutomationTarget.ExactWindow
    {
        guard current.identity.windowID == retained.identity.windowID,
              current.identity.processIdentity == retained.identity.processIdentity
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "File dialog changed its exact owning window while expanding.",
                hint: "List the file dialog again and retry against its current window.")
        }
        return current
    }

    static func fileDialogTargetAfterNavigation(
        _ current: UIAutomationTarget.ExactWindow,
        retained: UIAutomationTarget.ExactWindow,
        disposition: FileDialogNavigationResult.TargetDisposition) throws -> UIAutomationTarget.ExactWindow
    {
        switch disposition {
        case .unchanged:
            try self.requireSameFileDialogTarget(current, retained: retained)
            return retained
        case .refreshAfterExpansion:
            return try self.refreshFileDialogTargetAfterVerifiedExpansion(current, retained: retained)
        }
    }

    static func preservingFileDialogFailure(
        _ error: any Error,
        after sequence: DesktopActionSequenceAccumulator,
        target: UIAutomationTarget.ExactWindow?) -> any Error
    {
        let targetReceipt = target.map(Self.desktopActionTargetReceipt)
        if let failure = error as? DesktopActionFailure {
            return sequence.failure(
                combining: failure,
                message: failure.message,
                hint: failure.hint ?? "Observe the exact file dialog before retrying.",
                causeDescription: failure.causeDescription)
                .attributed(to: targetReceipt)
        }
        if error is CancellationError,
           let failure = sequence.cancellationFailure(
               fallbackRoute: .local,
               message: "File-dialog handling was cancelled after a mutation may have started.",
               hint: "Observe the exact file dialog before retrying.",
               causeDescription: error.localizedDescription)
        {
            return failure.attributed(to: targetReceipt)
        }
        let resolution = sequence.successResolution()
        guard resolution.mutationDispatched else { return error }
        return DesktopActionFailure.indeterminate(
            route: resolution.outcome?.route ?? .local,
            delivery: resolution.outcome?.delivery,
            evidence: .completionUnknown,
            unitCount: resolution.mutationDisposition.unitCount,
            message: "File-dialog handling failed after an earlier mutation was dispatched.",
            hint: "Observe the exact file dialog before retrying.",
            causeDescription: error.localizedDescription)
            .attributed(to: targetReceipt)
    }
}
