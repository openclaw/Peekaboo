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
        let systemWide = Element.systemWide()

        guard let menuBar = systemWide.menuBar() else {
            throw PeekabooError.operationError(message: "System menu bar not found")
        }

        let menuBarItems = menuBar.children(strict: true) ?? []
        guard let menuExtrasGroup = menuBarItems.last(where: { $0.role() == "AXGroup" }) else {
            var context = ErrorContext()
            context.add("menuExtra", title)
            throw NotFoundError(
                code: .menuNotFound,
                userMessage: "Menu extras group not found in system menu bar",
                context: context.build())
        }

        let extras = menuExtrasGroup.children(strict: true) ?? []
        let normalizedTarget = normalizedMenuTitle(title)
        func candidates(for element: Element) -> [String?] {
            [
                element.title(),
                element.help(),
                element.descriptionText(),
                element.identifier(),
            ]
        }

        let menuExtra = extras.first(where: { element in
            candidates(for: element).contains(where: {
                titlesMatch(candidate: $0, target: title, normalizedTarget: normalizedTarget)
            })
        }) ?? extras.first(where: { element in
            candidates(for: element).contains(where: { menuExtraTitlesMatch(candidate: $0, target: title) })
        }) ?? extras.first(where: { element in
            guard self.partialMatchEnabled else { return false }
            return candidates(for: element).contains(where: { titlesMatchPartial(
                candidate: $0,
                target: title,
                normalizedTarget: normalizedTarget) })
        })

        guard let menuExtra else {
            var context = ErrorContext()
            context.add("menuExtra", title)
            context.add("availableExtras", extras.count)
            throw NotFoundError(
                code: .menuNotFound,
                userMessage: "Menu extra '\(title)' not found in system menu bar",
                context: context.build())
        }

        if let position = menuExtra.position(),
           Self.isIndividuallyHiddenMenuExtra(
               position: position,
               allPositions: extras.compactMap { $0.position() },
               displayBounds: self.activeDisplayBounds())
        {
            throw PeekabooError.operationError(
                message: self.hiddenMenuExtraMessage(title: title))
        }

        if !menuExtra.showMenu(), !menuExtra.press() {
            throw OperationError.interactionFailed(
                action: "click menu extra",
                reason: "Failed to click menu extra '\(title)'")
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
            return windowExtras
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
        return self.hydrateMenuExtraOwners(merged)
    }

    public func listMenuBarItems(includeRaw: Bool = false) async throws -> [MenuBarItemInfo] {
        let extras = try await listMenuExtras()

        return extras.indexed().map { index, extra in
            let displayTitle = self.resolvedMenuBarTitle(for: extra, index: index)
            return MenuBarItemInfo(
                title: displayTitle,
                index: index,
                isVisible: extra.isVisible,
                description: extra.identifier ?? extra.rawTitle ?? extra.ownerName ?? extra.title,
                rawTitle: extra.rawTitle,
                bundleIdentifier: extra.bundleIdentifier,
                ownerName: extra.ownerName,
                frame: CGRect(origin: extra.position, size: .zero),
                identifier: extra.identifier,
                axIdentifier: extra.identifier,
                axDescription: extra.rawTitle,
                rawWindowID: includeRaw ? extra.windowID : nil,
                rawWindowLayer: includeRaw ? extra.windowLayer : nil,
                rawOwnerPID: includeRaw ? extra.ownerPID : nil,
                rawSource: includeRaw ? extra.source : nil)
        }
    }

    public func clickMenuBarItem(named name: String) async throws -> ClickResult {
        do {
            try await self.clickMenuExtra(title: name)
            return ClickResult(
                elementDescription: "Menu bar item: \(name)",
                location: nil)
        } catch {
            let items = try await listMenuBarItems(includeRaw: false)
            let normalizedName = normalizedMenuTitle(name)

            if let item = items.first(where: {
                titlesMatch(candidate: $0.title, target: name, normalizedTarget: normalizedName)
            }) {
                return try await self.clickMenuBarItem(at: item.index)
            }

            if let item = items.first(where: { menuExtraTitlesMatch(candidate: $0.title, target: name) }) {
                return try await self.clickMenuBarItem(at: item.index)
            }

            if partialMatchEnabled,
               let item = items.first(where: { titlesMatchPartial(
                   candidate: $0.title,
                   target: name,
                   normalizedTarget: normalizedName) })
            {
                return try await self.clickMenuBarItem(at: item.index)
            }

            throw NotFoundError(
                code: .menuNotFound,
                userMessage: "Menu bar item '\(name)' not found",
                context: ["availableItems": items.compactMap(\.title).joined(separator: ", ")])
        }
    }

    public func clickMenuBarItem(at index: Int) async throws -> ClickResult {
        let extras = try await listMenuExtras()

        guard index >= 0, index < extras.count else {
            throw PeekabooError
                .invalidInput("Invalid menu bar item index: \(index). Valid range: 0-\(extras.count - 1)")
        }

        let extra = extras[index]
        guard extra.isVisible else {
            throw PeekabooError.operationError(
                message: self.hiddenMenuExtraMessage(title: extra.title))
        }
        guard let clickPoint = self.resolveMenuExtraClickPoint(for: extra) else {
            throw PeekabooError.operationError(message: "Menu bar item has no clickable position")
        }
        guard self.isMenuExtraPointVisible(clickPoint) else {
            throw PeekabooError.operationError(
                message: self.hiddenMenuExtraMessage(title: extra.title))
        }

        try? InputDriver.move(to: clickPoint)

        if !self.tryWindowTargetedClick(extra: extra, point: clickPoint) {
            let clickService = ClickService()
            try await clickService.click(
                target: .coordinates(clickPoint),
                clickType: .single,
                snapshotId: nil)
        }

        return ClickResult(
            elementDescription: "Menu bar item [\(index)]: \(extra.title)",
            location: clickPoint)
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
