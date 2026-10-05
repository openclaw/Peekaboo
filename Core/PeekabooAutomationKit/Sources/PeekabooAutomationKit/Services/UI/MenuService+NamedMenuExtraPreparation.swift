import AppKit
import AXorcist
import PeekabooFoundation

struct NamedMenuBarTarget {
    let item: MenuBarItemInfo
    let extra: MenuExtraInfo
    let snapshot: MenuExtraAXSnapshot?
    let evidence: DesktopSelectedLeafEvidence
}

@MainActor
extension MenuService {
    /// Existing attested clients and background popover setup bind the displayed CG inventory.
    func displayedMenuBarSelection(named name: String, expectedEvidence: DesktopSelectedLeafEvidence) async throws
        -> DeterministicDesktopLeafSelector.Selection<MenuBarItemInfo>?
    {
        let items = try await self.listMenuBarItems(includeRaw: true)
        do {
            let selection = try MenuBarItemSelector.select(named: name, from: items)
            guard let current = selection.candidate.value.selectionEvidence,
                  expectedEvidence.hasSameResolvedLeaf(as: current)
            else { return nil }
            return selection
        } catch let error as DesktopLeafSelectionError {
            if case .notFound = error {
                return nil
            }
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: error.localizedDescription,
                hint: "Refresh the displayed menu bar item before retrying.")
        }
    }

    public func prepareMenuBarItem(named name: String) async throws -> MenuBarItemInfo {
        try await self.operationLaneCoordinator.run(scope: .global, access: .read) {
            try await self.resolveNamedMenuBarTarget(named: name).item
        }
    }

    func resolveNamedMenuBarTarget(named name: String) async throws -> NamedMenuBarTarget {
        let snapshots = try await self.menuExtraReaders.snapshots()
        try Task.checkCancellation()
        let windows = self.menuExtraReaders.windowExtras?() ?? self.getMenuBarItemsViaWindows()
        let displayBounds = self.menuExtraReaders.displayBounds?() ?? self.activeDisplayBounds()
        let axExtras = snapshots.map { snapshot -> MenuExtraInfo in
            let app = self.menuExtraReaders.application(snapshot.processIdentity.processIdentifier)
            let rawTitle = [snapshot.title, snapshot.help, snapshot.description, snapshot.identifier]
                .compactMap(sanitizedMenuText).first
            return MenuExtraInfo(
                title: self.makeMenuExtraDisplayName(
                    rawTitle: rawTitle,
                    ownerName: app.name,
                    bundleIdentifier: app.bundle,
                    identifier: snapshot.identifier),
                rawTitle: rawTitle,
                bundleIdentifier: app.bundle,
                ownerName: app.name,
                position: CGPoint(x: snapshot.frame.midX, y: snapshot.frame.midY),
                isVisible: Self.isMenuExtraFrameVisible(snapshot.frame, displayBounds: displayBounds),
                identifier: snapshot.identifier,
                ownerPID: snapshot.processIdentity.processIdentifier,
                source: "ax-extras")
        }
        let extras = Self.sortedMenuExtras(Self.mergeMenuExtras(accessibilityExtras: axExtras, fallbackExtras: windows))
        let candidates = try extras.enumerated().map { index, extra in
            try self.namedMenuBarCandidate(extra: extra, index: index, snapshots: snapshots)
        }
        let selection: DeterministicDesktopLeafSelector.Selection<NamedMenuBarCandidate>
        do {
            selection = try DeterministicDesktopLeafSelector.select(
                named: name, from: candidates, allowPartial: self.partialMatchEnabled)
        } catch let error as DesktopLeafSelectionError {
            switch error {
            case let .ambiguous(_, matches):
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "Menu bar item selector '\(name)' is ambiguous: \(matches.joined(separator: ", ")).",
                    hint: "Use an exact current item name or a displayed list index.")
            case .notFound, .invalidIndex:
                throw PeekabooError.menuItemNotFound(name)
            }
        }
        let selected = selection.candidate.value
        guard let process = selected.processIdentity, let frame = selected.frame,
              selected.snapshot != nil || selected.windowIdentity != nil
        else { throw Self.changedMenuExtraTarget() }
        guard self.menuExtraReaders.processGeneration(process.processIdentifier) == process.processStartIdentity else {
            throw Self.changedMenuExtraTarget()
        }
        let evidence = try DesktopSelectedLeafEvidence(
            kind: .menuBarItem,
            normalizedSelector: selection.normalizedSelector,
            matchKind: selection.matchKind,
            selectedProcessIdentity: process,
            selectedWindowIdentity: selected.windowIdentity,
            selectedIndex: selection.candidate.index,
            selectedTitle: selected.item.title ?? selected.extra.title,
            selectedIdentifier: selected.extra.identifier,
            selectedRole: selected.snapshot?.role ?? "AXStatusItem",
            selectedSubrole: selected.snapshot?.subrole ?? selected.extra.source,
            selectedFrame: frame,
            candidateSetSHA256: selection.candidateSetSHA256,
            candidateCount: selection.candidateCount)
        return NamedMenuBarTarget(
            item: Self.namedMenuBarItem(extra: selected.extra, index: selection.candidate.index, evidence: evidence),
            extra: selected.extra,
            snapshot: selected.snapshot,
            evidence: evidence)
    }

    func dispatchNamedMenuBarTarget(_ target: NamedMenuBarTarget, named name: String) async throws
        -> UIAutomationActionResult<ClickResult>
    {
        let refreshed = try await self.resolveNamedMenuBarTarget(named: name)
        guard target.evidence.hasSameResolvedLeaf(as: refreshed.evidence),
              target.snapshot?.identity == refreshed.snapshot?.identity,
              refreshed.extra.isVisible
        else { throw Self.changedMenuExtraTarget() }
        try Self.checkMenuBarDispatchCancellation()
        guard let snapshot = refreshed.snapshot else {
            return try await self.dispatchMenuBarWindow(
                extra: refreshed.extra,
                evidence: refreshed.evidence,
                index: refreshed.item.index,
                normalizedSelector: refreshed.evidence.normalizedSelector,
                matchKind: refreshed.evidence.matchKind)
        }
        guard self.menuExtraReaders.processGeneration(snapshot.processIdentity.processIdentifier) ==
            snapshot.processIdentity.processStartIdentity
        else { throw Self.changedMenuExtraTarget() }
        do {
            try Self.dispatchMenuExtraAccessibilityAction(
                title: name,
                supportsShowMenu: snapshot.actions.contains(AXActionNames.kAXShowMenuAction),
                supportsPress: snapshot.actions.contains(AXActionNames.kAXPressAction),
                showMenu: { try self.menuExtraReaders.submit(snapshot, true) },
                press: { try self.menuExtraReaders.submit(snapshot, false) })
        } catch let failure as DesktopActionFailure {
            throw failure.attributed(to: snapshot.processIdentity.actionTargetReceipt)
                .selectingLeaves([refreshed.evidence])
        }
        return try UIAutomationActionResult(
            payload: ClickResult(elementDescription: "Menu bar item: \(name)", location: nil),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one),
            targetIdentity: DesktopTargetIdentity(processIdentity: snapshot.processIdentity),
            selectedLeafEvidence: [refreshed.evidence])
    }

    static func changedMenuExtraTarget() -> DesktopActionFailure {
        .preDispatchRefusal(
            reason: .targetUnavailable,
            message: "The selected menu bar item changed identity, order, or owner before dispatch.",
            hint: "Prepare the named menu bar item again before retrying.")
    }

    private struct NamedMenuBarCandidate {
        let item: MenuBarItemInfo
        let extra: MenuExtraInfo
        let snapshot: MenuExtraAXSnapshot?
        let windowIdentity: WindowMutationIdentity?
        let processIdentity: ApplicationProcessIdentity?
        let frame: CGRect?
    }

    private func namedMenuBarCandidate(extra: MenuExtraInfo, index: Int, snapshots: [MenuExtraAXSnapshot]) throws
        -> DeterministicDesktopLeafSelector.Candidate<NamedMenuBarCandidate>
    {
        let windowIdentity = extra.windowID.flatMap { self.menuExtraReaders.windowIdentity($0) }
        let snapshot: MenuExtraAXSnapshot?
        if extra.windowID == nil, extra.source == "ax-extras" {
            let matches = snapshots.filter {
                $0.processIdentity.processIdentifier == extra.ownerPID && $0.identifier == extra.identifier &&
                    CGPoint(x: $0.frame.midX, y: $0.frame.midY) == extra.position
            }
            guard matches.count == 1 else { throw MenuExtraAXReader.incomplete }
            snapshot = matches[0]
        } else {
            snapshot = nil
        }
        if let windowIdentity, windowIdentity.ownerProcessIdentifier != extra.ownerPID {
            throw MenuExtraAXReader.incomplete
        }
        let processIdentity = snapshot?.processIdentity ?? windowIdentity?.processIdentity
        let frame = snapshot?.frame ?? windowIdentity?.capturedBounds
        let item = Self.namedMenuBarItem(extra: extra, index: index, evidence: nil)
        return DeterministicDesktopLeafSelector.Candidate(
            value: NamedMenuBarCandidate(
                item: item,
                extra: extra,
                snapshot: snapshot,
                windowIdentity: windowIdentity,
                processIdentity: processIdentity,
                frame: frame),
            index: index,
            displayName: extra.title,
            matchFields: MenuBarItemSelector.matchFields(for: item) +
                [snapshot?.title, snapshot?.help, snapshot?.description].compactMap(sanitizedMenuText),
            stableIdentity: DeterministicDesktopLeafSelector.stableIdentity([
                extra.ownerPID.map { String($0) }, processIdentity.map { String($0.processStartIdentity) },
                extra.windowID.map { String($0) }, extra.title, extra.rawTitle, extra.identifier,
                extra.bundleIdentifier, extra.ownerName, extra.source, frame.map { "\($0)" },
                "\(extra.position)", String(extra.isVisible),
            ]))
    }

    private static func namedMenuBarItem(extra: MenuExtraInfo, index: Int, evidence: DesktopSelectedLeafEvidence?)
        -> MenuBarItemInfo
    {
        MenuBarItemInfo(
            title: extra.title,
            index: index,
            isVisible: extra.isVisible,
            description: extra.identifier ?? extra.rawTitle,
            rawTitle: extra.rawTitle,
            bundleIdentifier: extra.bundleIdentifier,
            ownerName: extra.ownerName,
            frame: evidence?.selectedFrame,
            identifier: extra.identifier,
            axIdentifier: extra.identifier,
            axDescription: extra.rawTitle,
            rawWindowID: extra.windowID,
            rawWindowLayer: extra.windowLayer,
            rawOwnerPID: extra.ownerPID,
            rawSource: extra.source,
            selectionEvidence: evidence)
    }
}
