import AppKit
import AXorcist
import PeekabooFoundation

struct LegacyAXMenuExtraSnapshot {
    let element: Element
    let index: Int
    let title: String
    let matchFields: [String]
    let identifier: String?
    let role: String
    let subrole: String?
    let frame: CGRect
    let processIdentity: ApplicationProcessIdentity
}

struct LegacyAXMenuExtraInventory {
    let snapshots: [LegacyAXMenuExtraSnapshot]
    let extraCount: Int
    let allPositions: [CGPoint]
}

@MainActor
struct LegacyMenuExtraNativeAccess {
    var inventory: @MainActor (String) throws -> LegacyAXMenuExtraInventory = Self.readInventory
    var supportsAction: @MainActor (Element, String) -> Bool = { $0.isActionSupported($1) }
    var submit: @MainActor (Element, Bool) throws -> Void = { element, showMenu in
        try element.performAction(showMenu ? .showMenu : .press)
    }

    private static func readInventory(title: String) throws -> LegacyAXMenuExtraInventory {
        guard let menuBar = Element.systemWide().menuBar() else {
            throw PeekabooError.operationError(message: "System menu bar not found")
        }
        let groups = (menuBar.children(strict: true) ?? []).filter { $0.role() == "AXGroup" }
        guard !groups.isEmpty else {
            throw NotFoundError(
                code: .menuNotFound,
                userMessage: "Menu extras group not found in system menu bar",
                context: ["menuExtra": title])
        }
        let extras = groups.flatMap { $0.children(strict: true) ?? [] }
        let snapshots = extras.indexed().compactMap { index, element -> LegacyAXMenuExtraSnapshot? in
            let fields = [element.title(), element.help(), element.descriptionText(), element.identifier()]
                .compactMap { sanitizedMenuText($0) }
            guard let displayTitle = fields.first,
                  let frame = element.frame(), !frame.isEmpty,
                  let ownerPID = element.pid(), ownerPID > 0,
                  let generation = SystemIdentityResolver.processStartIdentity(ownerPID)
            else { return nil }
            return LegacyAXMenuExtraSnapshot(
                element: element,
                index: index,
                title: displayTitle,
                matchFields: fields,
                identifier: element.identifier(),
                role: element.role() ?? "AXStatusItem",
                subrole: element.subrole(),
                frame: frame,
                processIdentity: .init(processIdentifier: ownerPID, processStartIdentity: generation))
        }
        return LegacyAXMenuExtraInventory(
            snapshots: snapshots, extraCount: extras.count, allPositions: extras.compactMap { $0.position() })
    }
}

struct LegacyAXMenuExtraTarget {
    let snapshot: LegacyAXMenuExtraSnapshot
    let evidence: DesktopSelectedLeafEvidence
    let allPositions: [CGPoint]
}

