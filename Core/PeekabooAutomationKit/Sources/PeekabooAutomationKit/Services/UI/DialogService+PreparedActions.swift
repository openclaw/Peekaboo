import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    public func prepareDialogAction(_ request: DialogActionPreparationRequest) async throws
        -> PreparedDialogActionReceipt
    {
        do {
            return try await self.operationLaneCoordinator.run(scope: .global, access: .read) {
                let candidates = try await self.preparedActionCandidates(for: request)
                guard candidates.count == 1, let candidate = candidates.first else {
                    throw self.actionCandidateRefusal(request: request, candidates: candidates)
                }

                let receipt = PreparedDialogActionReceipt(
                    token: UUID(),
                    kind: request.kind,
                    target: candidate.target)
                self.preparedActionStore.insert(.init(
                    receipt: receipt,
                    request: request,
                    window: candidate.window,
                    dialog: candidate.dialog,
                    button: candidate.button,
                    resolvedButtonTitle: candidate.button.title() ?? request.buttonText ?? "Dismiss",
                    resolvedButtonIdentifier: candidate.button.attribute(Attribute<String>("AXIdentifier")),
                    createdAt: Date()))
                return receipt
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Dialog action target could not be prepared before any mutation.",
                hint: "List the application and dialog again before retrying.",
                causeDescription: error.localizedDescription)
        }
    }

    public func performPreparedDialogAction(_ receipt: PreparedDialogActionReceipt) async throws
        -> DialogActionResult
    {
        try await self.operationLaneCoordinator.run(
            scope: .window(receipt.target.identity),
            access: .write)
        {
            let entry = try self.preparedActionStore.consume(receipt)
            do {
                try await self.revalidatePreparedAction(entry)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as DesktopActionFailure {
                throw failure
            } catch {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Prepared dialog target could not be revalidated before AXPress.",
                    hint: "List the dialog and prepare a fresh exact action.",
                    causeDescription: error.localizedDescription)
            }

            var sequence = DesktopActionSequenceAccumulator()
            let leafOutcome: DesktopActionOutcome
            do {
                try Task.checkCancellation()
                leafOutcome = try await DetachedAXActionRunner.perform(
                    action: AXActionNames.kAXPressAction,
                    on: entry.button.underlyingElement,
                    gracePeriod: DetachedAXActionRunner.pressGracePeriod)
                sequence.record(.reportedOutcome(leafOutcome, defaultDispatchedUnitCount: .one))
                try Task.checkCancellation()
            } catch is CancellationError {
                if let failure = sequence.cancellationFailure(
                    fallbackRoute: .local,
                    message: "Dialog action was cancelled after AXPress may have been dispatched.",
                    hint: "Observe the dialog before any retry.",
                    causeDescription: "Cancellation occurred after the dialog action entered its leaf dispatch.")
                {
                    throw failure
                }
                throw CancellationError()
            } catch let failure as DesktopActionFailure {
                throw sequence.failure(
                    combining: failure,
                    message: failure.message,
                    hint: failure.hint,
                    causeDescription: failure.causeDescription)
            } catch {
                sequence.record(.mayHaveDispatched(
                    route: .local,
                    delivery: Self.backgroundDialogDelivery,
                    unitCount: .one))
                throw DesktopActionFailure.indeterminate(
                    delivery: Self.backgroundDialogDelivery,
                    evidence: .completionUnknown,
                    unitCount: .one,
                    message: "Dialog AXPress returned without reliable completion evidence.",
                    hint: "Observe the dialog before any retry.",
                    causeDescription: error.localizedDescription)
            }

            let dialogDisappeared = await self.verifyPreparedDialogDisappeared(entry)
            if Task.isCancelled,
               let failure = sequence.cancellationFailure(
                   fallbackRoute: .local,
                   message: "Dialog action was cancelled while verifying its postcondition.",
                   hint: "Observe the dialog before any retry.",
                   causeDescription: "Cancellation occurred after AXPress dispatch.")
            {
                throw failure
            }
            if dialogDisappeared {
                let outcome = DesktopActionOutcome.confirmedChange(
                    delivery: Self.backgroundDialogDelivery,
                    unitCount: .one)
                return DialogActionResult(
                    success: true,
                    action: receipt.kind == .clickButton ? .clickButton : .dismiss,
                    details: self.preparedActionDetails(entry),
                    outcome: outcome)
            }

            let outcome = sequence.successResolution().outcome ?? leafOutcome
            throw DesktopActionFailure(
                outcome: outcome,
                message: "Dialog AXPress was accepted, but dialog disappearance was not verified.",
                hint: "Capture fresh dialog state before deciding whether to retry.") ??
                DesktopActionFailure.indeterminate(
                    delivery: Self.backgroundDialogDelivery,
                    evidence: .completionUnknown,
                    unitCount: .one,
                    message: "Dialog action returned contradictory confirmation evidence.",
                    hint: "Observe the dialog before any retry.")
        }
    }

    public func listDialogElements(target: DialogTargetSelector) async throws -> DialogElements {
        try await self.operationLaneCoordinator.run(scope: .global, access: .read) {
            let dialogs = try await self.targetedDialogCandidates(target: target)
            guard dialogs.count == 1, let selected = dialogs.first else {
                throw self.dialogCandidateRefusal(target: target, candidates: dialogs)
            }
            return self.dialogElements(for: selected.dialog)
        }
    }
}

