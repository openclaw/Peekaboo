import CoreGraphics
import Foundation
import PeekabooFoundation

extension ObservationTargetResolver {
    func resolveMenuBar() throws -> ResolvedObservationTarget {
        guard let screen = self.screens?.primaryScreen else {
            throw DesktopObservationError.targetNotFound("primary menu bar screen")
        }

        let bounds = Self.menuBarBounds(for: screen)
        return ResolvedObservationTarget(
            kind: .menubar,
            bounds: bounds,
            captureScaleHint: screen.scaleFactor)
    }

    func resolveMenuBarPopover(
        hints: [String],
        openIfNeeded: MenuBarPopoverOpenOptions?) async throws -> ResolvedObservationTarget
    {
        try await self.resolveMenuBarPopoverActionResult(
            hints: hints,
            openIfNeeded: openIfNeeded).payload
    }

    func resolveMenuBarPopoverActionResult(
        hints: [String],
        openIfNeeded: MenuBarPopoverOpenOptions?) async throws
        -> UIAutomationActionResult<ResolvedObservationTarget>
    {
        do {
            return try UIAutomationActionResult(
                payload: self.resolveOpenMenuBarPopover(hints: hints),
                outcome: nil)
        } catch DesktopObservationError.targetNotFound(_) where openIfNeeded != nil {
            return try await self.openAndResolveMenuBarPopover(
                hints: hints,
                options: openIfNeeded ?? MenuBarPopoverOpenOptions())
        }
    }

    private func resolveOpenMenuBarPopover(
        hints: [String]) throws -> ResolvedObservationTarget
    {
        guard let screens = self.screens?.listScreens(), !screens.isEmpty else {
            throw DesktopObservationError.targetNotFound("menu bar popover screens")
        }

        let snapshot = ObservationMenuBarWindowCatalog.currentPopoverSnapshot(screens: screens)
        guard let popover = ObservationMenuBarPopoverResolver.resolve(
            hints: hints,
            candidates: snapshot.candidates)
        else {
            throw DesktopObservationError.targetNotFound("menu bar popover")
        }

        let exactMetadata = self.exactWindowMetadataProvider.metadata(for: popover.windowID)
        if exactMetadata == nil ||
            exactMetadata?.ownerProcessIdentifier != popover.ownerPID ||
            exactMetadata?.bounds != popover.bounds
        {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The open menu-bar popover has no stable owner generation.",
                hint: "Refresh the menu-bar target before retrying; Peekaboo refused to click it.")
        }
        guard let exactMetadata else {
            preconditionFailure("Stable popover metadata was required above")
        }
        let processStartIdentity = exactMetadata.ownerProcessStartIdentity
        let app = ApplicationIdentity(
            processIdentifier: popover.ownerPID,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: nil,
            name: popover.ownerName ?? exactMetadata.applicationName ?? "Unknown")
        let window = WindowIdentity(
            windowID: Int(popover.windowID),
            title: popover.title ?? "",
            bounds: popover.bounds,
            index: 0)
        let context = WindowContext(
            applicationName: app.name,
            applicationBundleId: app.bundleIdentifier,
            applicationProcessId: app.processIdentifier,
            windowTitle: window.title,
            windowID: window.windowID,
            windowBounds: window.bounds,
            windowMutationIdentity: WindowMutationIdentity(
                windowID: window.windowID,
                ownerProcessIdentifier: app.processIdentifier,
                ownerProcessStartIdentity: processStartIdentity,
                capturedBounds: window.bounds))

