//
//  MenuService+MenuExtraAccessibility.swift
//  PeekabooCore
//

import AppKit
import AXorcist
import Foundation

@MainActor
extension MenuService {
    /// Attempt to pull status items hosted inside Control Center/system UI via accessibility.
    func getMenuBarItemsFromControlCenterAX(timeout: Float) -> [MenuExtraInfo] {
        let hostBundleIDs = [
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
        ]
        let hosts = NSWorkspace.shared.runningApplications.filter { app in
            if let bid = app.bundleIdentifier {
                return hostBundleIDs.contains(bid)
            }
            return false
        }

        func collectElements(from element: Element, depth: Int = 0, limit: Int = 6) -> [Element] {
            if depth > limit {
                return []
            }
            var results: [Element] = []
            element.setMessagingTimeout(timeout)
            if let children = element.children(strict: true) {
                for child in children {
                    results.append(child)
                    results.append(contentsOf: collectElements(from: child, depth: depth + 1, limit: limit))
                }
            }
            return results
        }

        var items: [MenuExtraInfo] = []

        for host in hosts {
            let axApp = AXApp(host).element
            axApp.setMessagingTimeout(timeout)
            let candidates = collectElements(from: axApp)
            for extra in candidates {
                extra.setMessagingTimeout(timeout)
                let baseTitle = extra.title() ?? extra.help() ?? extra.descriptionText() ?? "Unknown"
                let identifier = extra.identifier()
                let hasIdentifier = identifier?.isEmpty == false
                let hasNonPlaceholderTitle = !isPlaceholderMenuTitle(baseTitle)
                if !hasIdentifier, !hasNonPlaceholderTitle {
                    continue
                }

                var effectiveTitle = baseTitle
                if isPlaceholderMenuTitle(effectiveTitle),
                   let children = extra.children(strict: true)
                {
                    if let childDerived = children
                        .compactMap({ sanitizedMenuText($0.title()) ?? sanitizedMenuText($0.descriptionText()) })
                        .first(where: { !isPlaceholderMenuTitle($0) })
                    {
                        effectiveTitle = childDerived
                    } else if let ident = sanitizedMenuText(identifier), !ident.isEmpty {
                        effectiveTitle = ident
                    }
                }

                let position = extra.position() ?? .zero
                if !self.isLikelyMenuBarAXPosition(position) {
                    continue
                }

                let info = MenuExtraInfo(
                    title: self.makeMenuExtraDisplayName(
                        rawTitle: effectiveTitle,
                        ownerName: host.localizedName,
                        bundleIdentifier: host.bundleIdentifier,
                        identifier: identifier),
                    rawTitle: baseTitle,
                    bundleIdentifier: host.bundleIdentifier,
                    ownerName: host.localizedName,
                    position: position,
                    isVisible: self.isMenuExtraAXPositionVisible(position),
                    identifier: identifier,
                    source: "ax-control-center")
                items.append(info)
            }
        }

        return items
    }

    func getMenuBarItemsViaAccessibility(timeout: Float) -> [MenuExtraInfo] {
        let systemWide = Element.systemWide()

        guard let menuBar = systemWide.menuBarWithTimeout(timeout: timeout) else {
            return []
        }

        func flattenExtras(_ element: Element) -> [Element] {
            element.setMessagingTimeout(timeout)
            guard let children = element.children(strict: true) else { return [] }
            var results: [Element] = []
            for child in children {
                if child.role() == "AXMenuBarItem" || child.role() == "AXGroup" {
                    results.append(child)
                }
                results.append(contentsOf: flattenExtras(child))
            }
            return results
        }

        let candidates = flattenExtras(menuBar)
        let accessoryApps = NSWorkspace.shared.runningApplications

        return candidates.compactMap { extra in
            extra.setMessagingTimeout(timeout)
            let baseTitle = extra.title() ?? extra.help() ?? extra.descriptionText() ?? "Unknown"
            var effectiveTitle = baseTitle
            if isPlaceholderMenuTitle(effectiveTitle),
               let children = extra.children(strict: true)
            {
                if let childDerived = children
                    .compactMap({ sanitizedMenuText($0.title()) ?? sanitizedMenuText($0.descriptionText()) })
                    .first(where: { !isPlaceholderMenuTitle($0) })
                {
                    effectiveTitle = childDerived
                } else if let ident = sanitizedMenuText(extra.identifier()), !ident.isEmpty {
                    effectiveTitle = ident
                }
            }
            let position = extra.position() ?? .zero
            let identifier = extra.identifier()
            let matchedApp = self.matchMenuExtraApp(
                title: effectiveTitle,
                identifier: identifier,
                apps: accessoryApps)
            let ownerName = matchedApp?.localizedName
            let bundleIdentifier = matchedApp?.bundleIdentifier
            let ownerPID = matchedApp.map { pid_t($0.processIdentifier) }

            return MenuExtraInfo(
                title: self.makeMenuExtraDisplayName(
                    rawTitle: effectiveTitle,
                    ownerName: ownerName,
                    bundleIdentifier: bundleIdentifier,
                    identifier: identifier),
                rawTitle: baseTitle,
                bundleIdentifier: bundleIdentifier,
                ownerName: ownerName,
                position: position,
                isVisible: self.isMenuExtraAXPositionVisible(position),
                identifier: identifier,
                ownerPID: ownerPID,
                source: "ax-menubar")
        }
    }

