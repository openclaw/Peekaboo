import CoreGraphics
import Foundation

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
        do {
            return try self.resolveOpenMenuBarPopover(hints: hints)
        } catch DesktopObservationError.targetNotFound(_) where openIfNeeded != nil {
            return try await self.openAndResolveMenuBarPopover(
                hints: hints,
                options: openIfNeeded ?? MenuBarPopoverOpenOptions())
        }
    }

    private func resolveOpenMenuBarPopover(hints: [String]) throws -> ResolvedObservationTarget {
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

        let app = ApplicationIdentity(
            processIdentifier: popover.ownerPID,
            bundleIdentifier: nil,
            name: popover.ownerName ?? "Unknown")
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
            windowBounds: window.bounds)

        return ResolvedObservationTarget(
            kind: .menubarPopover,
            app: app,
            window: window,
            bounds: popover.bounds,
            detectionContext: context)
    }

    private func openAndResolveMenuBarPopover(
        hints: [String],
        options: MenuBarPopoverOpenOptions) async throws -> ResolvedObservationTarget
    {
        guard let menu else {
            throw DesktopObservationError.targetNotFound("menu bar popover menu service")
        }
        guard let hint = self.menuBarPopoverClickHint(from: hints, options: options) else {
            throw DesktopObservationError.targetNotFound("menu bar popover click hint")
        }

        let clickResult = if let ownedMenu = menu as? MenuService {
            try await ownedMenu.clickMenuBarItemWithOwnedLane(named: hint)
        } else {
            try await menu.clickMenuBarItem(named: hint)
        }
        if options.settleDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: options.settleDelayNanoseconds)
        }

        if let target = try? self.resolveOpenMenuBarPopover(hints: hints) {
            return target
        }

        // Some transient menu extras do not publish a stable CG window immediately after click; fall back to
        // the click-adjacent menu-bar area so OCR can still inspect the opened popover.
        if options.useClickLocationAreaFallback,
           let preferredX = clickResult.location?.x,
           let screens = self.screens?.listScreens(),
           let bounds = ObservationMenuBarPopoverOCRSelector.popoverAreaRect(
               preferredX: preferredX,
               screens: screens)
        {
            let context = WindowContext(
                applicationName: hint,
                windowTitle: hint,
                windowBounds: bounds)
            return ResolvedObservationTarget(
                kind: .menubarPopover,
                app: ApplicationIdentity(processIdentifier: -1, bundleIdentifier: nil, name: hint),
                bounds: bounds,
                detectionContext: context)
        }

        throw DesktopObservationError.targetNotFound("menu bar popover")
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
