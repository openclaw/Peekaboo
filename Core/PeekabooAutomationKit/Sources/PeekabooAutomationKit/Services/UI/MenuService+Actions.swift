//
//  MenuService+Actions.swift
//  PeekabooCore
//

import AppKit
import AXorcist
import Foundation
import PeekabooFoundation

private struct NamedMenuPathSearch {
    let itemName: String
    let maxDepth: Int
    var remaining: Int
    var paths: [String] = []

    mutating func collect(in items: [MenuItem], currentPath: String, depth: Int) {
        guard self.remaining > 0, depth <= self.maxDepth, self.paths.count <= 1 else { return }

        for item in items {
            guard self.remaining > 0, self.paths.count <= 1 else { return }
            self.remaining -= 1
            if item.title == self.itemName, !item.isSeparator {
                self.paths.append("\(currentPath) > \(item.title)")
            }

            if !item.submenu.isEmpty {
                self.collect(
                    in: item.submenu,
                    currentPath: "\(currentPath) > \(item.title)",
                    depth: depth + 1)
            }
        }
    }
}

@MainActor
extension MenuService {
    public func clickMenuItem(app: String, itemPath: String) async throws {
        _ = try await self.clickMenuItemActionResult(app: app, itemPath: itemPath)
    }

    public func clickMenuItemActionResult(
        app: String,
        itemPath: String) async throws -> UIAutomationActionResult<Void>
    {
        let appInfo = try await applicationService.findApplication(identifier: app)
        guard let processIdentity = appInfo.processIdentity else {
            throw PeekabooError.commandFailed(
                "Could not capture a stable process-generation identity for \(appInfo.name)")
        }
        return try await self.clickMenuItemActionResult(request: MenuItemActionRequest(
            appIdentifier: "PID:\(processIdentity.processIdentifier)",
            itemPath: itemPath,
            expectedIdentity: processIdentity))
    }

    public func clickMenuItemActionResult(
        request: MenuItemActionRequest) async throws -> UIAutomationActionResult<Void>
    {
        let appInfo = try await applicationService.findApplication(identifier: request.appIdentifier)
        try Self.validateResolvedApplication(
            appInfo,
            expectedIdentity: request.expectedIdentity,
            operation: "menu item click")
        return try await self.withPinnedMenuFailureAttribution(processIdentity: request.expectedIdentity) {
            try await self.operationLaneCoordinator.run(scope: .process(request.expectedIdentity), access: .write) {
                let delivery = Self.menuActionDelivery(mode: request.deliveryMode)
                let submittedUnitCount = try await self.performMenuItemClick(
                    appInfo: appInfo,
                    processIdentity: request.expectedIdentity,
                    itemPath: request.itemPath,
                    delivery: delivery)
                return try Self.menuActionResult(
                    processIdentity: request.expectedIdentity,
                    submittedUnitCount: submittedUnitCount,
                    delivery: delivery)
            }
        }
    }

    public func clickMenuItemByName(app: String, itemName: String) async throws {
        _ = try await self.clickMenuItemByNameActionResult(app: app, itemName: itemName)
    }

    public func clickMenuItemByNameActionResult(
        app: String,
        itemName: String) async throws -> UIAutomationActionResult<Void>
    {
        let appInfo = try await applicationService.findApplication(identifier: app)
        guard let processIdentity = appInfo.processIdentity else {
            throw PeekabooError.commandFailed(
                "Could not capture a stable process-generation identity for \(appInfo.name)")
        }
        return try await self.clickMenuItemByNameActionResult(request: MenuItemByNameActionRequest(
            appIdentifier: "PID:\(processIdentity.processIdentifier)",
            itemName: itemName,
            expectedIdentity: processIdentity))
    }

    public func clickMenuItemByNameActionResult(
        request: MenuItemByNameActionRequest) async throws -> UIAutomationActionResult<Void>
    {
        let appInfo = try await applicationService.findApplication(identifier: request.appIdentifier)
        try Self.validateResolvedApplication(
            appInfo,
            expectedIdentity: request.expectedIdentity,
            operation: "named menu item click")
        let menuStructure = try await listMenus(for: request.appIdentifier)

        let resolution = Self.namedMenuPaths(
            itemName: request.itemName,
            in: menuStructure,
            maxDepth: traversalLimits.maxDepth,
            maxChildren: traversalLimits.maxChildren)
        let itemPath = try Self.resolvedNamedMenuPath(
            itemName: request.itemName,
            applicationName: appInfo.name,
            resolution: resolution)

        return try await self.withPinnedMenuFailureAttribution(processIdentity: request.expectedIdentity) {
            try await self.operationLaneCoordinator.run(scope: .process(request.expectedIdentity), access: .write) {
                let delivery = Self.menuActionDelivery(mode: request.deliveryMode)
                let submittedUnitCount = try await self.performMenuItemClick(
                    appInfo: appInfo,
                    processIdentity: request.expectedIdentity,
                    itemPath: itemPath,
                    delivery: delivery)
                return try Self.menuActionResult(
                    processIdentity: request.expectedIdentity,
                    submittedUnitCount: submittedUnitCount,
                    delivery: delivery)
            }
        }
    }