    func matchMenuExtraApp(
        title: String,
        identifier: String?,
        apps: [NSRunningApplication]) -> NSRunningApplication?
    {
        let normalizedTitle = title.lowercased()
        let normalizedIdentifier = identifier?.lowercased()

        if let normalizedIdentifier,
           let exact = apps.first(where: { $0.bundleIdentifier?.lowercased() == normalizedIdentifier })
        {
            return exact
        }

        if let exact = apps.first(where: { $0.localizedName?.lowercased() == normalizedTitle }) {
            return exact
        }

        if let normalizedIdentifier,
           let fuzzy = apps.first(where: { ($0.bundleIdentifier ?? "").lowercased().contains(normalizedIdentifier) })
        {
            return fuzzy
        }

        if normalizedTitle != "unknown",
           let fuzzy = apps.first(where: { ($0.bundleIdentifier ?? "").lowercased().contains(normalizedTitle) })
        {
            return fuzzy
        }

        return nil
    }

    func hydrateMenuExtraOwners(_ extras: [MenuExtraInfo]) -> [MenuExtraInfo] {
        let runningApps = NSWorkspace.shared.runningApplications
        var appsByBundle: [String: NSRunningApplication] = [:]
        for app in runningApps {
            if let bundle = app.bundleIdentifier {
                appsByBundle[bundle] = app
            }
        }

        return extras.map { extra in
            guard extra.ownerPID == nil else { return extra }
            var matched: NSRunningApplication?

            if let bundle = extra.bundleIdentifier {
                matched = appsByBundle[bundle]
            }

            if matched == nil, let ownerName = extra.ownerName {
                matched = runningApps.first(where: { $0.localizedName == ownerName })
            }

            guard let matched else { return extra }

            return MenuExtraInfo(
                title: extra.title,
                rawTitle: extra.rawTitle,
                bundleIdentifier: extra.bundleIdentifier ?? matched.bundleIdentifier,
                ownerName: extra.ownerName ?? matched.localizedName,
                position: extra.position,
                isVisible: extra.isVisible,
                identifier: extra.identifier,
                windowID: extra.windowID,
                windowLayer: extra.windowLayer,
                ownerPID: matched.processIdentifier,
                source: extra.source)
        }
    }

