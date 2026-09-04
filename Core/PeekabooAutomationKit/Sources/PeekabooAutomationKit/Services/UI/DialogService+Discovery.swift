import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    struct DiscoveredCandidate {
        let owner: ServiceApplicationInfo
        let window: Element
        let dialog: Element
        let elements: DialogElements
        let target: TargetedDialogCandidate?
        let source: String
    }

    struct DiscoveryScan {
        var candidates: [DiscoveredCandidate] = []
        var owners: [ApplicationProcessIdentity] = []
        var issues: [String] = []

        var inventory: DialogDiscoveryInventory {
            DialogDiscoveryInventory(
                dialogs: self.candidates.map {
                    DiscoveredDialog(
                        owner: $0.owner,
                        elements: $0.elements,
                        source: $0.source)
                },
                isComplete: self.issues.isEmpty,
                issues: self.issues)
        }
    }

    func discoverDialogCandidates() throws -> DiscoveryScan {
        var scan = DiscoveryScan()
        let deadline = self.discoveryReaders.now().addingTimeInterval(3)
        let focused = self.discoveryReaders.focusedOwners()
        let owners = self.discoveryReaders.applications().filter {
            focused.contains($0.processIdentifier) || DialogSystemAlertHosts.contains($0)
        }
        if !focused.filter({ $0 > 0 }).isSubset(of: Set(owners.map(\.processIdentifier))) {
            scan.issues.append("Focused owner is missing from the process catalog")
        }
        if owners.count > 8 {
            scan.issues.append("Owner limit exceeded")
        }
        var seenOwners: Set<Int32> = []
        for owner in owners.prefix(8) where seenOwners.insert(owner.processIdentifier).inserted {
            try Task.checkCancellation()
            guard self.discoveryReaders.now() < deadline else {
                scan.issues.append("Discovery deadline exceeded")
                break
            }
            guard let identity = owner.processIdentity else {
                scan.issues.append("\(owner.name) PID \(owner.processIdentifier): missing process generation")
                continue
            }
            scan.owners.append(identity)
            let windows = self.discoveryReaders.windows(owner.processIdentifier)
            if !windows.readable || windows.elements.count > 16 {
                scan.issues.append("\(owner.name) PID \(owner.processIdentifier): incomplete AXWindows")
            }
            var seenWindows: Set<Element> = []
            for (index, window) in windows.elements.prefix(16).enumerated()
                where seenWindows.insert(window).inserted
            {
                let tree = self.discoveryTree(
                    window,
                    owner: identity.processIdentifier,
                    deadline: deadline)
                if !tree.readable {
                    scan.issues.append("\(owner.name) PID \(owner.processIdentifier): incomplete dialog hierarchy")
                }
                let dialogs = DialogTraversal.preferredStructuralDialogs(
                    in: window,
                    candidates: tree.elements.filter {
                        DialogElementClassifier.isStructuralDialog(DialogElementClassifier.evidence(for: $0))
                    })
                for dialog in dialogs {
                    let metadata = self.discoveryTree(
                        dialog,
                        owner: identity.processIdentifier,
                        deadline: deadline)
                    if !metadata.readable || metadata.elements.contains(where: {
                        $0.role() == "AXButton" &&
                            ($0.isEnabled() == nil || self.discoveryReaders.supportsPress($0) == nil)
                    }) {
                        scan.issues.append("\(owner.name): incomplete dialog controls")
                    }
                    let target = try self.discoveredTarget(
                        owner: owner,
                        window: window,
                        dialog: dialog,
                        index: index)
                    if target == nil {
                        scan.issues.append("\(owner.name): dialog has no exact parent window receipt")
                    }
                    scan.candidates.append(DiscoveredCandidate(
                        owner: owner,
                        window: window,
                        dialog: dialog,
                        elements: self.discoveredElements(
                            dialog,
                            nodes: metadata.elements,
                            target: target?.resolvedTarget),
                        target: target,
                        source: DialogSystemAlertHosts.contains(owner) ? "system_alert_host" : "focused_owner"))
                }
            }
            guard let current = self.discoveryReaders.currentApplication(owner.processIdentifier),
                  current.processIdentity == identity,
                  current.bundleIdentifier == owner.bundleIdentifier,
                  current.executablePath == owner.executablePath,
                  current.bundlePath == owner.bundlePath
            else {
                scan.issues.append("\(owner.name) PID \(owner.processIdentifier): owner changed during discovery")
                continue
            }
        }
        // Detect a host starting or exiting while we read AX; absence is not a stable inventory in that case.
        let finalOwners = self.discoveryReaders.applications().filter {
            focused.contains($0.processIdentifier) || DialogSystemAlertHosts.contains($0)
        }
        if finalOwners.sorted(by: { $0.processIdentifier < $1.processIdentifier }).map(\.processIdentity) !=
            owners.sorted(by: { $0.processIdentifier < $1.processIdentifier }).map(\.processIdentity)
        {
            scan.issues.append("Dialog owner catalog changed during discovery")
        }
        if self.discoveryReaders.now() >= deadline {
            scan.issues.append("Discovery deadline exceeded")
        }
        return scan
    }

    func discoveryTree(
        _ root: Element,
        owner: Int32,
        deadline: Date)
        -> DialogDiscoveryReaders.ElementRead
    {
        var visited: Set<Element> = []
        var nodes: [Element] = []
        var stack = [(root, 0)]
        var readable = true
        while let (element, depth) = stack.popLast() {
            guard visited.insert(element).inserted else { continue }
            guard nodes.count < 256, depth <= 16, self.discoveryReaders.now() < deadline else {
                readable = false
                break
            }
            AXUIElementSetMessagingTimeout(element.underlyingElement, 0.05)
            guard self.discoveryReaders.ownerPID(element) == owner else {
                readable = false
                continue
            }
            let role = element.role()
            if !self.discoveryReaders.classificationReadable(element) {
                readable = false
            }
            if element != root {
                if role == "AXApplication" {
                    continue
                }
                if role == "AXWindow",
                   !DialogElementClassifier.isStructuralDialog(DialogElementClassifier.evidence(for: element))
                {
                    continue
                }
            }
            guard role != nil else {
                readable = false
                continue
            }
            nodes.append(element)
            let children = self.discoveryReaders.children(element)
            readable = readable && children.readable
            guard children.elements.count <= 256 else {
                readable = false
                continue
            }
            stack.append(contentsOf: children.elements.reversed().map { ($0, depth + 1) })
        }
        return (nodes, readable)
    }

    private func discoveredTarget(
        owner: ServiceApplicationInfo,
        window: Element,
        dialog: Element,
        index: Int) throws -> TargetedDialogCandidate?
    {
        guard let info = self.discoveryReaders.windowReceipt(window, owner, index),
              info.mutationIdentity?.processIdentity == owner.processIdentity
        else { return nil }
        let exact = try UIAutomationTarget.ExactWindow(window: info)
        return try TargetedDialogCandidate(
            target: exact,
            resolvedTarget: ResolvedDialogTargetEvidence(
                target: exact,
                application: owner,
                window: info),
            window: window,
            dialog: dialog)
    }

    private func discoveredElements(
        _ dialog: Element,
        nodes: [Element],
        target: ResolvedDialogTargetEvidence?) -> DialogElements
    {
        DialogElements(
            dialogInfo: DialogInfo(
                title: dialog.title() ?? "",
                role: dialog.role() ?? "Unknown",
                subrole: dialog.subrole(),
                isFileDialog: self.isFileDialogElement(dialog),
                bounds: self.elementBounds(for: dialog)),
            buttons: nodes.filter { $0.role() == "AXButton" }.map {
                DialogButton(
                    title: Self.discoveredButtonName($0),
                    isEnabled: $0.isEnabled() == true,
                    isDefault: $0.attribute(Attribute<Bool>("AXDefault")) == true,
                    supportsAXPress: self.discoveryReaders.supportsPress($0))
            },
            textFields: nodes.filter { $0.role() == "AXTextField" || $0.role() == "AXTextArea" }
                .enumerated().map { index, field in
                    DialogTextField(
                        title: field.title(),
                        value: field.value() as? String,
                        placeholder: field.attribute(Attribute<String>("AXPlaceholderValue")),
                        index: index,
                        isEnabled: field.isEnabled() ?? true)
                },
            staticTexts: nodes.filter { $0.role() == "AXStaticText" }.compactMap {
                [$0.value() as? String, $0.title(), $0.label(), $0.descriptionText()].compactMap(\.self)
                    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            },
            resolvedTarget: target)
    }

    static func discoveredButtonName(_ element: Element) -> String {
        [element.title(), element.label(), element.descriptionText()].compactMap(\.self)
            .first { !$0.isEmpty } ?? ""
    }

    func discoveredActionCandidate(for request: DialogActionPreparationRequest) throws -> PreparedActionCandidate {
        let scan = try self.discoverDialogCandidates()
        guard scan.issues.isEmpty, scan.candidates.count == 1,
              let selected = scan.candidates.first, let target = selected.target
        else { throw self.discoveryRefusal(
            scan,
            message: "Automatic dialog discovery is incomplete or ambiguous.") }
        let buttons = self.discoveredMatchingButtons(
            in: selected.dialog,
            request: request)
        guard buttons.readable, buttons.elements.count == 1, let button = buttons.elements.first else {
            throw self.discoveryRefusal(
                scan,
                message: "Automatic click requires one exact enabled AXPress button.")
        }
        return try PreparedActionCandidate(
            target: target.target,
            resolvedTarget: self.resolvedTargetWithUniqueWindowProof(
                target,
                candidates: [target]),
            window: selected.window,
            dialog: selected.dialog,
            button: button,
            discoveryProof: DialogDiscoverySelectionProof(
                scannedOwners: scan.owners,
                isComplete: true,
                dialogCount: scan.candidates.count,
                enabledPressButtonCount: buttons.elements.count,
                buttonTitle: Self.discoveredButtonName(button)))
    }

    func discoveredMatchingButtons(
        in dialog: Element,
        request: DialogActionPreparationRequest)
        -> DialogDiscoveryReaders.ElementRead
    {
        let tree = self.discoveryTree(
            dialog,
            owner: self.discoveryReaders.ownerPID(dialog) ?? 0,
            deadline: self.discoveryReaders.now().addingTimeInterval(1))
        let matches = tree.elements.filter {
            $0.role() == "AXButton" && $0.isEnabled() == true && self.discoveryReaders.supportsPress($0) == true &&
                DialogDiscoverySelectionProof.canonicalButtonName(Self.discoveredButtonName($0)) ==
                DialogDiscoverySelectionProof.canonicalButtonName(request.buttonText ?? "")
        }
        let controlsReadable = tree.elements.filter { $0.role() == "AXButton" }.allSatisfy {
            $0.isEnabled() != nil && self.discoveryReaders.supportsPress($0) != nil
        }
        return (matches, tree.readable && controlsReadable)
    }

    func discoveryRefusal(
        _ scan: DiscoveryScan,
        message: String) -> DesktopActionFailure
    {
        let candidates = scan.candidates.map {
            let buttons = $0.elements.buttons.map {
                "\($0.title) [enabled=\($0.isEnabled), AXPress=\($0.supportsAXPress == true)]"
            }.joined(separator: ", ")
            return "\($0.owner.name) (\($0.owner.bundleIdentifier ?? "unknown"), PID \($0.owner.processIdentifier)), " +
                "window \($0.target.map { String($0.target.identity.windowID) } ?? "unaddressable"): \(buttons)"
        }.joined(separator: "; ")
        return .preDispatchRefusal(
            reason: .targetUnavailable,
            message: message,
            hint: "Candidates: \(candidates.isEmpty ? "none" : candidates). " + scan.issues.joined(separator: "; "))
    }
}