@MainActor
extension MenuService {
    private func resolveLegacyAXMenuExtra(title: String) throws -> LegacyAXMenuExtraTarget {
        let inventory = try self.legacyMenuExtraAccess.inventory(title)
        let candidates = inventory.snapshots.map { snapshot in
            DeterministicDesktopLeafSelector.Candidate(
                value: snapshot,
                index: snapshot.index,
                displayName: snapshot.title,
                matchFields: snapshot.matchFields,
                stableIdentity: DeterministicDesktopLeafSelector.stableIdentity([
                    String(snapshot.processIdentity.processIdentifier),
                    String(snapshot.processIdentity.processStartIdentity),
                    snapshot.identifier == nil ? snapshot.title : nil,
                    snapshot.identifier, snapshot.role, snapshot.subrole, "\(snapshot.frame)",
                ]))
        }
        let selection: DeterministicDesktopLeafSelector.Selection<LegacyAXMenuExtraSnapshot>
        do {
            selection = try DeterministicDesktopLeafSelector.select(
                named: title, from: candidates, allowPartial: self.partialMatchEnabled)
        } catch let error as DesktopLeafSelectionError {
            if case let .ambiguous(_, matches) = error {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "Menu bar item selector '\(title)' is ambiguous: \(matches.joined(separator: ", ")).",
                    hint: "Use the exact status-item title or a current list index.")
            }
            throw NotFoundError(
                code: .menuNotFound,
                userMessage: "Menu extra '\(title)' not found in system menu bar",
                context: ["menuExtra": title, "availableExtras": String(inventory.extraCount)])
        }
        let selected = selection.candidate.value
        let evidence = try DesktopSelectedLeafEvidence(
            kind: .menuBarItem,
            normalizedSelector: selection.normalizedSelector,
            matchKind: selection.matchKind,
            selectedProcessIdentity: selected.processIdentity,
            selectedIndex: selected.index,
            selectedTitle: selected.title,
            selectedIdentifier: selected.identifier,
            selectedRole: selected.role,
            selectedSubrole: selected.subrole,
            selectedFrame: selected.frame,
            candidateSetSHA256: selection.candidateSetSHA256,
            candidateCount: selection.candidateCount)
        return LegacyAXMenuExtraTarget(snapshot: selected, evidence: evidence, allPositions: inventory.allPositions)
    }

    func clickMenuExtraWithOwnedLane(title: String) async throws -> LegacyAXMenuExtraTarget {
        let target = try self.resolveLegacyAXMenuExtra(title: title)
        let bounds = self.menuExtraReaders.displayBounds?() ?? self.activeDisplayBounds()
        if Self.isIndividuallyHiddenMenuExtra(
            position: CGPoint(x: target.snapshot.frame.midX, y: target.snapshot.frame.midY),
            allPositions: target.allPositions,
            displayBounds: bounds)
        {
            throw PeekabooError.operationError(message: self.hiddenMenuExtraMessage(title: title))
        }
        let refreshed = try self.resolveLegacyAXMenuExtra(title: title)
        guard target.snapshot.element == refreshed.snapshot.element,
              target.evidence.hasSameResolvedLeaf(as: refreshed.evidence),
              self.menuExtraReaders.processGeneration(refreshed.snapshot.processIdentity.processIdentifier) ==
              refreshed.snapshot.processIdentity.processStartIdentity
        else {
            throw PeekabooError.serviceUnavailable(
                "Menu extra '\(title)' changed identity, order, or owner before dispatch")
        }
        let element = refreshed.snapshot.element
        do {
            try Self.dispatchMenuExtraAccessibilityAction(
                title: title,
                supportsShowMenu: self.legacyMenuExtraAccess.supportsAction(element, AXActionNames.kAXShowMenuAction),
                supportsPress: self.legacyMenuExtraAccess.supportsAction(element, AXActionNames.kAXPressAction),
                showMenu: { try self.legacyMenuExtraAccess.submit(element, true) },
                press: { try self.legacyMenuExtraAccess.submit(element, false) })
        } catch let failure as DesktopActionFailure {
            throw failure.attributed(to: refreshed.snapshot.processIdentity.actionTargetReceipt)
                .selectingLeaves([refreshed.evidence])
        }
        return refreshed
    }

    static func withNamedMenuExtraLookupFallback<Result>(
        _ primary: @MainActor () async throws -> Result,
        fallback: @MainActor () async throws -> Result) async throws -> Result
    {
        do {
            return try await primary()
        } catch let failure as DesktopActionFailure {
            let outcome = failure.outcome
            guard outcome.state == .refused,
                  let refusalReason = outcome.refusalReason,
                  [DesktopActionOutcome.RefusalReason.targetUnavailable, .operationUnsupported].contains(refusalReason),
                  outcome.dispatchState == .none, outcome.retrySafety == .safe
            else { throw failure }
        } catch is NotFoundError {
            // The legacy AX path raises lookup errors only before dispatch.
        } catch let error as PeekabooError {
            switch error {
            case .serviceUnavailable, .operationError:
                break
            default:
                throw error
            }
        }
        return try await fallback()
    }
}
