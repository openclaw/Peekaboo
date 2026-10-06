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
        let windowExtras = self.menuExtraReaders.windowExtras?() ?? self.getMenuBarItemsViaWindows()

        // Named mutation preparation owns AX discovery; displayed indices stay on the cheap CG path.
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
              let startIdentity = self.menuExtraReaders.processGeneration(ownerPID)
        else {
            throw DesktopSelectedLeafEvidenceError.invalidEvidence
        }
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: ownerPID,
            processStartIdentity: startIdentity)
        let windowIdentity = extra.windowID.flatMap {
            self.menuExtraReaders.windowIdentity($0)
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
            if request.applicationScope != nil {
                return try await self.executeScopedMenuBarAction(request)
            }
            let items = try await self.listMenuBarItems(includeRaw: true)
            let selection: DeterministicDesktopLeafSelector.Selection<MenuBarItemInfo>
            if let name = request.name {
                selection = try Self.resolveDisplayedMenuBarSelection(named: name, items: items)
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
                payload: ClickResult(elementDescription: "Menu bar item: \(name)", location: nil),
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                targetIdentity: DesktopTargetIdentity(processIdentity: target.snapshot.processIdentity),
                selectedLeafEvidence: [target.evidence])
        } fallback: {
            try await self.clickDisplayedMenuBarItemWithOwnedLane(named: name)
        }
    }

    private func clickDisplayedMenuBarItemWithOwnedLane(
        named name: String) async throws -> UIAutomationActionResult<ClickResult>
    {
        let selection = try await self.displayedMenuBarSelection(named: name)
        guard let evidence = selection.candidate.value.selectionEvidence else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The displayed menu bar item has no exact window evidence.",
                hint: "Refresh the menu bar list before retrying.")
        }
        return try await self.clickMenuBarItemActionResultWithOwnedLane(
            at: selection.candidate.value.index,
            expectedEvidence: evidence,
            normalizedSelector: selection.normalizedSelector,
            matchKind: selection.matchKind)
    }

    func displayedMenuBarSelection(named name: String) async throws
        -> DeterministicDesktopLeafSelector.Selection<MenuBarItemInfo>
    {
        let items = try await self.listMenuBarItems(includeRaw: true)
        return try Self.resolveDisplayedMenuBarSelection(named: name, items: items)
    }

    private static func resolveDisplayedMenuBarSelection(named name: String, items: [MenuBarItemInfo]) throws
        -> DeterministicDesktopLeafSelector.Selection<MenuBarItemInfo>
    {
        do {
            return try MenuBarItemSelector.select(named: name, from: items)
        } catch let error as DesktopLeafSelectionError {
            if case .notFound = error {
                throw PeekabooError.menuItemNotFound(name)
            }
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: error.localizedDescription,
                hint: "Use one exact displayed name or a current list index.")
        }
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
        return try await self.dispatchMenuBarWindow(
            extra: refreshedExtra,
            evidence: refreshedEvidence,
            index: index,
            normalizedSelector: normalizedSelector,
            matchKind: matchKind)
    }

    func dispatchMenuBarWindow(
        extra: MenuExtraInfo,
        evidence: DesktopSelectedLeafEvidence,
        index: Int,
        normalizedSelector: String? = nil,
        matchKind: DesktopSelectedLeafEvidence.MatchKind? = nil) async throws -> UIAutomationActionResult<ClickResult>
    {
        let processIdentity = evidence.selectedProcessIdentity
        let liveWindow = extra.windowID.flatMap { SystemIdentityResolver.stableWindowIdentity($0) }
        let mutationIdentity = extra.windowID.flatMap {
            SystemIdentityResolver.windowMutationIdentity(windowID: $0)
        }
        let route = try Self.menuBarWindowRoute(
            extra: extra,
            expectedProcessIdentity: processIdentity,
            liveWindow: liveWindow,
            mutationIdentity: mutationIdentity)
        guard self.isMenuExtraPointVisible(route.point) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: self.hiddenMenuExtraMessage(title: extra.title),
                hint: "Refresh menu bar items before retrying.")
        }
        try Self.checkMenuBarDispatchCancellation()
        let resultEvidence = try evidence.selecting(
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
                .attributed(to: route.identity.actionTargetReceipt)
                .selectingLeaves([resultEvidence])
        } catch let error as InputDeliveryIndeterminateError {
            throw error.desktopActionFailure(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background))
                .attributed(to: route.identity.actionTargetReceipt)
                .selectingLeaves([resultEvidence])
        } catch is CancellationError {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .requestCancelled,
                message: "Menu bar click was cancelled before routed event submission.",
                hint: "Submit a new request only if the menu bar action is still wanted.")
                .attributed(to: route.identity.actionTargetReceipt)
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
                .attributed(to: route.identity.actionTargetReceipt)
                .selectingLeaves([resultEvidence])
        }

        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: route.identity,
            bounds: route.bounds)
        return UIAutomationActionResult(
            payload: ClickResult(
                elementDescription: "Menu bar item [\(index)]: \(extra.title)",
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

    func hiddenMenuExtraMessage(title: String) -> String {
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
