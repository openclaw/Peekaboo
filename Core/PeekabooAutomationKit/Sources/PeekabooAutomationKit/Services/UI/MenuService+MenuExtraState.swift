//
//  MenuService+MenuExtraState.swift
//  PeekabooCore
//

import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation

@MainActor
extension MenuService {
    func isMenuExtraMenuOpenInternal(
        title: String,
        ownerPID: pid_t?,
        timeout: Float) -> Bool
    {
        let systemWide = Element.systemWide()
        systemWide.setMessagingTimeout(timeout)
        defer { systemWide.setMessagingTimeout(0) }

        guard let menuBar = systemWide.menuBar() else {
            return false
        }

        let menuBarItems = menuBar.children(strict: true) ?? []
        guard let menuExtrasGroup = menuBarItems.last(where: { $0.role() == "AXGroup" }) else {
            return false
        }

        let extras = menuExtrasGroup.children(strict: true) ?? []
        let normalizedTarget = normalizedMenuTitle(title)
        if let menuExtra = self.findMenuExtra(
            in: extras,
            title: title,
            normalizedTarget: normalizedTarget,
            ownerPID: ownerPID)
        {
            if self.menuExtraHasOpenMenu(menuExtra) {
                return true
            }
        }

        let systemMenus = (systemWide.children(strict: true) ?? []).filter { $0.isMenu() }
        guard !systemMenus.isEmpty else { return false }

        for menu in systemMenus where self.menuMatches(
            menu: menu,
            normalizedTarget: normalizedTarget,
            ownerPID: ownerPID)
        {
            return true
        }

        return false
    }

    func findMenuExtra(
        in extras: [Element],
        title: String,
        normalizedTarget: String?,
        ownerPID: pid_t?) -> Element?
    {
        if let match = extras.first(where: { element in
            let candidates = [
                element.title(),
                element.help(),
                element.descriptionText(),
                element.identifier(),
            ]
            if candidates
                .contains(where: { titlesMatch(candidate: $0, target: title, normalizedTarget: normalizedTarget) })
            {
                return true
            }
            if self.partialMatchEnabled,
               candidates.contains(where: { titlesMatchPartial(
                   candidate: $0,
                   target: title,
                   normalizedTarget: normalizedTarget) })
            {
                return true
            }
            return false
        }) {
            return match
        }

        guard let ownerPID else { return nil }
        return extras.first(where: { $0.pid() == ownerPID })
    }

    func menuExtraHasOpenMenu(_ menuExtra: Element) -> Bool {
        if let menuElement: AXUIElement = menuExtra.attribute(Attribute<AXUIElement>("AXMenu")) {
            let menu = Element(menuElement)
            if let children = menu.children(strict: true), !children.isEmpty {
                return true
            }
        }

        let children = menuExtra.children(strict: true) ?? []
        return children.contains(where: { $0.isMenu() || $0.isMenuItem() })
    }

    func menuExtraOpenMenuFrameInternal(
        title: String,
        ownerPID: pid_t?,
        timeout: Float) -> CGRect?
    {
        let systemWide = Element.systemWide()
        systemWide.setMessagingTimeout(timeout)
        defer { systemWide.setMessagingTimeout(0) }

        guard let menuBar = systemWide.menuBar() else {
            return nil
        }

        let menuBarItems = menuBar.children(strict: true) ?? []
        guard let menuExtrasGroup = menuBarItems.last(where: { $0.role() == "AXGroup" }) else {
            return nil
        }

        let extras = menuExtrasGroup.children(strict: true) ?? []
        let normalizedTarget = normalizedMenuTitle(title)
        if let menuExtra = self.findMenuExtra(
            in: extras,
            title: title,
            normalizedTarget: normalizedTarget,
            ownerPID: ownerPID)
        {
            if self.menuExtraHasOpenMenu(menuExtra),
               let frame = self.menuExtraMenuFrame(menuExtra)
            {
                return frame
            }
        }

        let systemMenus = (systemWide.children(strict: true) ?? []).filter { $0.isMenu() }
        guard !systemMenus.isEmpty else { return nil }

        for menu in systemMenus where self.menuMatches(
            menu: menu,
            normalizedTarget: normalizedTarget,
            ownerPID: ownerPID)
        {
            if let frame = menu.frame() {
                return frame
            }
        }

        return nil
    }

    func menuExtraMenuFrame(_ menuExtra: Element) -> CGRect? {
        if let menuElement: AXUIElement = menuExtra.attribute(Attribute<AXUIElement>("AXMenu")) {
            let menu = Element(menuElement)
            if let frame = menu.frame() {
                return frame
            }
        }

        if let menu = (menuExtra.children(strict: true) ?? []).first(where: { $0.isMenu() }),
           let frame = menu.frame()
        {
            return frame
        }

        return nil
    }

    func menuMatches(menu: Element, normalizedTarget: String?, ownerPID: pid_t?) -> Bool {
        if let ownerPID, menu.pid() == ownerPID {
            return true
        }

        if let ownerPID {
            var remaining = 200
            if self.menuContainsPID(menu: menu, ownerPID: ownerPID, depth: 0, remaining: &remaining) {
                return true
            }
        }

        guard let normalizedTarget else { return false }
        var remaining = 200
        return self.menuContainsTitle(menu: menu, normalizedTarget: normalizedTarget, depth: 0, remaining: &remaining)
    }

    func menuContainsPID(
        menu: Element,
        ownerPID: pid_t,
        depth: Int,
        remaining: inout Int) -> Bool
    {
        guard remaining > 0 else { return false }
        guard let children = menu.children(strict: true) else { return false }

        for child in children {
            guard remaining > 0 else { break }
            remaining -= 1

            if child.pid() == ownerPID {
                return true
            }

            if depth < 2,
               let submenu = child.children(strict: true)?.first(where: { $0.isMenu() })
            {
                if self.menuContainsPID(menu: submenu, ownerPID: ownerPID, depth: depth + 1, remaining: &remaining) {
                    return true
                }
            }
        }

        return false
    }

    func menuContainsTitle(
        menu: Element,
        normalizedTarget: String,
        depth: Int,
        remaining: inout Int) -> Bool
    {
        guard remaining > 0 else { return false }
        guard let children = menu.children(strict: true) else { return false }

        for child in children {
            guard remaining > 0 else { break }
            remaining -= 1

            if self.menuItemMatchesTitle(child, normalizedTarget: normalizedTarget) {
                return true
            }

            if depth < 2,
               let submenu = child.children(strict: true)?.first(where: { $0.isMenu() })
            {
                if self.menuContainsTitle(
                    menu: submenu,
                    normalizedTarget: normalizedTarget,
                    depth: depth + 1,
                    remaining: &remaining)
                {
                    return true
                }
            }
        }

        return false
    }

    func menuItemMatchesTitle(_ element: Element, normalizedTarget: String) -> Bool {
        let candidates: [String?] = [
            element.title(),
            element.descriptionText(),
            element.attribute(Attribute<String>(AXAttributeNames.kAXValueAttribute)),
        ]
        return menuTitleCandidatesContainNormalized(candidates, normalizedTarget: normalizedTarget)
    }
}