    /// Sweep AX trees of all running apps to find menu bar/status items that expose AX titles or identifiers.
    func accessoryAppsForMenuExtras() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy != .regular
        }
    }

    func getMenuBarItemsFromAppsAX(
        timeout: Float,
        apps: [NSRunningApplication]) -> [MenuExtraInfo]
    {
        let running = apps
        var results: [MenuExtraInfo] = []
        let commonMenuTitles: Set = [
            "apple", "file", "edit", "view", "window", "help", "history", "bookmarks", "navigate", "tab", "tools",
            "cut", "copy", "paste", "format",
        ]

        func collectElements(from element: Element, depth: Int = 0, limit: Int = 4) -> [Element] {
            if depth > limit {
                return []
            }
            var list: [Element] = []
            element.setMessagingTimeout(timeout)
            if let children = element.children(strict: true) {
                for child in children {
                    list.append(child)
                    list.append(contentsOf: collectElements(from: child, depth: depth + 1, limit: limit))
                }
            }
            return list
        }

        for app in running {
            let axApp = AXApp(app).element
            axApp.setMessagingTimeout(timeout)
            let candidates = collectElements(from: axApp)
            for extra in candidates {
                extra.setMessagingTimeout(timeout)
                let role = extra.role() ?? ""
                let subrole = extra.subrole() ?? ""
                let isStatusLike = role == "AXStatusItem" || subrole == "AXStatusItem" || subrole == "AXMenuExtra"
                if !isStatusLike {
                    continue
                }

                let baseTitle = extra.title() ?? extra.help() ?? extra.descriptionText() ?? ""
                let identifier = extra.identifier()
                let nonPlaceholder = !isPlaceholderMenuTitle(baseTitle) || (identifier?.isEmpty == false)
                guard nonPlaceholder else { continue }

                // Prefer stable identifier/help over child-derived titles to avoid menu-item leakage.
                var effectiveTitle: String = sanitizedMenuText(identifier)
                    ?? sanitizedMenuText(extra.help())
                    ?? sanitizedMenuText(baseTitle)
                    ?? baseTitle

                // Fallbacks to app name when placeholder/short/common menu words.
                if isPlaceholderMenuTitle(effectiveTitle) ||
                    effectiveTitle.count <= 2 ||
                    commonMenuTitles.contains(effectiveTitle.lowercased())
                {
                    effectiveTitle = app.localizedName ?? effectiveTitle
                }

                let position = extra.position() ?? .zero
                // Restrict to top-of-screen positions to avoid stray elements.
                if !self.isLikelyMenuBarAXPosition(position) {
                    continue
                }

                // Avoid duplicating children of a status item: require that this element itself is status-like.
                let childrenRoles = (extra.children(strict: true) ?? []).compactMap { $0.role() }
                if !isStatusLike, childrenRoles.contains(where: { $0 == "AXMenuItem" }) {
                    continue
                }

                let info = MenuExtraInfo(
                    title: self.makeMenuExtraDisplayName(
                        rawTitle: effectiveTitle,
                        ownerName: app.localizedName,
                        bundleIdentifier: app.bundleIdentifier,
                        identifier: identifier),
                    rawTitle: baseTitle,
                    bundleIdentifier: app.bundleIdentifier,
                    ownerName: app.localizedName,
                    position: position,
                    isVisible: self.isMenuExtraAXPositionVisible(position),
                    identifier: identifier,
                    ownerPID: app.processIdentifier,
                    source: "ax-app")
                results.append(info)
            }
        }

        return results
    }

    /// Hit-test window extras to attach AX identifiers/titles when CGS gives only placeholders.
    func enrichWindowExtrasWithAXHitTest(_ extras: [MenuExtraInfo], timeout: Float) -> [MenuExtraInfo] {
        extras.map { extra in
            guard extra
                .identifier == nil || isPlaceholderMenuTitle(extra.title) || isPlaceholderMenuTitle(extra.rawTitle),
                extra.position != .zero
            else { return extra }

            Element.systemWide().setMessagingTimeout(timeout)
            guard let hit = Element.elementAtPoint(extra.position) else {
                return extra
            }

            hit.setMessagingTimeout(timeout)
            let role = hit.role() ?? ""
            let subrole = hit.subrole() ?? ""
            let isStatusLike = role == "AXStatusItem" || subrole == "AXStatusItem" || subrole == "AXMenuExtra"
            if !isStatusLike {
                return extra
            }

            let hitTitle = sanitizedMenuText(hit.identifier())
                ?? sanitizedMenuText(hit.help())
                ?? sanitizedMenuText(hit.title())
                ?? hit.descriptionText()
                ?? extra.rawTitle
                ?? extra.title
            let hitIdentifier = hit.identifier() ?? extra.identifier

            return MenuExtraInfo(
                title: self.makeMenuExtraDisplayName(
                    rawTitle: hitTitle,
                    ownerName: extra.ownerName,
                    bundleIdentifier: extra.bundleIdentifier,
                    identifier: hitIdentifier),
                rawTitle: hitTitle,
                bundleIdentifier: extra.bundleIdentifier,
                ownerName: extra.ownerName,
                position: extra.position,
                isVisible: extra.isVisible,
                identifier: hitIdentifier,
                windowID: extra.windowID,
                windowLayer: extra.windowLayer,
                ownerPID: extra.ownerPID,
                source: extra.source ?? "cgs-hit")
        }
    }
}
