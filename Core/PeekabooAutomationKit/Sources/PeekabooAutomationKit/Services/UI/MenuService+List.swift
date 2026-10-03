//
//  MenuService+List.swift
//  PeekabooCore
//

import AppKit
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
extension MenuService {
    public func listMenus(for appIdentifier: String) async throws -> MenuStructure {
        if let cached = menuCache[appIdentifier], cached.expiresAt > Date() {
            return cached.structure
        }

        let appInfo = try await applicationService.findApplication(identifier: appIdentifier)
        guard let runningApp = NSRunningApplication(processIdentifier: appInfo.processIdentifier) else {
            throw NotFoundError.application(appIdentifier)
        }
        let appElement = AXApp(runningApp).element

        let menuBar = try self.menuBar(for: appElement, appInfo: appInfo)
        var budget = MenuTraversalBudget(limits: traversalLimits)
        let menus = self.collectMenus(from: menuBar, appInfo: appInfo, budget: &budget)
        let structure = MenuStructure(application: appInfo, menus: menus)
        menuCache[appIdentifier] = (expiresAt: Date().addingTimeInterval(cacheTTL), structure: structure)
        return structure
    }

    public func listFrontmostMenus() async throws -> MenuStructure {
        let frontmostApp = try await applicationService.getFrontmostApplication()
        return try await self.listMenus(for: frontmostApp.bundleIdentifier ?? frontmostApp.name)
    }

    private func menuBar(for appElement: Element, appInfo: ServiceApplicationInfo) throws -> Element {
        guard let menuBar = appElement.menuBarWithTimeout(timeout: 2.0) else {
            var context = ErrorContext()
            context.add("application", appInfo.name)
            throw NotFoundError(
                code: .menuNotFound,
                userMessage: "Menu bar not found for application '\(appInfo.name)'",
                context: context.build())
        }
        return menuBar
    }

    private func collectMenus(
        from menuBar: Element,
        appInfo: ServiceApplicationInfo,
        budget: inout MenuTraversalBudget) -> [Menu]
    {
        var menus: [Menu] = []
        for menuBarItem in menuBar.children() ?? [] {
            guard budget.allowVisit(depth: 1, logger: logger, context: menuBarItem.title() ?? "<menu>") else {
                break
            }

            if let menu = self.extractMenu(
                from: menuBarItem,
                depth: 1,
                parentPath: "",
                application: appInfo,
                budget: &budget)
            {
                menus.append(menu)
            }
        }

        return menus
    }

    private func extractMenu(
        from menuBarItem: Element,
        depth: Int,
        parentPath: String,
        application: ServiceApplicationInfo,
        budget: inout MenuTraversalBudget) -> Menu?
    {
        guard let title = menuBarItem.title() else { return nil }
        guard budget.allowVisit(depth: depth, logger: logger, context: title) else { return nil }

        let isEnabled = menuBarItem.isEnabled() ?? true
        var items: [MenuItem] = []

        if let children = menuBarItem.children(),
           let menuElement = children.first(where: { $0.role() == AXRoleNames.kAXMenuRole })
        {
            if let menuChildren = menuElement.children() {
                let currentPath = parentPath.isEmpty ? title : "\(parentPath) > \(title)"
                let nextDepth = depth + 1
                items = self.extractMenuItems(
                    from: menuChildren,
                    depth: nextDepth,
                    parentPath: currentPath,
                    application: application,
                    budget: &budget)
            }
        }

        return Menu(
            title: title,
            bundleIdentifier: application.bundleIdentifier,
            ownerName: application.name,
            items: items,
            isEnabled: isEnabled)
    }

    private func extractMenuItems(
        from elements: [Element],
        depth: Int,
        parentPath: String,
        application: ServiceApplicationInfo,
        budget: inout MenuTraversalBudget) -> [MenuItem]
    {
        var items: [MenuItem] = []

        for element in elements {
            guard budget.allowVisit(depth: depth, logger: logger, context: parentPath) else {
                break
            }

            if let item = self.extractMenuItem(
                from: element,
                depth: depth,
                parentPath: parentPath,
                application: application,
                budget: &budget)
            {
                items.append(item)
            }
        }

        return items
    }

    private func extractMenuItem(
        from element: Element,
        depth: Int,
        parentPath: String,
        application: ServiceApplicationInfo,
        budget: inout MenuTraversalBudget) -> MenuItem?
    {
        if element.role() == "AXSeparatorMenuItem" {
            return MenuItem(
                title: "---",
                bundleIdentifier: application.bundleIdentifier,
                ownerName: application.name,
                isSeparator: true,
                path: "\(parentPath) > ---")
        }

        let title = element.title() ?? element.attribute(Attribute<String>(AXAttributeNames.kAXValueAttribute)) ?? ""
        guard !title.isEmpty else { return nil }

        let path = "\(parentPath) > \(title)"
        let isEnabled = element.isEnabled() ?? true
        let isChecked = element.value() as? Bool ?? false
        let keyboardShortcut = self.extractKeyboardShortcut(from: element)

        var submenuItems: [MenuItem] = []
        if depth + 1 <= traversalLimits.maxDepth,
           let children = element.children(),
           let submenuElement = children.first(where: { $0.role() == AXRoleNames.kAXMenuRole }),
           let submenuChildren = submenuElement.children()
        {
            submenuItems = self.extractMenuItems(
                from: submenuChildren,
                depth: depth + 1,
                parentPath: path,
                application: application,
                budget: &budget)
        }

        return MenuItem(
            title: title,
            bundleIdentifier: application.bundleIdentifier,
            ownerName: application.name,
            keyboardShortcut: keyboardShortcut,
            isEnabled: isEnabled,
            isChecked: isChecked,
            isSeparator: false,
            submenu: submenuItems,
            path: path)
    }

    private func extractKeyboardShortcut(from element: Element) -> KeyboardShortcut? {
        if let cmdChar = element.attribute(Attribute<String>("AXMenuItemCmdChar")),
           let modifiers = element.attribute(Attribute<Int>("AXMenuItemCmdModifiers"))
        {
            return self.formatKeyboardShortcut(cmdChar: cmdChar, modifiers: modifiers)
        }
        return nil
    }

    private func formatKeyboardShortcut(cmdChar: String, modifiers: Int) -> KeyboardShortcut {
        var modifierSet: Set<String> = []
        var displayParts: [String] = []

        if modifiers & (1 << 3) == 0 {
            modifierSet.insert("cmd")
            displayParts.append("⌘")
        }
        if modifiers & (1 << 0) != 0 {
            modifierSet.insert("shift")
            displayParts.append("⇧")
        }
        if modifiers & (1 << 1) != 0 {
            modifierSet.insert("option")
            displayParts.append("⌥")
        }
        if modifiers & (1 << 2) != 0 {
            modifierSet.insert("ctrl")
            displayParts.append("⌃")
        }

        displayParts.append(cmdChar.uppercased())

        return KeyboardShortcut(
            modifiers: modifierSet,
            key: cmdChar,
            displayString: displayParts.joined())
    }
}
