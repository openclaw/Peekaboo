//
//  MenuService+Actions.swift
//  PeekabooCore
//

import AppKit
import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension MenuService {
    /// Temporary stubs: keep protocol conformance without full traversal
    func listMenusInternal(appIdentifier: String) async throws -> MenuStructure {
        throw PeekabooError.operationError(message: "Menu traversal not yet implemented")
    }

    func listFrontmostMenusInternal() async throws -> MenuStructure {
        throw PeekabooError.operationError(message: "Menu traversal not yet implemented")
    }

    func clickMenuItemInternal(app: String, itemPath: String) async throws {
        _ = (app, itemPath)
        throw PeekabooError.operationError(message: "Menu click not yet implemented")
    }

    func clickMenuItemByNameInternal(app: String, itemName: String) async throws {
        _ = (app, itemName)
        throw PeekabooError.operationError(message: "Menu click by name not yet implemented")
    }

    func clickMenuExtraInternal(title: String) async throws {
        _ = title
        throw PeekabooError.operationError(message: "Menu extra click not yet implemented")
    }

    func listMenuExtrasInternal() async throws -> [MenuExtraInfo] {
        throw PeekabooError.operationError(message: "Menu extras listing not yet implemented")
    }

    func listMenuBarItemsInternal() async throws -> [MenuBarItemInfo] {
        throw PeekabooError.operationError(message: "Menu bar listing not yet implemented")
    }

    func clickMenuBarItemNamedInternal(name: String) async throws -> ClickResult {
        _ = name
        throw PeekabooError.operationError(message: "Menu bar click not yet implemented")
    }

    func clickMenuBarItemIndexInternal(index: Int) async throws -> ClickResult {
        _ = index
        throw PeekabooError.operationError(message: "Menu bar click not yet implemented")
    }

    public func clickMenuItem(app: String, itemPath: String) async throws {
        let appInfo = try await applicationService.findApplication(identifier: app)
        guard let processIdentity = appInfo.processIdentity else {
            throw PeekabooError.commandFailed(
                "Could not capture a stable process-generation identity for \(appInfo.name)")
        }
        try await self.operationLaneCoordinator.run(scope: .process(processIdentity), access: .write) {
            guard SystemIdentityResolver.processStartIdentity(processIdentity.processIdentifier) ==
                processIdentity.processStartIdentity
            else {
                throw PeekabooError.commandFailed(
                    "Application PID \(processIdentity.processIdentifier) changed generation before menu dispatch")
            }

            let pathComponents = itemPath
                .split(separator: ">")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .map { String($0) }

            guard !pathComponents.isEmpty else {
                throw PeekabooError.invalidInput("Menu path is empty")
            }

            guard pathComponents.count <= traversalLimits.maxDepth else {
                throw PeekabooError.invalidInput(
                    "Menu path depth \(pathComponents.count) exceeds limit \(traversalLimits.maxDepth)")
            }

            guard let runningApp = NSRunningApplication(processIdentifier: appInfo.processIdentifier) else {
                throw NotFoundError.application(appInfo.name)
            }
            let appElement = AXApp(runningApp).element

            guard let menuBar = appElement.menuBar() else {
                var context = ErrorContext()
                context.add("application", appInfo.name)
                throw NotFoundError(
                    code: .menuNotFound,
                    userMessage: "Menu bar not found for application '\(appInfo.name)'",
                    context: context.build())
            }

            var traversalContext = MenuTraversalContext(
                menuPath: [],
                fullPath: itemPath,
                appInfo: appInfo,
                budget: MenuTraversalBudget(limits: traversalLimits))

            _ = try await self.walkMenuPath(
                startingElement: menuBar,
                components: pathComponents,
                context: &traversalContext)
        }
    }

    public func clickMenuItemByName(app: String, itemName: String) async throws {
        let appInfo = try await applicationService.findApplication(identifier: app)
        let menuStructure = try await listMenus(for: app)

        var remaining = traversalLimits.maxChildren
        var foundPath: String?

        for menu in menuStructure.menus {
            if let path = findItemPath(
                itemName: itemName,
                in: menu.items,
                currentPath: menu.title,
                depth: 1,
                remaining: &remaining)
            {
                foundPath = path
                break
            }
        }

        guard let itemPath = foundPath else {
            var context = ErrorContext()
            context.add("application", appInfo.name)
            context.add("item", itemName)
            if remaining <= 0 {
                context.add("limit", "menu traversal budget reached")
            }
            throw NotFoundError(
                code: .menuNotFound,
                userMessage: "Menu item '\(itemName)' not found in application '\(appInfo.name)'",
                context: context.build())
        }

        try await self.clickMenuItem(app: app, itemPath: itemPath)
    }

    private func findItemPath(
        itemName: String,
        in items: [MenuItem],
        currentPath: String,
        depth: Int,
        remaining: inout Int) -> String?
    {
        guard remaining > 0 else { return nil }
        guard depth <= traversalLimits.maxDepth else { return nil }
        remaining -= 1

        for item in items {
            if item.title == itemName, !item.isSeparator {
                return "\(currentPath) > \(item.title)"
            }

            if !item.submenu.isEmpty,
               let path = findItemPath(
                   itemName: itemName,
                   in: item.submenu,
                   currentPath: "\(currentPath) > \(item.title)",
                   depth: depth + 1,
                   remaining: &remaining)
            {
                return path
            }
        }

        return nil
    }
}
