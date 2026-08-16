//
//  MenuService+Extras.swift
//  PeekabooCore
//

import AppKit
import AXorcist
import CoreFoundation
import CoreGraphics
import Foundation
import PeekabooFoundation

private struct AXMenuExtraSnapshot {
    let element: Element
    let index: Int
    let title: String
    let identifier: String?
    let role: String
    let subrole: String?
    let frame: CGRect
    let processIdentity: ApplicationProcessIdentity
}

private struct AXMenuExtraTarget {
    let snapshot: AXMenuExtraSnapshot
    let evidence: DesktopSelectedLeafEvidence
    let allPositions: [CGPoint]
}

@MainActor
extension MenuService {
    private var menuBarAXTimeoutSec: Float {
        0.25
    }

    private var deepMenuBarAXSweepEnabled: Bool {
        ProcessInfo.processInfo.environment["PEEKABOO_MENUBAR_DEEP_AX_SWEEP"] == "1"
    }

    private var menuBarAXAugmentationEnabled: Bool {
        ProcessInfo.processInfo.environment["PEEKABOO_MENUBAR_AUGMENT_AX"] == "1"
    }

    public func clickMenuExtra(title: String) async throws {
        _ = try await self.clickMenuExtraActionResult(title: title)
    }

    public func clickMenuExtraActionResult(title: String) async throws -> UIAutomationActionResult<Void> {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            let target = try await self.clickMenuExtraWithOwnedLane(title: title)
            return try UIAutomationActionResult(
                payload: (),
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                targetIdentity: DesktopTargetIdentity(processIdentity: target.snapshot.processIdentity),
                selectedLeafEvidence: [target.evidence])
        }
    }

    private func resolveAXMenuExtra(title: String) throws -> AXMenuExtraTarget {
        let systemWide = Element.systemWide()

        guard let menuBar = systemWide.menuBar() else {
            throw PeekabooError.operationError(message: "System menu bar not found")
        }

        let menuBarItems = menuBar.children(strict: true) ?? []
        let menuExtrasGroups = menuBarItems.filter { $0.role() == "AXGroup" }
        guard !menuExtrasGroups.isEmpty else {
            var context = ErrorContext()
            context.add("menuExtra", title)
            throw NotFoundError(
                code: .menuNotFound,
                userMessage: "Menu extras group not found in system menu bar",
                context: context.build())
        }

        let extras = menuExtrasGroups.flatMap { $0.children(strict: true) ?? [] }
        let snapshots = extras.indexed().compactMap { index, element -> AXMenuExtraSnapshot? in
            let fields = [element.title(), element.help(), element.descriptionText(), element.identifier()]
                .compactMap { sanitizedMenuText($0) }
            guard let displayTitle = fields.first,
                  let frame = element.frame(),
                  !frame.isEmpty,
                  let ownerPID = element.pid(),
                  ownerPID > 0,
                  let processStartIdentity = SystemIdentityResolver.processStartIdentity(ownerPID)
            else { return nil }
            return AXMenuExtraSnapshot(
                element: element,
                index: index,
                title: displayTitle,
                identifier: element.identifier(),
                role: element.role() ?? "AXStatusItem",
                subrole: element.subrole(),
                frame: frame,
                processIdentity: .init(
                    processIdentifier: ownerPID,
                    processStartIdentity: processStartIdentity))
        }
        let candidates = snapshots.map { snapshot in
            let stableTitle = snapshot.identifier == nil ? snapshot.title : nil
            return DeterministicDesktopLeafSelector.Candidate(
                value: snapshot,
                index: snapshot.index,
                displayName: snapshot.title,
                matchFields: [
                    snapshot.element.title(),
                    snapshot.element.help(),
                    snapshot.element.descriptionText(),
                    snapshot.identifier,
                ].compactMap { sanitizedMenuText($0) },
                stableIdentity: DeterministicDesktopLeafSelector.stableIdentity([
                    String(snapshot.processIdentity.processIdentifier),
                    String(snapshot.processIdentity.processStartIdentity),
                    stableTitle,
                    snapshot.identifier,
                    snapshot.role,
                    snapshot.subrole,
                    "\(snapshot.frame)",
                ]))
        }
        let selection: DeterministicDesktopLeafSelector.Selection<AXMenuExtraSnapshot>
        do {
            selection = try DeterministicDesktopLeafSelector.select(
                named: title,
                from: candidates,
                allowPartial: self.partialMatchEnabled)
        } catch let error as DesktopLeafSelectionError {
            if case let .ambiguous(_, matches) = error {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "Menu bar item selector '\(title)' is ambiguous: \(matches.joined(separator: ", ")).",
                    hint: "Use the exact status-item title or a current list index.")
            }
            var context = ErrorContext()
            context.add("menuExtra", title)
            context.add("availableExtras", extras.count)
            throw NotFoundError(
                code: .menuNotFound,
                userMessage: "Menu extra '\(title)' not found in system menu bar",
                context: context.build())
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
        return AXMenuExtraTarget(
            snapshot: selected,
            evidence: evidence,
            allPositions: extras.compactMap { $0.position() })
    }

    private func clickMenuExtraWithOwnedLane(title: String) async throws -> AXMenuExtraTarget {
        let target = try self.resolveAXMenuExtra(title: title)
        if Self.isIndividuallyHiddenMenuExtra(
            position: CGPoint(x: target.snapshot.frame.midX, y: target.snapshot.frame.midY),
            allPositions: target.allPositions,
            displayBounds: self.activeDisplayBounds())
        {
            throw PeekabooError.operationError(message: self.hiddenMenuExtraMessage(title: title))
        }

        let refreshed = try self.resolveAXMenuExtra(title: title)
        guard target.snapshot.element == refreshed.snapshot.element,
              target.evidence.hasSameResolvedLeaf(as: refreshed.evidence),
              SystemIdentityResolver.processStartIdentity(refreshed.snapshot.processIdentity.processIdentifier) ==
              refreshed.snapshot.processIdentity.processStartIdentity
        else {
            throw PeekabooError.serviceUnavailable(
                "Menu extra '\(title)' changed identity, order, or owner before dispatch")
        }

        do {
            try Self.dispatchMenuExtraAccessibilityAction(
                title: title,
                supportsShowMenu: refreshed.snapshot.element.isActionSupported(AXActionNames.kAXShowMenuAction),
                supportsPress: refreshed.snapshot.element.isActionSupported(AXActionNames.kAXPressAction),
                showMenu: { try refreshed.snapshot.element.performAction(.showMenu) },
                press: { try refreshed.snapshot.element.performAction(.press) })
        } catch let failure as DesktopActionFailure {
            throw failure
                .attributed(to: refreshed.snapshot.processIdentity)
                .selectingLeaves([refreshed.evidence])
        }
        return refreshed
    }

    static func dispatchMenuExtraAccessibilityAction(
        title: String,
        supportsShowMenu: Bool,
        supportsPress: Bool,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() },
        showMenu: @escaping () throws -> Void,
        press: @escaping () throws -> Void) throws
    {
        let action: String
        let submit: () throws -> Void
        if supportsShowMenu {
            action = "show menu"
            submit = showMenu
        } else if supportsPress {
            action = "press"
            submit = press
        } else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "Menu extra '\(title)' exposes neither AXShowMenu nor AXPress.",
                hint: "Choose a menu extra that exposes one supported accessibility action.")
        }

        do {
            try checkCancellation()
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .requestCancelled,
                message: "Menu extra '\(title)' was cancelled before \(action) submission.",
                hint: "Submit a new request only if the menu-extra action is still wanted.")
        }
        do {
            try submit()
        } catch {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Menu extra '\(title)' returned without reliable \(action) dispatch evidence.",
                hint: "Observe the menu extra before retrying; do not submit a fallback action blindly.",
                causeDescription: error.localizedDescription)
        }
    }

    public func isMenuExtraMenuOpen(title: String, ownerPID: pid_t?) async throws -> Bool {
        let timeoutSeconds = max(TimeInterval(self.menuBarAXTimeoutSec), 0.5)
        do {
            return try await AXTimeoutHelper.withTimeout(
                seconds: timeoutSeconds)
            { [self] in
                await MainActor.run {
                    self.isMenuExtraMenuOpenInternal(
                        title: title,
                        ownerPID: ownerPID,
                        timeout: Float(timeoutSeconds))
                }
            }
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            self.logger.debug("Menu extra open check timed out: \(error.localizedDescription)")
            return false
        }
    }

    public func menuExtraOpenMenuFrame(title: String, ownerPID: pid_t?) async throws -> CGRect? {
        let timeoutSeconds = max(TimeInterval(self.menuBarAXTimeoutSec), 0.5)
        do {
            return try await AXTimeoutHelper.withTimeout(
                seconds: timeoutSeconds)
            { [self] in
                await MainActor.run {
                    self.menuExtraOpenMenuFrameInternal(
                        title: title,
                        ownerPID: ownerPID,
                        timeout: Float(timeoutSeconds))
                }
            }
        } catch {
            self.logger.debug("Menu extra open frame check timed out: \(error.localizedDescription)")
            return nil
        }
    }

    public func listMenuExtras() async throws -> [MenuExtraInfo] {
        // Menu bar enumeration must never hang: agents depend on this returning quickly.
        // AX can block on misbehaving apps; keep the default path cheap and bounded.
        let windowExtras = self.getMenuBarItemsViaWindows()

        // Fast path: WindowServer enumeration is usually sufficient and avoids AX calls entirely.
        // Only fall back to accessibility sweeps when explicitly enabled, or when WindowServer returns nothing.
        if !windowExtras.isEmpty,
           !self.deepMenuBarAXSweepEnabled,
           !self.menuBarAXAugmentationEnabled
        {
            return Self.sortedMenuExtras(windowExtras)
        }

        let axExtras = self.getMenuBarItemsViaAccessibility(timeout: self.menuBarAXTimeoutSec)
        let controlCenterExtras = self.getMenuBarItemsFromControlCenterAX(timeout: self.menuBarAXTimeoutSec)

        let appAXExtras: [MenuExtraInfo] = if self.deepMenuBarAXSweepEnabled {
            self.getMenuBarItemsFromAppsAX(
                timeout: self.menuBarAXTimeoutSec,
                apps: NSWorkspace.shared.runningApplications)
        } else {
            self.getMenuBarItemsFromAppsAX(
                timeout: self.menuBarAXTimeoutSec,
                apps: self.accessoryAppsForMenuExtras())
        }

        // Avoid AX hit-testing by default (can hang); enable via PEEKABOO_MENUBAR_DEEP_AX_SWEEP=1.
        let fallbackExtras: [MenuExtraInfo] = if self.deepMenuBarAXSweepEnabled {
            self.enrichWindowExtrasWithAXHitTest(windowExtras, timeout: self.menuBarAXTimeoutSec)
        } else {
            windowExtras
        }

        let merged = Self.mergeMenuExtras(
            accessibilityExtras: axExtras + controlCenterExtras + appAXExtras,
            fallbackExtras: fallbackExtras)
        return Self.sortedMenuExtras(self.hydrateMenuExtraOwners(merged))
    }

    static func sortedMenuExtras(_ extras: [MenuExtraInfo]) -> [MenuExtraInfo] {
        extras.sorted { lhs, rhs in
            let lhsKey = (
                lhs.position.y,
                lhs.position.x,
                lhs.windowID ?? .max,
                lhs.ownerPID ?? .max,
                lhs.identifier ?? lhs.title)
            let rhsKey = (
                rhs.position.y,
                rhs.position.x,
                rhs.windowID ?? .max,
                rhs.ownerPID ?? .max,
                rhs.identifier ?? rhs.title)
            if lhsKey.0 != rhsKey.0 {
                return lhsKey.0 < rhsKey.0
            }
            if lhsKey.1 != rhsKey.1 {
                return lhsKey.1 < rhsKey.1
            }
            if lhsKey.2 != rhsKey.2 {
                return lhsKey.2 < rhsKey.2
            }
            if lhsKey.3 != rhsKey.3 {
                return lhsKey.3 < rhsKey.3
            }
            return lhsKey.4 < rhsKey.4
        }
    }

    public func listMenuBarItems(includeRaw: Bool = false) async throws -> [MenuBarItemInfo] {
        let extras = try await listMenuExtras()

        return extras.indexed().map { index, extra in
            let displayTitle = self.resolvedMenuBarTitle(for: extra, index: index)
            let evidence = try? self.menuBarLeafEvidence(extra: extra, index: index, extras: extras)
            return MenuBarItemInfo(
                title: displayTitle,
                index: index,
                isVisible: extra.isVisible,
                description: extra.identifier ?? extra.rawTitle ?? extra.ownerName ?? extra.title,
                rawTitle: extra.rawTitle,
                bundleIdentifier: extra.bundleIdentifier,
                ownerName: extra.ownerName,
                frame: evidence?.selectedFrame ?? CGRect(origin: extra.position, size: .zero),
                identifier: extra.identifier,
                axIdentifier: extra.identifier,
                axDescription: extra.rawTitle,
                rawWindowID: includeRaw ? extra.windowID : nil,
                rawWindowLayer: includeRaw ? extra.windowLayer : nil,
                rawOwnerPID: includeRaw ? extra.ownerPID : nil,
                rawSource: includeRaw ? extra.source : nil,
                selectionEvidence: evidence)
        }
    }

    private func menuBarLeafEvidence(
        extra: MenuExtraInfo,
        index: Int,
        extras: [MenuExtraInfo]) throws -> DesktopSelectedLeafEvidence
    {
        guard let ownerPID = extra.ownerPID,
              ownerPID > 0,
              let startIdentity = SystemIdentityResolver.processStartIdentity(ownerPID)
        else {
            throw DesktopSelectedLeafEvidenceError.invalidEvidence
        }
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: ownerPID,
            processStartIdentity: startIdentity)
        let windowIdentity = extra.windowID.flatMap {
            SystemIdentityResolver.windowMutationIdentity(windowID: $0)
        }
        if let windowIdentity, windowIdentity.processIdentity != processIdentity {
            throw DesktopSelectedLeafEvidenceError.invalidEvidence
        }
        let frame = windowIdentity?.capturedBounds ?? CGRect(
            x: extra.position.x - 0.5,
            y: extra.position.y - 0.5,
            width: 1,
            height: 1)
        guard !frame.isEmpty else { throw DesktopSelectedLeafEvidenceError.invalidEvidence }

        let candidates = extras.indexed().map { candidateIndex, candidate in
            let hasStableAnchor = candidate.identifier != nil || candidate.windowID != nil
            return DeterministicDesktopLeafSelector.Candidate(
                value: candidate,
                index: candidateIndex,
                displayName: self.resolvedMenuBarTitle(for: candidate, index: candidateIndex),
                matchFields: [
                    self.resolvedMenuBarTitle(for: candidate, index: candidateIndex),
                    candidate.rawTitle,
                    candidate.identifier,
                    candidate.ownerName,
                ].compactMap { sanitizedMenuText($0) },
                stableIdentity: DeterministicDesktopLeafSelector.stableIdentity([
                    candidate.ownerPID.map { String($0) },
                    candidate.windowID.map { String($0) },
                    candidate.windowLayer.map { String($0) },
                    hasStableAnchor ? nil : candidate.title,
                    hasStableAnchor ? nil : candidate.rawTitle,
                    candidate.bundleIdentifier,
                    candidate.ownerName,
                    candidate.identifier,
                    candidate.source,
                    "\(candidate.position.x),\(candidate.position.y)",
                    String(candidate.isVisible),
                ]))
        }
        let selection = try DeterministicDesktopLeafSelector.select(index: index, from: candidates)
        return try DesktopSelectedLeafEvidence(
            kind: .menuBarItem,
            normalizedSelector: selection.normalizedSelector,
            matchKind: .index,
            selectedProcessIdentity: processIdentity,
            selectedWindowIdentity: windowIdentity,
            selectedIndex: index,
            selectedTitle: self.resolvedMenuBarTitle(for: extra, index: index),
            selectedIdentifier: extra.identifier,
            selectedRole: "AXStatusItem",
            selectedSubrole: extra.source,
            selectedFrame: frame,
            candidateSetSHA256: selection.candidateSetSHA256,
            candidateCount: selection.candidateCount)
    }

    public func clickMenuBarItem(named name: String) async throws -> ClickResult {
        try await self.clickMenuBarItemActionResult(named: name).payload
    }

    public func clickMenuBarItemActionResult(named name: String) async throws -> UIAutomationActionResult<ClickResult> {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            try await self.clickMenuBarItemActionResultWithOwnedLane(named: name)
        }
    }

    public func clickMenuBarItemGenerationPinnedActionResult(named name: String) async throws
        -> UIAutomationActionResult<ClickResult>
    {
        try await self.clickMenuBarItemActionResult(named: name)
    }

    public func clickMenuBarItemActionResult(request: MenuBarItemActionRequest) async throws
        -> UIAutomationActionResult<ClickResult>
    {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            let items = try await self.listMenuBarItems(includeRaw: true)
            let selection: DeterministicDesktopLeafSelector.Selection<MenuBarItemInfo>
            if let name = request.name {
                selection = try self.resolveMenuBarItem(named: name, items: items)
            } else if let index = request.index {
                selection = try MenuBarItemSelector.select(index: index, from: items)
            } else {
                throw PeekabooError.invalidInput("Menu bar action request has no selector")
            }
            guard let evidence = selection.candidate.value.selectionEvidence,
                  request.expectedLeafEvidence.hasSameResolvedLeaf(as: evidence)
            else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "The selected menu bar item changed before dispatch.",
                    hint: "Refresh the menu bar inventory before retrying.")
            }
            return try await self.clickMenuBarItemActionResultWithOwnedLane(
                at: selection.candidate.value.index,
                expectedEvidence: request.expectedLeafEvidence,
                normalizedSelector: selection.normalizedSelector,
                matchKind: selection.matchKind)
        }
    }

    func clickMenuBarItemWithOwnedLane(named name: String) async throws -> ClickResult {
        try await self.clickMenuBarItemActionResultWithOwnedLane(named: name).payload
    }

    func clickMenuBarItemActionResultWithOwnedLane(
        named name: String) async throws -> UIAutomationActionResult<ClickResult>
    {
        try await Self.withNamedMenuExtraLookupFallback {
            let target = try await self.clickMenuExtraWithOwnedLane(title: name)
            return try UIAutomationActionResult(
                payload: ClickResult(
                    elementDescription: "Menu bar item: \(name)",
                    location: nil),
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                targetIdentity: DesktopTargetIdentity(processIdentity: target.snapshot.processIdentity),
                selectedLeafEvidence: [target.evidence])
        } fallback: {
            let items = try await listMenuBarItems(includeRaw: true)
            let selection = try self.resolveMenuBarItem(named: name, items: items)
            guard let evidence = selection.candidate.value.selectionEvidence else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Menu bar item '\(name)' has no exact selected-leaf evidence.",
                    hint: "Refresh the menu bar inventory before retrying.")
            }
            return try await self.clickMenuBarItemActionResultWithOwnedLane(
                at: selection.candidate.value.index,
                expectedEvidence: evidence,
                normalizedSelector: selection.normalizedSelector,
                matchKind: selection.matchKind)
        }
    }

    private func resolveMenuBarItem(
        named name: String,
        items: [MenuBarItemInfo]) throws
        -> DeterministicDesktopLeafSelector.Selection<MenuBarItemInfo>
    {
        do {
            return try MenuBarItemSelector.select(named: name, from: items)
        } catch let error as DesktopLeafSelectionError {
            switch error {
            case let .ambiguous(_, matches):
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "Menu bar item selector '\(name)' is ambiguous: \(matches.joined(separator: ", ")).",
                    hint: "Use an exact current item name or list index.")
            case .notFound, .invalidIndex:
                throw NotFoundError(
                    code: .menuNotFound,
                    userMessage: "Menu bar item '\(name)' not found",
                    context: ["availableItems": items.compactMap(\.title).joined(separator: ", ")])
            }
        }
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
                  [DesktopActionOutcome.RefusalReason.targetUnavailable, .operationUnsupported]
                      .contains(refusalReason),
                      outcome.dispatchState == .none,
                      outcome.retrySafety == .safe
            else {
                throw failure
            }
        } catch is NotFoundError {
            // The direct menu-extra path only raises this while resolving the AX target.
        } catch let error as PeekabooError {
            switch error {
            case .serviceUnavailable, .operationError:
                // These are emitted above only by owner/visibility checks before AX dispatch.
                break
            default:
                throw error
            }
        }

        return try await fallback()
    }

    public func clickMenuBarItem(at index: Int) async throws -> ClickResult {
        try await self.clickMenuBarItemActionResult(at: index).payload
    }

    public func clickMenuBarItemActionResult(at index: Int) async throws -> UIAutomationActionResult<ClickResult> {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            try await self.clickMenuBarItemActionResultWithOwnedLane(at: index)
        }
    }

    func clickMenuBarItemActionResultWithOwnedLane(
        at index: Int,
        expectedEvidence: DesktopSelectedLeafEvidence? = nil,
        normalizedSelector: String? = nil,
        matchKind: DesktopSelectedLeafEvidence.MatchKind? = nil) async throws
        -> UIAutomationActionResult<ClickResult>
    {
        let extras = try await listMenuExtras()
        try Self.checkMenuBarDispatchCancellation()

        guard index >= 0, index < extras.count else {
            throw PeekabooError
                .invalidInput("Invalid menu bar item index: \(index). Valid range: 0-\(extras.count - 1)")
        }

        let extra = extras[index]
        let initialEvidence = try self.menuBarLeafEvidence(extra: extra, index: index, extras: extras)
        if let expectedEvidence,
           !expectedEvidence.hasSameResolvedLeaf(as: initialEvidence)
        {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Menu bar item [\(index)] changed identity or order before dispatch.",
                hint: "Refresh menu bar items before retrying.")
        }
        guard extra.isVisible else {
            throw PeekabooError.operationError(
                message: self.hiddenMenuExtraMessage(title: extra.title))
        }

        let refreshedExtras = try await self.listMenuExtras()
        guard index >= 0, index < refreshedExtras.count else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Menu bar item [\(index)] disappeared before dispatch.",
                hint: "Refresh menu bar items before retrying.")
        }
        let refreshedExtra = refreshedExtras[index]
        let refreshedEvidence = try self.menuBarLeafEvidence(
            extra: refreshedExtra,
            index: index,
            extras: refreshedExtras)
        guard initialEvidence.hasSameResolvedLeaf(as: refreshedEvidence),
              expectedEvidence.map({ $0.hasSameResolvedLeaf(as: refreshedEvidence) }) ?? true
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Menu bar item [\(index)] changed identity or order before dispatch.",
                hint: "Refresh menu bar items before retrying.")
        }
        let processIdentity = refreshedEvidence.selectedProcessIdentity
        let liveWindow = refreshedExtra.windowID.flatMap { SystemIdentityResolver.stableWindowIdentity($0) }
        let mutationIdentity = refreshedExtra.windowID.flatMap {
            SystemIdentityResolver.windowMutationIdentity(windowID: $0)
        }
        let route = try Self.menuBarWindowRoute(
            extra: refreshedExtra,
            expectedProcessIdentity: processIdentity,
            liveWindow: liveWindow,
            mutationIdentity: mutationIdentity)
        guard self.isMenuExtraPointVisible(route.point) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: self.hiddenMenuExtraMessage(title: refreshedExtra.title),
                hint: "Refresh menu bar items before retrying.")
        }
        try Self.checkMenuBarDispatchCancellation()
        let resultEvidence = try refreshedEvidence.selecting(
            normalizedSelector: normalizedSelector ?? String(index),
            matchKind: matchKind ?? .index)
        let outcome: DesktopActionOutcome
        do {
            guard let windowID = CGWindowID(exactly: route.identity.windowID) else {
                throw PeekabooError.snapshotStale("Menu bar window identifier is outside the CGWindowID range")
            }
            outcome = try await WindowRoutedPointerDriver().click(
                at: route.point,
                button: .left,
                count: 1,
                targetProcessIdentifier: route.identity.ownerProcessIdentifier,
                targetWindowID: windowID,
                expectedWindowIdentity: route.identity,
                expectedWindowBounds: route.bounds,
                allowedWindowLayers: Self.menuBarRoutableWindowLayers)
        } catch let failure as DesktopActionFailure {
            throw failure
                .attributed(to: route.identity)
                .selectingLeaves([resultEvidence])
        } catch let error as InputDeliveryIndeterminateError {
            throw error.desktopActionFailure(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background))
                .attributed(to: route.identity)
                .selectingLeaves([resultEvidence])
        } catch is CancellationError {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .requestCancelled,
                message: "Menu bar click was cancelled before routed event submission.",
                hint: "Submit a new request only if the menu bar action is still wanted.")
                .attributed(to: route.identity)
                .selectingLeaves([resultEvidence])
        } catch let error as PeekabooError {
            let reason: DesktopActionOutcome.RefusalReason = switch error {
            case .permissionDeniedEventSynthesizing: .permissionDenied
            case .snapshotStale: .targetUnavailable
            default: .operationUnsupported
            }
            throw DesktopActionFailure.preDispatchRefusal(
                reason: reason,
                message: "Menu bar background routing refused before dispatch.",
                hint: "Refresh the target or grant Event Synthesizing permission; global fallback is disabled.",
                causeDescription: error.localizedDescription)
                .attributed(to: route.identity)
                .selectingLeaves([resultEvidence])
        }

        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: route.identity,
            bounds: route.bounds)
        return UIAutomationActionResult(
            payload: ClickResult(
                elementDescription: "Menu bar item [\(index)]: \(refreshedExtra.title)",
                location: route.point),
            outcome: outcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow),
            selectedLeafEvidence: [resultEvidence])
    }

    static func checkMenuBarDispatchCancellation(
        _ checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws
    {
        do {
            try checkCancellation()
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .requestCancelled,
                message: "Menu bar click was cancelled before event submission.",
                hint: "Submit a new request only if the menu bar action is still wanted.")
        }
    }

    func validateNamedFallbackTitle(_ candidate: String, requestedName: String) throws {
        let normalizedName = normalizedMenuTitle(requestedName)
        let matches = titlesMatch(
            candidate: candidate,
            target: requestedName,
            normalizedTarget: normalizedName) ||
            menuExtraTitlesMatch(candidate: candidate, target: requestedName) ||
            (self.partialMatchEnabled && titlesMatchPartial(
                candidate: candidate,
                target: requestedName,
                normalizedTarget: normalizedName))
        guard matches else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Menu bar item '\(requestedName)' changed before dispatch.",
                hint: "Refresh menu bar items and retry against the current target.")
        }
    }

    private func hiddenMenuExtraMessage(title: String) -> String {
        "Menu bar item '\(title)' is outside the active displays. It may be hidden by a menu bar manager."
    }

    @_spi(Testing) public func resolvedMenuBarTitle(for extra: MenuExtraInfo, index: Int) -> String {
        let title = extra.title
        let titleIsPlaceholder = isPlaceholderMenuTitle(title) ||
            (isPlaceholderMenuTitle(extra.rawTitle) && title == extra.ownerName)

        if !titleIsPlaceholder {
            return title
        }

        if let identifierName = humanReadableMenuIdentifier(extra.identifier ?? extra.rawTitle),
           !identifierName.isEmpty
        {
            if let ownerName = extra.ownerName,
               let normalizedIdentifier = normalizedMenuTitle(identifierName)?.replacingOccurrences(of: " ", with: ""),
               let normalizedOwner = normalizedMenuTitle(ownerName)?.replacingOccurrences(of: " ", with: ""),
               normalizedIdentifier == normalizedOwner
            {
                // Skip identifier-based label when it matches the owner (e.g., Control Center).
            } else {
                self.logger.debug("MenuService replacing placeholder '\(title)' with identifier '\(identifierName)'")
                return identifierName
            }
        }

        if let ownerName = extra.ownerName, !ownerName.isEmpty {
            return "\(ownerName) #\(index)"
        }

        if let raw = extra.rawTitle, !raw.isEmpty {
            return "\(raw) #\(index)"
        }

        return "Menu Bar Item #\(index)"
    }

    #if DEBUG
    @_spi(Testing) public func makeDebugDisplayName(
        rawTitle: String?,
        ownerName: String?,
        bundleIdentifier: String?) async -> String
    {
        self.makeMenuExtraDisplayName(
            rawTitle: rawTitle,
            ownerName: ownerName,
            bundleIdentifier: bundleIdentifier,
            identifier: rawTitle)
    }
    #endif
}
