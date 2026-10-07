import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    @MainActor
    final class FileExecution {
        let request: DialogFileExecutionRequest
        let window: Element
        let selectorEvidence: ResolvedDialogTargetEvidence
        var resolution: FileDialogElementResolution

        init(request: DialogFileExecutionRequest, resolution: FileDialogElementResolution) throws {
            guard let window = resolution.window, let evidence = resolution.resolvedTarget,
                  evidence.target == resolution.target, evidence.matches(request.target)
            else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "File dialog has no complete parent and selector plan.",
                    hint: "List the dialog before retrying.")
            }
            self.request = request
            self.window = window
            self.selectorEvidence = evidence
            self.resolution = resolution
        }

        var target: UIAutomationTarget.ExactWindow {
            self.resolution.target
        }

        func resolvedTarget() throws -> ResolvedDialogTargetEvidence {
            let identity = self.target.identity
            let original = self.selectorEvidence
            guard original.target.identity.windowID == identity.windowID,
                  original.target.identity.processIdentity == identity.processIdentity
            else { throw DesktopSelectedLeafEvidenceError.invalidEvidence }
            // Selector labels belong to planning time; expansion only refreshes the same window's geometry.
            let proofs = original.selectorResolutionProofs?.map { $0.selecting(windowIdentity: identity) }
            let application = ServiceApplicationInfo(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity,
                bundleIdentifier: original.applicationBundleIdentifier,
                name: original.applicationName,
                bundlePath: original.applicationBundlePath,
                executablePath: original.applicationExecutablePath,
                activationPolicy: original.applicationActivationPolicy,
                selectorResolutionProofs: proofs?.filter { $0.scope == .application })
            let window = ServiceWindowInfo(
                windowID: identity.windowID,
                title: original.windowTitle,
                bounds: self.target.bounds,
                index: original.windowIndex,
                mutationIdentity: identity)
            return try ResolvedDialogTargetEvidence(
                target: self.target,
                application: application,
                window: window,
                windowResolutionProof: proofs?.first(where: { $0.scope == .window }))
        }
    }

    func refreshFileExecution(
        _ execution: FileExecution,
        allowExpansion: Bool = false) async throws -> FileDialogElementResolution
    {
        let retained = execution.resolution
        let current = try await self.resolveFileDialogElementResolution(target: DialogTargetSelector(
            processIdentifier: retained.target.identity.ownerProcessIdentifier,
            windowID: retained.target.identity.windowID), revalidate: false)
        guard let window = current.window, Self.sameElement(window, execution.window) else {
            throw self.targetUnavailable("The file dialog parent changed during execution.")
        }
        _ = try Self.fileDialogTargetAfterNavigation(
            current.target,
            retained: retained.target,
            disposition: allowExpansion ? .refreshAfterExpansion : .unchanged)
        if !Self.sameElement(current.element, retained.element) {
            throw self.targetUnavailable("The retained file panel changed before dispatch.")
        }
        execution.resolution = current
        return current
    }

    func focusFileExecution(_ execution: FileExecution) async throws -> DesktopActionOutcome {
        let resolution = execution.resolution
        let policy = execution.request.focus
        var sequence = DesktopActionSequenceAccumulator()
        do {
            try Task.checkCancellation()
            if policy.autoFocus {
                try await self.focusService.focusFileDialogWindowWithOwnedLane(
                    target: resolution.target,
                    window: execution.window,
                    dialog: resolution.element,
                    options: .init(
                        timeout: policy.timeout,
                        retryCount: policy.retryCount,
                        switchSpace: policy.switchSpace,
                        bringToCurrentSpace: policy.bringToCurrentSpace),
                    onDispatch: { sequence.record($0.sequenceStep) })
            } else {
                try await self.focusService.requireFileDialogWindowFocusWithOwnedLane(
                    target: resolution.target,
                    window: execution.window,
                    dialog: resolution.element,
                    timeout: policy.timeout)
            }
            return FocusDispatchAccounting.verifiedFocusOutcome(sequence.successResolution())
        } catch {
            throw Self.preservingFileDialogFailure(error, after: sequence, target: resolution.target)
        }
    }

    func resolveFileDialogElementResolution(
        appName: String?,
        execution: FileExecution?,
        allowExpansion: Bool = false) async throws -> FileDialogElementResolution
    {
        if let execution {
            return try await self.refreshFileExecution(execution, allowExpansion: allowExpansion)
        }
        return try await self.resolveFileDialogElementResolution(appName: appName)
    }

    func ensureFileDialogFocus(
        dialog: Element,
        appName: String?,
        execution: FileExecution?) async throws -> DesktopActionOutcome?
    {
        if let execution {
            return try await self.focusFileExecution(execution)
        }
        return try await self.ensureDialogFocus(dialog: dialog, appName: appName)
    }

    func requireFileExecutionFocus(
        _ execution: FileExecution?,
        dialog: Element? = nil,
        field: Element? = nil) throws
    {
        try Task.checkCancellation()
        guard let execution else { return }
        try self.focusService.requireFileDialogDispatchFocus(
            target: execution.target,
            window: execution.window,
            dialog: dialog ?? execution.resolution.element,
            field: field)
    }

    func fileDialogControls(in dialog: Element, execution: FileExecution?, role: String) async throws -> [Element] {
        guard let execution else {
            return role == "AXButton" ? self.collectButtons(from: dialog) : self.collectTextFields(from: dialog)
        }
        let budget = try DialogOperationDeadline.resolve(operationName: "file dialog controls")
        var visited: Set<Element> = []
        var stack = [dialog]
        var controls: [Element] = []
        while let element = stack.popLast() {
            try budget.check()
            guard visited.insert(element).inserted else { continue }
            let node = try await self.discoveryReaders.hierarchyNode(
                element, execution.target.identity.processIdentity, budget)
            if element != dialog,
               ["AXApplication", "AXWindow"].contains(node.evidence.role) ||
               DialogElementClassifier.isStructuralDialog(node.evidence)
            {
                continue
            }
            if node.evidence.role == role || (role == "AXTextField" && node.evidence.role == "AXTextArea") {
                controls.append(element)
            }
            stack.append(contentsOf: node.children.reversed())
        }
        return controls
    }

    struct FileNavigationSheet {
        let dialog: Element
        let field: Element
    }

    func resolveFileNavigationSheet(_ execution: FileExecution) async throws -> FileNavigationSheet {
        let panel = execution.resolution.element
        let budget = try DialogOperationDeadline.resolve(operationName: "Go to Folder sheet discovery")
        var visited: Set<Element> = []
        var stack = [panel]
        var sheets: [Element] = []
        while let element = stack.popLast() {
            try budget.check()
            guard visited.insert(element).inserted else { continue }
            let node = try await self.discoveryReaders.hierarchyNode(
                element, execution.target.identity.processIdentity, budget)
            if element != panel, DialogElementClassifier.isStructuralDialog(node.evidence) {
                sheets.append(element)
                continue
            }
            if element != panel, ["AXApplication", "AXWindow"].contains(node.evidence.role) {
                continue
            }
            stack.append(contentsOf: node.children.reversed())
        }
        guard sheets.count == 1, let sheet = sheets.first else {
            throw self.targetUnavailable("Go to Folder did not expose one sheet within the retained file panel.")
        }
        let fields = try await self.fileDialogControls(in: sheet, execution: execution, role: "AXTextField")
            .filter { $0.isEnabled() == true }
        guard fields.count == 1, let field = fields.first else {
            throw self.targetUnavailable("Go to Folder did not expose one enabled text field.")
        }
        return FileNavigationSheet(dialog: sheet, field: field)
    }

    func requireFileNavigationSheet(_ sheet: FileNavigationSheet, execution: FileExecution) throws {
        // The temporary sheet cannot replace the planned file panel or borrow another modal descendant of P.
        guard Self.rawElementPresence(sheet.dialog, in: execution.resolution.element) == .present else {
            throw self.targetUnavailable("Go to Folder is no longer attached to the retained file panel.")
        }
        try self.requireFileExecutionFocus(execution, dialog: sheet.dialog, field: sheet.field)
    }
}