@MainActor
extension DialogService {
    struct TargetedDialogCandidate {
        let target: UIAutomationTarget.ExactWindow
        let window: Element
        let dialog: Element
    }

    struct PreparedActionCandidate {
        let target: UIAutomationTarget.ExactWindow
        let window: Element
        let dialog: Element
        let button: Element
    }

    enum DialogPresence: Equatable {
        case present
        case absent
        case unreadable
    }

    static let backgroundDialogDelivery = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .background)

    func preparedActionCandidates(for request: DialogActionPreparationRequest) async throws
        -> [PreparedActionCandidate]
    {
        let dialogs = try await self.targetedDialogCandidates(target: request.target)
        guard dialogs.count == 1, let candidate = dialogs.first else {
            throw self.dialogCandidateRefusal(target: request.target, candidates: dialogs)
        }
        let matches = self.semanticButtons(in: candidate.dialog, request: request)
        guard matches.count == 1, let button = matches.first else {
            let available = self.collectButtons(from: candidate.dialog).enumerated().map { index, button in
                let title = button.title() ?? "untitled"
                return "\(index):\(title)"
            }.joined(separator: ", ")
            let availableButtons = available.isEmpty ? "none" : available
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: matches.isEmpty
                    ? "No unique enabled AXPress dialog button matched the request."
                    : "Dialog button selection is ambiguous across \(matches.count) exact matches.",
                hint: "Candidate window ID: \(candidate.target.identity.windowID). " +
                    "Available buttons: \(availableButtons). " +
                    "Run dialog list and provide one unique exact button name.")
        }
        return [PreparedActionCandidate(
            target: candidate.target,
            window: candidate.window,
            dialog: candidate.dialog,
            button: button)]
    }

    func targetedDialogCandidates(target selector: DialogTargetSelector) async throws
        -> [TargetedDialogCandidate]
    {
        guard selector.hasTarget else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Targeted dialog lookup requires an app, PID, or window selector.",
                hint: "Omit the target for a foreground read-only list, or provide an exact owner.")
        }

        let application = try await self.targetApplication(for: selector)
        guard let processIdentity = application.processIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "The selected dialog owner has no process-generation receipt.",
                hint: "Update the runtime host and list the application again.")
        }

        let response = try await self.applicationService.listWindows(
            for: "PID:\(processIdentity.processIdentifier)",
            timeout: self.targetedDialogSearchTimeout)
        let windows = self.filteredDialogWindows(response.data.windows, selector: selector)
        if selector.hasWindowSelector, windows.count != 1 {
            let ids = windows.map(\.windowID).sorted().map(String.init).joined(separator: ", ")
            let candidateIDs = ids.isEmpty ? "none" : ids
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: windows.isEmpty
                    ? "The dialog window selector matched no exact window."
                    : "The dialog window selector is ambiguous across \(windows.count) windows.",
                hint: "Candidate window IDs: \(candidateIDs). Use one exact --window-id.")
        }
        var candidates: [TargetedDialogCandidate] = []
        for window in windows {
            guard let identity = window.mutationIdentity,
                  identity.processIdentity == processIdentity,
                  identity.windowID == window.windowID,
                  identity.capturedBounds == window.bounds,
                  let handle = self.windowIdentityService.findWindow(
                      byID: CGWindowID(window.windowID),
                      messagingTimeout: self.targetedDialogSearchTimeout),
                  handle.element.pid() == processIdentity.processIdentifier
            else { continue }

            let exactWindow = try UIAutomationTarget.ExactWindow(window: window)
            let freshDialogs = self.freshDialogElements(in: handle.element)
            guard freshDialogs.readable else {
                throw self.targetUnavailable(
                    "Dialog hierarchy became unreadable while preparing the exact target.")
            }
            for dialog in freshDialogs.elements {
                guard dialog.pid() == processIdentity.processIdentifier else { continue }
                candidates.append(TargetedDialogCandidate(
                    target: exactWindow,
                    window: handle.element,
                    dialog: dialog))
            }
        }

        let current = try await self.applicationService.findApplication(
            identifier: "PID:\(processIdentity.processIdentifier)")
        guard current.processIdentity == processIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Dialog owner changed process generation during planning.",
                hint: "List the application and dialog again before retrying.")
        }
        return candidates
    }

    func targetApplication(for selector: DialogTargetSelector) async throws -> ServiceApplicationInfo {
        let application: ServiceApplicationInfo
        if let processIdentifier = selector.processIdentifier {
            application = try await self.applicationService.findApplication(
                identifier: "PID:\(processIdentifier)")
            guard application.processIdentifier == processIdentifier else {
                throw self.targetUnavailable("The selected PID no longer identifies the same application.")
            }
        } else if let identifier = selector.applicationIdentifier {
            application = try await self.applicationService.findApplication(identifier: identifier)
        } else if let windowID = selector.windowID,
                  let handle = self.windowIdentityService.findWindow(
                      byID: CGWindowID(windowID),
                      messagingTimeout: self.targetedDialogSearchTimeout),
                  let ownerPID = handle.element.pid()
        {
            application = try await self.applicationService.findApplication(
                identifier: "PID:\(ownerPID)")
        } else {
            throw self.targetUnavailable("The selected dialog window could not be resolved to one owner.")
        }
        return application
    }

    func filteredDialogWindows(
        _ windows: [ServiceWindowInfo],
        selector: DialogTargetSelector) -> [ServiceWindowInfo]
    {
        if let windowID = selector.windowID {
            return windows.filter { $0.windowID == windowID }
        }
        if let title = selector.windowTitle {
            return windows.filter { $0.title.localizedCaseInsensitiveContains(title) }
        }
        if let index = selector.windowIndex {
            return windows.indices.contains(index) ? [windows[index]] : []
        }
        return windows
    }

    func freshDialogElements(in window: Element) -> (elements: [Element], readable: Bool) {
        var dialogs: [Element] = []
        var visited: Set<Element> = []
        var stack = [window]
        var readable = true

        while let element = stack.popLast() {
            guard visited.insert(element).inserted else { continue }
            if DialogElementClassifier.isStructuralDialog(DialogElementClassifier.evidence(for: element)) {
                dialogs.append(element)
            }
            let traversal = Self.traversalChildren(of: element)
            readable = readable && traversal.readable
            stack.append(contentsOf: traversal.elements.reversed())
        }
        return (dialogs, readable)
    }

    func semanticButtons(in dialog: Element, request: DialogActionPreparationRequest) -> [Element] {
        let buttons = self.collectButtons(from: dialog).filter { button in
            Self.isEligiblePreparedButton(button)
        }
        switch request.kind {
        case .clickButton:
            guard let requested = request.buttonText else { return [] }
            let normalized = self.normalizedDialogButtonTitle(requested)
            if normalized == "default" {
                return buttons.filter {
                    $0.attribute(Attribute<String>("AXIdentifier")) == "OKButton"
                }
            }
            return buttons.filter {
                guard let title = $0.title() else { return false }
                return self.normalizedDialogButtonTitle(title) == normalized
            }
        case .dismiss:
            let dismissTitles: Set = ["cancel", "close", "dismiss", "no", "don't save"]
            return buttons.filter { button in
                if button.attribute(Attribute<String>("AXIdentifier")) == "CancelButton" {
                    return true
                }
                guard let title = button.title() else { return false }
                return dismissTitles.contains(self.normalizedDialogButtonTitle(title))
            }
        }
    }

    func revalidatePreparedAction(_ entry: DialogPreparedActionStore.Entry) async throws {
        let expected = entry.receipt.target
        let application = try await self.applicationService.findApplication(
            identifier: "PID:\(expected.identity.ownerProcessIdentifier)")
        guard application.processIdentity == expected.identity.processIdentity else {
            throw self.targetUnavailable("Dialog owner changed process generation before AXPress.")
        }

        let response = try await self.applicationService.listWindows(
            for: "PID:\(expected.identity.ownerProcessIdentifier)",
            timeout: self.targetedDialogSearchTimeout)
        guard let window = response.data.windows.first(where: { $0.windowID == expected.identity.windowID }),
              let identity = window.mutationIdentity,
              identity.hasSameStableReceipt(as: expected.identity),
              window.bounds == expected.bounds,
              let currentWindow = self.windowIdentityService.findWindow(
                  byID: CGWindowID(expected.identity.windowID),
                  messagingTimeout: self.targetedDialogSearchTimeout),
              Self.sameElement(currentWindow.element, entry.window)
        else {
            throw self.targetUnavailable("Dialog window receipt changed before AXPress.")
        }

        let freshDialogs = self.freshDialogElements(in: currentWindow.element)
        guard freshDialogs.readable,
              freshDialogs.elements.count == 1,
              let dialog = freshDialogs.elements.first,
              Self.sameElement(dialog, entry.dialog)
        else {
            throw self.targetUnavailable("Prepared dialog or sheet changed before AXPress.")
        }
        let buttons = self.semanticButtons(in: dialog, request: entry.request)
        guard buttons.count == 1,
              let button = buttons.first,
              Self.sameElement(button, entry.button),
              Self.isEligiblePreparedButton(button)
        else {
            throw self.targetUnavailable("Prepared dialog button changed or became ambiguous before AXPress.")
        }
        try Task.checkCancellation()
    }

    func verifyPreparedDialogDisappeared(_ entry: DialogPreparedActionStore.Entry) async -> Bool {
        let deadline = Date().addingTimeInterval(0.75)
        var lastPresence = DialogPresence.unreadable
        repeat {
            lastPresence = self.preparedDialogPresence(entry)
            if lastPresence == .absent {
                return true
            }
            if Date() < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
        } while Date() < deadline && !Task.isCancelled
        return lastPresence == .absent
    }

    func preparedDialogPresence(_ entry: DialogPreparedActionStore.Entry) -> DialogPresence {
        let expected = entry.receipt.target
        switch Self.windowServerPresence(expected.identity) {
        case .absent:
            return .absent
        case .unreadable:
            return .unreadable
        case .present:
            break
        }
        guard let currentWindow = self.windowIdentityService.findWindow(
            byID: CGWindowID(expected.identity.windowID),
            messagingTimeout: self.targetedDialogSearchTimeout)
        else { return .unreadable }
        return Self.rawElementPresence(entry.dialog, in: currentWindow.element)
    }

    func preparedActionDetails(_ entry: DialogPreparedActionStore.Entry) -> [String: String] {
        var details = [
            "button": entry.resolvedButtonTitle,
            "window_id": String(entry.receipt.target.identity.windowID),
            "method": "button",
        ]
        if let identifier = entry.resolvedButtonIdentifier, !identifier.isEmpty {
            details["button_identifier"] = identifier
        }
        return details
    }

    func dialogElements(for dialog: Element) -> DialogElements {
        let info = DialogInfo(
            title: dialog.title() ?? "Untitled Dialog",
            role: dialog.role() ?? "Unknown",
            subrole: dialog.subrole(),
            isFileDialog: self.isFileDialogElement(dialog),
            bounds: self.elementBounds(for: dialog))
        return DialogElements(
            dialogInfo: info,
            buttons: self.dialogButtons(from: dialog),
            textFields: self.dialogTextFields(from: dialog),
            staticTexts: self.dialogStaticTexts(from: dialog),
            otherElements: self.dialogOtherElements(from: dialog))
    }

    func actionCandidateRefusal(
        request: DialogActionPreparationRequest,
        candidates: [PreparedActionCandidate]) -> DesktopActionFailure
    {
        let candidateIDs = Self.candidateWindowIDs(candidates.map(\.target))
        let message = candidates.isEmpty
            ? "No unique enabled AXPress dialog button matched the request."
            : "Dialog action is ambiguous across \(candidates.count) eligible window/dialog/button matches."
        let buttonHint = request.kind == .clickButton
            ? " Use dialog list and provide one exact button name."
            : " Use --window-id to select one dialog with one dismiss button."
        return .preDispatchRefusal(
            reason: .targetUnavailable,
            message: message,
            hint: "Candidate window IDs: \(candidateIDs).\(buttonHint)")
    }

    func dialogCandidateRefusal(
        target _: DialogTargetSelector,
        candidates: [TargetedDialogCandidate]) -> DesktopActionFailure
    {
        let candidateIDs = Self.candidateWindowIDs(candidates.map(\.target))
        let message = candidates.isEmpty
            ? "No dialog matched the selected target."
            : "Dialog target is ambiguous across \(candidates.count) eligible dialogs."
        return .preDispatchRefusal(
            reason: .targetUnavailable,
            message: message,
            hint: "Candidate window IDs: \(candidateIDs). Add --window-id or a more exact selector.")
    }

    func targetUnavailable(_ message: String) -> DesktopActionFailure {
        .preDispatchRefusal(
            reason: .targetUnavailable,
            message: message,
            hint: "List the dialog again and prepare a fresh exact action.")
    }

    static func candidateWindowIDs(_ targets: [UIAutomationTarget.ExactWindow]) -> String {
        let ids = Set(targets.map(\.identity.windowID)).sorted()
        return ids.isEmpty ? "none" : ids.map(String.init).joined(separator: ", ")
    }

    static func supportsAXPress(_ element: Element) -> Bool {
        var actions: CFArray?
        let error = AXUIElementCopyActionNames(element.underlyingElement, &actions)
        return error == .success && (actions as? [String])?.contains(AXActionNames.kAXPressAction) == true
    }

    static func isEligiblePreparedButton(_ element: Element) -> Bool {
        element.isEnabled() == true && self.supportsAXPress(element)
    }

    static func sameElement(_ lhs: Element, _ rhs: Element) -> Bool {
        CFEqual(lhs.underlyingElement, rhs.underlyingElement)
    }

    static func rawElementPresence(_ retained: Element, in root: Element) -> DialogPresence {
        var visited: Set<Element> = []
        var stack = [root]
        var readable = true
        while let element = stack.popLast() {
            guard visited.insert(element).inserted else { continue }
            if self.sameElement(element, retained) {
                return .present
            }
            let traversal = self.traversalChildren(of: element)
            readable = readable && traversal.readable
            stack.append(contentsOf: traversal.elements.reversed())
        }
        return readable ? .absent : .unreadable
    }

    static func traversalChildren(of element: Element) -> (elements: [Element], readable: Bool) {
        let children = self.elements(for: kAXChildrenAttribute as String, on: element)
        let sheets = self.elements(for: AXAttributeNames.kAXSheetsAttribute, on: element)
        var combined: [Element] = []
        var seen: Set<Element> = []
        for child in sheets.elements + children.elements where seen.insert(child).inserted {
            combined.append(child)
        }
        return (combined, children.readable && sheets.readable)
    }

    static func elements(for attribute: String, on element: Element) -> (elements: [Element], readable: Bool) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element.underlyingElement, attribute as CFString, &value)
        switch error {
        case .success:
            guard let value else { return ([], true) }
            guard let elements = value as? [AXUIElement] else { return ([], false) }
            return (elements.map(Element.init), true)
        case .attributeUnsupported, .noValue:
            return ([], true)
        default:
            return ([], false)
        }
    }

    static func windowServerPresence(_ identity: WindowMutationIdentity) -> DialogPresence {
        let windows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            CGWindowID(identity.windowID)) as? [[String: Any]]
        return self.windowServerPresence(identity, windows: windows)
    }

    static func windowServerPresence(
        _ identity: WindowMutationIdentity,
        windows: [[String: Any]]?) -> DialogPresence
    {
        guard let windows else { return .unreadable }
        guard let window = windows.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == identity.windowID
        }) else { return .absent }
        guard let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber else { return .unreadable }
        return ownerPID.int32Value == identity.ownerProcessIdentifier ? .present : .absent
    }
}