        return ResolvedObservationTarget(
            kind: .menubarPopover,
            app: app,
            window: window,
            bounds: popover.bounds,
            detectionContext: context)
    }

    private func openAndResolveMenuBarPopover(
        hints: [String],
        options: MenuBarPopoverOpenOptions) async throws -> UIAutomationActionResult<ResolvedObservationTarget>
    {
        guard let menu else {
            throw DesktopObservationError.targetNotFound("menu bar popover menu service")
        }
        guard let hint = self.menuBarPopoverClickHint(from: hints, options: options) else {
            throw DesktopObservationError.targetNotFound("menu bar popover click hint")
        }

        guard let exactMenu = menu as? any MenuServiceExactLeafActionResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .foregroundConsentRequired,
                message: "Background popover observation requires an exact window-routed menu-bar item.",
                hint: "Update the runtime or explicitly authorize a separate foreground menu-bar interaction.")
        }

        let clickResult = try await self.backgroundMenuBarClick(
            named: hint,
            menu: menu,
            exactMenu: exactMenu)
        DesktopObservationActionProgressContext.record(clickResult)
        do {
            if options.settleDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: options.settleDelayNanoseconds)
            }

            if let target = try? self.resolveOpenMenuBarPopover(hints: hints) {
                return self.menuBarResolutionResult(target, after: clickResult)
            }

            // Some transient menu extras do not publish a stable CG window immediately after click; fall back to
            // the click-adjacent menu-bar area so OCR can still inspect the opened popover.
            if options.useClickLocationAreaFallback,
               let preferredX = clickResult.payload.location?.x,
               let screens = self.screens?.listScreens(),
               let bounds = ObservationMenuBarPopoverOCRSelector.popoverAreaRect(
                   preferredX: preferredX,
                   screens: screens)
            {
                let context = WindowContext(
                    applicationName: hint,
                    windowTitle: hint,
                    windowBounds: bounds)
                return self.menuBarResolutionResult(
                    ResolvedObservationTarget(
                        kind: .menubarPopover,
                        app: ApplicationIdentity(processIdentifier: -1, bundleIdentifier: nil, name: hint),
                        bounds: bounds,
                        detectionContext: context),
                    after: clickResult)
            }

            throw DesktopObservationError.targetNotFound("menu bar popover")
        } catch {
            throw self.failureAfterMenuBarClick(error, clickResult: clickResult)
        }
    }

    private func withMutationTargetIdentity(
        _ target: ResolvedObservationTarget,
        _ mutationTargetIdentity: DesktopTargetIdentity) -> ResolvedObservationTarget
    {
        ResolvedObservationTarget(
            kind: target.kind,
            app: target.app,
            window: target.window,
            bounds: target.bounds,
            detectionContext: target.detectionContext,
            captureScaleHint: target.captureScaleHint,
            mutationTargetIdentity: DesktopObservationMutationTargetIdentity(mutationTargetIdentity))
    }

    private func backgroundMenuBarClick(
        named name: String,
        menu: any MenuServiceProtocol,
        exactMenu: any MenuServiceExactLeafActionResultProviding) async throws
        -> UIAutomationActionResult<ClickResult>
    {
        let items = try await menu.listMenuBarItems(includeRaw: true)
        let selection: DeterministicDesktopLeafSelector.Selection<MenuBarItemInfo>
        do {
            selection = try MenuBarItemSelector.select(named: name, from: items)
        } catch let error as DesktopLeafSelectionError {
            let reason: DesktopActionOutcome.RefusalReason = switch error {
            case .ambiguous: .invalidRequest
            case .notFound, .invalidIndex: .targetUnavailable
            }
            throw DesktopActionFailure.preDispatchRefusal(
                reason: reason,
                message: error.localizedDescription,
                hint: "Use one exact current menu-bar item name.")
        }
        guard let baseEvidence = selection.candidate.value.selectionEvidence,
              baseEvidence.selectedTargetReceipt.windowID != nil
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .foregroundConsentRequired,
                message: "The menu-bar item has no exact background window route.",
                hint: "Use an explicitly authorized foreground menu-bar action instead.")
        }
        let expectedEvidence = try baseEvidence.selecting(
            normalizedSelector: selection.normalizedSelector,
            matchKind: selection.matchKind)
        let request = try MenuBarItemActionRequest(
            named: name,
            expectedLeafEvidence: expectedEvidence)
        let result = if let ownedMenu = exactMenu as? MenuService {
            try await ownedMenu.clickMenuBarItemActionResultWithOwnedLane(
                at: selection.candidate.value.index,
                expectedEvidence: expectedEvidence,
                normalizedSelector: selection.normalizedSelector,
                matchKind: selection.matchKind)
        } else {
            try await exactMenu.clickMenuBarItemActionResult(request: request)
        }

        guard let outcome = result.outcome,
              outcome.isAccepted(by: .confirmedOrDispatched),
              outcome.delivery == .init(mechanism: .windowTargetedEvents, mode: .background),
              outcome.dispatchState.unitCount != nil,
              let target = result.targetIdentity,
              let exactWindow = target.exactWindow,
              expectedEvidence.selects(window: exactWindow.identity),
              result.selectedLeafEvidence?.count == 1,
              result.selectedLeafEvidence?.first?.hasSameResolvedLeaf(as: expectedEvidence) == true
        else {
            throw DesktopActionFailure.indeterminate(
                delivery: result.outcome?.delivery,
                evidence: .completionUnknown,
                unitCount: result.outcome?.dispatchState.unitCount,
                message: "The background menu-bar click returned incomplete or foreground action evidence.",
                hint: "Observe the menu bar before retrying and update the runtime host.")
                .attributed(to: result.targetIdentity?.actionTargetReceipt)
                .selectingLeaves(result.selectedLeafEvidence)
        }
        return result
    }

    private func menuBarResolutionResult(
        _ target: ResolvedObservationTarget,
        after clickResult: UIAutomationActionResult<ClickResult>) -> UIAutomationActionResult<ResolvedObservationTarget>
    {
        guard let mutationTargetIdentity = clickResult.targetIdentity else {
            preconditionFailure("Background menu-bar result validation requires an exact target")
        }
        return UIAutomationActionResult(
            payload: self.withMutationTargetIdentity(target, mutationTargetIdentity),
            outcome: clickResult.outcome,
            targetIdentity: mutationTargetIdentity,
            selectedLeafEvidence: clickResult.selectedLeafEvidence)
    }

    private func failureAfterMenuBarClick(
        _ error: any Error,
        clickResult: UIAutomationActionResult<ClickResult>) -> DesktopActionFailure
    {
        let message = "Menu-bar popover resolution failed after its background click was dispatched."
        let hint = "Observe the menu bar before retrying this popover observation."
        if let outcome = clickResult.outcome,
           let failure = DesktopActionFailure(
               outcome: outcome,
               message: message,
               hint: hint,
               causeDescription: error.localizedDescription,
               targetReceipt: clickResult.targetIdentity?.actionTargetReceipt,
               selectedLeafEvidence: clickResult.selectedLeafEvidence)
        {
            return failure
        }
        return DesktopActionFailure.indeterminate(
            delivery: clickResult.outcome?.delivery,
            evidence: .completionUnknown,
            unitCount: clickResult.outcome?.dispatchState.unitCount,
            message: message,
            hint: hint,
            causeDescription: error.localizedDescription)
            .attributed(to: clickResult.targetIdentity?.actionTargetReceipt)
            .selectingLeaves(clickResult.selectedLeafEvidence)
    }

    private func menuBarPopoverClickHint(
        from hints: [String],
        options: MenuBarPopoverOpenOptions) -> String?
    {
        let candidates = [options.clickHint] + hints.map(Optional.some)
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    public nonisolated static func menuBarBounds(for screen: ScreenInfo) -> CGRect {
        let calculatedHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let menuBarHeight: CGFloat = calculatedHeight > 0 ? calculatedHeight : 24
        return CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - menuBarHeight,
            width: screen.frame.width,
            height: menuBarHeight)
    }
}
