import AppKit
import AXorcist
import PeekabooFoundation

/// The retained owner-scoped preparation; its original selector is replayed only for read-only revalidation.
struct ScopedMenuBarTarget {
    let request: MenuBarItemPreparationRequest
    let item: MenuBarItemInfo
    let snapshot: MenuExtraAXSnapshot
    let evidence: DesktopSelectedLeafEvidence
}

@MainActor
extension MenuService {
    public func prepareMenuBarItem(_ request: MenuBarItemPreparationRequest) async throws -> MenuBarItemInfo {
        try await self.operationLaneCoordinator.run(scope: .global, access: .read) {
            try await self.resolveScopedMenuBarTarget(request).item
        }
    }

    func resolveScopedMenuBarTarget(
        _ request: MenuBarItemPreparationRequest,
        expectedIdentity: ApplicationProcessIdentity? = nil) async throws -> ScopedMenuBarTarget
    {
        try Task.checkCancellation()
        let application = try await self.menuExtraReaders.resolveOwner(
            request.applicationScope, self.applicationService, expectedIdentity)
        guard let owner = application.processIdentity,
              request.applicationScope.matches(application),
              expectedIdentity.map({ $0 == owner }) ?? true
        else { throw Self.changedMenuExtraTarget() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let snapshots = try await self.menuExtraReaders.snapshots(owner, deadline)
        try MenuExtraAXReader.check(deadline)
        guard snapshots.allSatisfy({ $0.processIdentity == owner }),
              self.menuExtraReaders.processGeneration(owner.processIdentifier) == owner.processStartIdentity
        else { throw Self.changedMenuExtraTarget() }
        var seen: Set<MenuExtraAXIdentity> = []
        let ordered = snapshots.filter { seen.insert($0.identity).inserted }.sorted {
            if $0.frame.minY != $1.frame.minY {
                return $0.frame.minY < $1.frame.minY
            }
            if $0.frame.minX != $1.frame.minX {
                return $0.frame.minX < $1.frame.minX
            }
            return ($0.identifier ?? $0.title ?? "") < ($1.identifier ?? $1.title ?? "")
        }
        let bounds = self.menuExtraReaders.displayBounds?() ?? self.activeDisplayBounds()
        let candidates = ordered.enumerated().map { index, snapshot in
            let item = self.scopedMenuBarItem(snapshot, application: application, index: index, bounds: bounds)
            return DeterministicDesktopLeafSelector.Candidate(
                value: snapshot,
                index: index,
                displayName: item.title ?? "Menu bar item",
                matchFields: [snapshot.title, snapshot.help, snapshot.description, snapshot.identifier]
                    .compactMap(sanitizedMenuText),
                stableIdentity: DeterministicDesktopLeafSelector.stableIdentity([
                    String(owner.processIdentifier), String(owner.processStartIdentity),
                    item.title, snapshot.identifier, snapshot.role, snapshot.subrole,
                    "\(snapshot.frame)",
                ]))
        }
        let selection: DeterministicDesktopLeafSelector.Selection<MenuExtraAXSnapshot>
        do {
            selection = try DeterministicDesktopLeafSelector.select(
                named: request.name, from: candidates, allowPartial: self.partialMatchEnabled)
        } catch let error as DesktopLeafSelectionError {
            switch error {
            case let .ambiguous(_, matches):
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "Menu bar item selector '\(request.name)' is ambiguous: " +
                        "\(matches.joined(separator: ", ")).",
                    hint: "Use one exact item name or identifier within the selected application.")
            case .notFound, .invalidIndex:
                throw PeekabooError.menuItemNotFound(request.name)
            }
        }
        let snapshot = selection.candidate.value
        let item = self.scopedMenuBarItem(
            snapshot, application: application, index: selection.candidate.index, bounds: bounds)
        let evidence = try DesktopSelectedLeafEvidence(
            kind: .menuBarItem,
            normalizedSelector: selection.normalizedSelector,
            matchKind: selection.matchKind,
            selectedProcessIdentity: owner,
            selectedIndex: selection.candidate.index,
            selectedTitle: item.title ?? "Menu bar item",
            selectedIdentifier: snapshot.identifier,
            selectedRole: snapshot.role,
            selectedSubrole: snapshot.subrole,
            selectedFrame: snapshot.frame,
            candidateSetSHA256: selection.candidateSetSHA256,
            candidateCount: selection.candidateCount)
        return ScopedMenuBarTarget(
            request: request,
            item: self.scopedMenuBarItem(
                snapshot,
                application: application,
                index: selection.candidate.index,
                bounds: bounds,
                evidence: evidence),
            snapshot: snapshot,
            evidence: evidence)
    }

    func executeScopedMenuBarAction(_ request: MenuBarItemActionRequest) async throws
        -> UIAutomationActionResult<ClickResult>
    {
        guard let name = request.name, let scope = request.applicationScope else {
            throw PeekabooError.invalidInput("Scoped menu bar mutation requires a name and an application owner")
        }
        let preparation = try MenuBarItemPreparationRequest(name: name, applicationScope: scope)
        let target = try await self.resolveScopedMenuBarTarget(
            preparation, expectedIdentity: request.expectedLeafEvidence.selectedProcessIdentity)
        guard request.expectedLeafEvidence.hasSameResolvedLeaf(as: target.evidence) else {
            throw Self.changedMenuExtraTarget()
        }
        let refreshed = try await self.resolveScopedMenuBarTarget(
            target.request, expectedIdentity: target.snapshot.processIdentity)
        guard target.evidence.hasSameResolvedLeaf(as: refreshed.evidence),
              target.snapshot.identity == refreshed.snapshot.identity,
              refreshed.item.isVisible,
              self.menuExtraReaders.processGeneration(refreshed.snapshot.processIdentity.processIdentifier) ==
              refreshed.snapshot.processIdentity.processStartIdentity
        else { throw Self.changedMenuExtraTarget() }
        try Self.checkMenuBarDispatchCancellation()
        let snapshot = refreshed.snapshot
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
            message: "The scoped menu bar item changed its application owner, process generation, or selected leaf.",
            hint: "Prepare the same explicit application and item again before retrying.")
    }

    private func scopedMenuBarItem(
        _ snapshot: MenuExtraAXSnapshot,
        application: ServiceApplicationInfo,
        index: Int,
        bounds: [CGRect],
        evidence: DesktopSelectedLeafEvidence? = nil) -> MenuBarItemInfo
    {
        let rawTitle = [snapshot.title, snapshot.help, snapshot.description, snapshot.identifier]
            .compactMap(sanitizedMenuText).first
        let title = self.makeMenuExtraDisplayName(
            rawTitle: rawTitle,
            ownerName: application.name,
            bundleIdentifier: application.bundleIdentifier,
            identifier: snapshot.identifier)
        return MenuBarItemInfo(
            title: title,
            index: index,
            isVisible: Self.isMenuExtraFrameVisible(snapshot.frame, displayBounds: bounds),
            description: snapshot.description,
            rawTitle: rawTitle,
            bundleIdentifier: application.bundleIdentifier,
            ownerName: application.name,
            frame: snapshot.frame,
            identifier: snapshot.identifier,
            axIdentifier: snapshot.identifier,
            axDescription: snapshot.help ?? snapshot.description,
            rawOwnerPID: snapshot.processIdentity.processIdentifier,
            rawSource: "ax-extras",
            selectionEvidence: evidence)
    }
}
