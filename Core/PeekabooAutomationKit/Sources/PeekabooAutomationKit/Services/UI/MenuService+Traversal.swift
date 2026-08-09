//
//  MenuService+Traversal.swift
//  PeekabooCore
//

import AppKit
import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension MenuService {
    func walkMenuPath(
        startingElement: Element,
        components: [String],
        context: inout MenuTraversalContext) async throws -> Element
    {
        var currentElement = startingElement

        for (index, component) in components.indexed() {
            guard context.budget.allowVisit(depth: index + 1, logger: logger, context: component) else {
                throw PeekabooError.operationError(
                    message: "Menu traversal limits exceeded for path '\(context.fullPath)'")
            }

            let isLastComponent = index == components.count - 1
            currentElement = try await self.navigateMenuLevel(
                currentElement: currentElement,
                component: component,
                isLastComponent: isLastComponent,
                context: &context)
        }

        return currentElement
    }

    private func navigateMenuLevel(
        currentElement: Element,
        component: String,
        isLastComponent: Bool,
        context: inout MenuTraversalContext) async throws -> Element
    {
        let children = currentElement.children() ?? []
        guard let menuItem = findMenuItem(named: component, in: children) else {
            var errorContext = ErrorContext()
            errorContext.add("menuItem", component)
            errorContext.add("path", context.fullPath)
            errorContext.add("application", context.appInfo.name)
            throw NotFoundError(
                code: .menuNotFound,
                userMessage: "Menu item '\(component)' not found in path '\(context.fullPath)'",
                context: errorContext.build())
        }

        context.menuPath.append(component)

        if isLastComponent {
            try await self.pressMenuItem(menuItem, action: "click menu item", target: component)
            return currentElement
        }

        try await self.pressMenuItem(menuItem, action: "open submenu", target: component)
        if context.menuPath.count > 1 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        guard let submenu = menuItem.children()?.first(where: { $0.role() == AXRoleNames.kAXMenuRole }) else {
            var errorContext = ErrorContext()
            errorContext.add("submenu", component)
            errorContext.add("path", context.fullPath)
            errorContext.add("application", context.appInfo.name)
            throw NotFoundError(
                code: .menuNotFound,
                userMessage: "Submenu '\(component)' not found",
                context: errorContext.build())
        }

        return submenu
    }

    private func pressMenuItem(_ element: Element, action: String, target: String) async throws {
        var lastError: (any Error)?

        for attempt in 1...2 {
            do {
                try element.performAction(Attribute<String>("AXPress"))
                return
            } catch {
                lastError = error
                if attempt == 1 {
                    try await Task.sleep(nanoseconds: 30_000_000)
                }
            }
        }

        throw OperationError.interactionFailed(
            action: action,
            reason: "Failed to \(action) '\(target)': \(lastError?.localizedDescription ?? "unknown error")")
    }

    private func findMenuItem(named name: String, in elements: [Element]) -> Element? {
        let normalizedTarget = normalizedMenuTitle(name)

        return elements.first { element in
            if let title = element.title(), titlesMatch(
                candidate: title,
                target: name,
                normalizedTarget: normalizedTarget)
            {
                return true
            }
            if let attrTitle = element.value() as? NSAttributedString,
               titlesMatch(candidate: attrTitle.string, target: name, normalizedTarget: normalizedTarget)
            {
                return true
            }
            return false
        }
    }
}