    static func resolvedNamedMenuPath(
        itemName: String,
        applicationName: String,
        resolution: (paths: [String], exhausted: Bool)) throws -> String
    {
        guard resolution.paths.count <= 1 else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Menu item '\(itemName)' is ambiguous in application '\(applicationName)'.",
                hint: "Use one explicit menu path: \(resolution.paths.joined(separator: ", ")).")
        }
        guard let itemPath = resolution.paths.first else {
            var context = ErrorContext()
            context.add("application", applicationName)
            context.add("item", itemName)
            if resolution.exhausted {
                context.add("limit", "menu traversal budget reached")
            }
            throw NotFoundError(
                code: .menuNotFound,
                userMessage: "Menu item '\(itemName)' not found in application '\(applicationName)'",
                context: context.build())
        }
        guard !resolution.exhausted else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Menu item '\(itemName)' was found in application '\(applicationName)', but its " +
                    "uniqueness could not be verified within the traversal budget.",
                hint: "Use one explicit menu path instead of a name-only selector.")
        }
        return itemPath
    }

    func withPinnedMenuFailureAttribution<Result>(
        processIdentity: ApplicationProcessIdentity,
        operation: () async throws -> Result) async throws -> Result
    {
        do {
            return try await operation()
        } catch let failure as DesktopActionFailure {
            throw failure.attributed(to: processIdentity)
        }
    }

    static func validateResolvedApplication(
        _ application: ServiceApplicationInfo,
        expectedIdentity: ApplicationProcessIdentity,
        operation: String) throws
    {
        guard application.processIdentity == expectedIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Application PID \(expectedIdentity.processIdentifier) changed generation " +
                    "before \(operation).",
                hint: "Refresh the application menu before retrying.")
        }
    }

    private func performMenuItemClick(
        appInfo: ServiceApplicationInfo,
        processIdentity: ApplicationProcessIdentity,
        itemPath: String,
        delivery: DesktopActionOutcome.Delivery) async throws -> DesktopActionOutcome.DispatchUnitCount
    {
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
            processIdentity: processIdentity,
            delivery: delivery,
            budget: MenuTraversalBudget(limits: traversalLimits))

        do {
            _ = try await self.walkMenuPath(
                startingElement: menuBar,
                components: pathComponents,
                context: &traversalContext)
            try Task.checkCancellation()
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch is CancellationError {
            try Self.rethrowMenuCancellation(
                submittedUnitCount: traversalContext.submittedUnitCount,
                itemPath: itemPath,
                delivery: delivery)
        } catch {
            guard traversalContext.submittedUnitCount > 0 else { throw error }
            throw DesktopActionFailure.partial(
                delivery: delivery,
                unitCount: Self.menuDispatchUnitCount(traversalContext.submittedUnitCount),
                message: "Menu traversal stopped after part of '\(itemPath)' was dispatched.",
                hint: "Observe or dismiss the open application menu before retrying.",
                causeDescription: error.localizedDescription)
        }
        return Self.menuDispatchUnitCount(traversalContext.submittedUnitCount)
    }

    private static func menuActionResult(
        processIdentity: ApplicationProcessIdentity,
        submittedUnitCount: DesktopActionOutcome.DispatchUnitCount,
        delivery: DesktopActionOutcome.Delivery) throws -> UIAutomationActionResult<Void>
    {
        try UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: submittedUnitCount),
            targetIdentity: DesktopTargetIdentity(processIdentity: processIdentity))
    }

    static func namedMenuPaths(
        itemName: String,
        in structure: MenuStructure,
        maxDepth: Int,
        maxChildren: Int) -> (paths: [String], exhausted: Bool)
    {
        var search = NamedMenuPathSearch(
            itemName: itemName,
            maxDepth: maxDepth,
            remaining: maxChildren)
        for menu in structure.menus {
            search.collect(
                in: menu.items,
                currentPath: menu.title,
                depth: 1)
            if search.paths.count > 1 {
                break
            }
        }
        return (search.paths, search.remaining == 0)
    }
}
