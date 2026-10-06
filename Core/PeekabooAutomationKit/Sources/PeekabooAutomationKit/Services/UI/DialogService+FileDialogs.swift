import AppKit
import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    private struct FileDialogOptions {
        let path: String?
        let filename: String?
        let actionButton: String?
        let ensureExpanded: Bool
    }

    public func handleFileDialog(
        path: String?,
        filename: String?,
        actionButton: String?,
        ensureExpanded: Bool = false,
        appName: String?) async throws -> DialogActionResult
    {
        try await self.executeFileDialog(
            options: .init(
                path: path,
                filename: filename,
                actionButton: actionButton,
                ensureExpanded: ensureExpanded),
            appName: appName,
            request: nil)
    }

    public func handleFileDialog(_ request: DialogFileExecutionRequest) async throws -> DialogActionResult {
        try await self.executeFileDialog(
            options: .init(
                path: request.path,
                filename: request.filename,
                actionButton: request.actionButton,
                ensureExpanded: request.ensureExpanded),
            appName: nil,
            request: request)
    }

    private func executeFileDialog(
        options: FileDialogOptions,
        appName: String?,
        request: DialogFileExecutionRequest?) async throws -> DialogActionResult
    {
        try await self.runDialogOperation(scope: .global, access: .write) {
            self.logger.info("Handling file dialog")
            if let path = options.path {
                self.logger.debug("Path: \(path)")
            }
            if let filename = options.filename {
                self.logger.debug("Filename: \(filename)")
            }
            if let actionButton = options.actionButton {
                self.logger.debug("Action button: \(actionButton)")
            } else {
                self.logger.debug("Action button: (default/OKButton)")
            }

            var actionSequence = DesktopActionSequenceAccumulator()
            var failureTarget: UIAutomationTarget.ExactWindow?
            do {
                let saveStartTime = Date()
                var resolution = if let request {
                    try await self.resolveFileDialogElementResolution(target: request.target, revalidate: false)
                } else {
                    try await self.resolveFileDialogElementResolution(appName: appName)
                }
                let execution = try request.map { try FileExecution(request: $0, resolution: resolution) }
                let appName = execution.map { "PID:\($0.target.identity.ownerProcessIdentifier)" } ?? appName
                var retainedTarget = resolution.target
                failureTarget = retainedTarget
                var dialog = resolution.element
                var details = Self.dialogTargetDetails(retainedTarget).merging([
                    "dialog_identifier": resolution.dialogIdentifier,
                    "found_via": resolution.foundVia,
                ]) { _, new in new }

                if let outcome = try await self.ensureFileDialogFocus(
                    dialog: dialog, appName: appName, execution: execution)
                {
                    actionSequence.record(.outcome(outcome))
                }

                if options.ensureExpanded {
                    let expansion = try await self.ensureFileDialogExpandedIfNeeded(
                        dialog: dialog,
                        execution: execution)
                    if let outcome = expansion {
                        actionSequence.record(.outcome(outcome))
                    }
                    // Expanding can rebuild the AX tree; re-resolve.
                    resolution = try await self.resolveFileDialogElementResolution(
                        appName: appName, execution: execution, allowExpansion: expansion != nil)
                    retainedTarget = try Self.fileDialogTargetAfterNavigation(
                        resolution.target,
                        retained: retainedTarget,
                        disposition: expansion != nil ? .refreshAfterExpansion : .unchanged)
                    failureTarget = retainedTarget
                    dialog = resolution.element
                    details["dialog_identifier"] = resolution.dialogIdentifier
                    details["found_via"] = resolution.foundVia
                    details["ensure_expanded"] = "true"
                }

                if let filePath = options.path {
                    let navigation = try await self.navigateToPath(
                        filePath,
                        in: dialog,
                        ensureExpanded: options.ensureExpanded,
                        appName: appName,
                        execution: execution)
                    details["path"] = filePath
                    details["path_navigation_method"] = navigation.method
                    if let outcome = navigation.outcome {
                        actionSequence.record(.outcome(outcome))
                    }

                    // Navigating the path can expand/collapse the panel and rebuild the sheet tree. Re-resolve the
                    // active
                    // file dialog after navigation so subsequent actions (filename + action button) target fresh AX
                    // handles.
                    resolution = try await self.resolveFileDialogElementResolution(
                        appName: appName,
                        execution: execution,
                        allowExpansion: navigation.targetDisposition == .refreshAfterExpansion)
                    retainedTarget = try Self.fileDialogTargetAfterNavigation(
                        resolution.target,
                        retained: retainedTarget,
                        disposition: navigation.targetDisposition)
                    failureTarget = retainedTarget
                    dialog = resolution.element
                    details["dialog_identifier"] = resolution.dialogIdentifier
                    details["found_via"] = resolution.foundVia
                }

                if let fileName = options.filename {
                    if let outcome = try await self.updateFilename(fileName, in: dialog, execution: execution) {
                        actionSequence.record(.outcome(outcome))
                    }
                    details["filename"] = fileName
                }

                let priorDocumentPath = try self.priorDocumentPathForFileAction(
                    options: options,
                    target: retainedTarget,
                    execution: execution,
                    appName: appName)

                // Typed execution retains its panel; controls are read afresh and focus/ownership checked at dispatch.
                // The legacy path has no retained raw panel and must resolve it again.
                resolution = if let execution {
                    execution.resolution
                } else {
                    try await self.resolveFileDialogElementResolution(appName: appName)
                }
                try Self.requireSameFileDialogTarget(resolution.target, retained: retainedTarget)
                dialog = resolution.element
                details["dialog_identifier"] = resolution.dialogIdentifier
                details["found_via"] = resolution.foundVia

                let resolvedActionButton = self.fileDialogActionButton(options.actionButton)
                let clickResult = try await self.clickButton(
                    in: dialog,
                    buttonText: resolvedActionButton,
                    allowFallbackToDefaultAction: true,
                    allowGlobalFallback: true,
                    execution: execution)
                if let outcome = clickResult.outcome {
                    actionSequence.record(.outcome(outcome))
                }
                details["button_clicked"] = clickResult.details["button"] ?? resolvedActionButton
                if let buttonIdentifier = clickResult.details["button_identifier"] {
                    details["button_identifier"] = buttonIdentifier
                }

                let clickedTitle = clickResult.details["button"] ?? resolvedActionButton
                if self.isSaveLikeAction(clickedTitle) {
                    let expectedPath = self.expectedSavedPath(path: options.path, filename: options.filename)
                    let expectedBaseName = self.expectedSavedBaseName(
                        filename: options.filename,
                        expectedPath: expectedPath)
                    let completed = try await self.verifySavedFileAfterAction(
                        request: .init(
                            appName: appName,
                            priorDocumentPath: priorDocumentPath,
                            expectedPath: expectedPath,
                            expectedBaseName: expectedBaseName,
                            startedAt: saveStartTime,
                            timeout: 5.0,
                            retainedTarget: retainedTarget,
                            retainedParentWindow: execution?.window),
                        actionSequence: &actionSequence)
                    retainedTarget = completed.target
                    failureTarget = retainedTarget
                    try self.recordSavedFileVerification(
                        completed,
                        expectedPath: expectedPath,
                        details: &details)
                }

                return try self.completedFileDialogResult(
                    details: details,
                    actionSequence: actionSequence,
                    target: retainedTarget,
                    execution: execution)
            } catch {
                throw Self.preservingFileDialogFailure(
                    error,
                    after: actionSequence,
                    target: failureTarget)
            }
        }
    }

    private func priorDocumentPathForFileAction(
        options: FileDialogOptions,
        target: UIAutomationTarget.ExactWindow,
        execution: FileExecution?,
        appName: String?) throws -> String?
    {
        guard options.actionButton == nil || self.isSaveLikeAction(options.actionButton ?? "") else {
            return nil
        }
        if let execution {
            return try self.documentPathForRetainedFileDialogParent(
                target: target,
                retainedParentWindow: execution.window)
        }
        return self.documentPathForApp(appName: appName)
    }

    private func fileDialogActionButton(_ actionButton: String?) -> String {
        let requestedButton = actionButton?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRequested = requestedButton.map(self.normalizedDialogButtonTitle)
        return if normalizedRequested == "default" || requestedButton == nil {
            "default"
        } else {
            requestedButton ?? "default"
        }
    }

    private func completedFileDialogResult(
        details: [String: String],
        actionSequence: DesktopActionSequenceAccumulator,
        target: UIAutomationTarget.ExactWindow,
        execution: FileExecution?) throws -> DialogActionResult
    {
        let result = try DialogActionResult(
            success: true,
            action: .handleFileDialog,
            details: details,
            outcome: actionSequence.successResolution().outcome,
            targetReceipt: target.actionTargetReceipt,
            targetWindowIdentity: target.identity,
            targetWindowBounds: target.bounds,
            focusedElement: nil,
            resolvedTarget: execution?.resolvedTarget())

        self.logger.info("\(AgentDisplayTokens.Status.success) Successfully handled file dialog")
        return result
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
        let targetReceipt = target?.actionTargetReceipt
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
