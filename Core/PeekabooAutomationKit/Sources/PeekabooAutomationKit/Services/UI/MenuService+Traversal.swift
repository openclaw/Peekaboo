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
        let candidateTitles = children.map { element in
            [element.title(), (element.value() as? NSAttributedString)?.string].compactMap(\.self)
        }
        let matchingIndexes = Self.menuItemMatchIndexes(
            named: component,
            candidateTitles: candidateTitles)
        guard matchingIndexes.count <= 1 else {
            throw Self.menuAmbiguityFailure(
                component: component,
                context: context,
                detail: "\(matchingIndexes.count) matching menu items")
        }
        guard let matchingIndex = matchingIndexes.first else {
            var errorContext = ErrorContext()
            errorContext.add("menuItem", component)
            errorContext.add("path", context.fullPath)
            errorContext.add("application", context.appInfo.name)
            throw NotFoundError(
                code: .menuNotFound,
                userMessage: "Menu item '\(component)' not found in path '\(context.fullPath)'",
                context: errorContext.build())
        }
        let menuItem = children[matchingIndex]

        context.menuPath.append(component)

        if isLastComponent {
            try self.pressMenuItem(
                menuItem,
                action: "click menu item",
                target: component,
                context: &context)
            return currentElement
        }

        try self.pressMenuItem(
            menuItem,
            action: "open submenu",
            target: component,
            context: &context)
        if context.menuPath.count > 1 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let submenus = (menuItem.children() ?? []).filter { $0.role() == AXRoleNames.kAXMenuRole }
        guard submenus.count <= 1 else {
            throw Self.menuAmbiguityFailure(
                component: component,
                context: context,
                detail: "\(submenus.count) matching submenu containers")
        }
        guard let submenu = submenus.first else {
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

    private func pressMenuItem(
        _ element: Element,
        action: String,
        target: String,
        context: inout MenuTraversalContext) throws
    {
        let processIdentity = context.processIdentity
        let delivery = context.delivery
        try Self.dispatchMenuPress(
            submittedUnitCount: &context.submittedUnitCount,
            action: action,
            target: target,
            delivery: delivery,
            validateTarget: {
                guard SystemIdentityResolver.processStartIdentity(processIdentity.processIdentifier) ==
                    processIdentity.processStartIdentity
                else {
                    throw PeekabooError.commandFailed(
                        "Application PID \(processIdentity.processIdentifier) changed generation before AXPress")
                }
            },
            submit: {
                try element.performAction(Attribute<String>("AXPress"))
            })
    }

    static func menuActionDelivery(
        mode: DesktopActionOutcome.Delivery.Mode) -> DesktopActionOutcome.Delivery
    {
        DesktopActionOutcome.Delivery(mechanism: .accessibilityAction, mode: mode)
    }

    static func dispatchMenuPress(
        submittedUnitCount: inout Int,
        action: String,
        target: String,
        delivery: DesktopActionOutcome.Delivery = .init(
            mechanism: .accessibilityAction,
            mode: .foreground),
        checkCancellation: () throws -> Void = { try Task.checkCancellation() },
        validateTarget: () throws -> Void,
        submit: () throws -> Void) throws
    {
        do {
            try checkCancellation()
        } catch {
            try self.rethrowMenuCancellation(
                submittedUnitCount: submittedUnitCount,
                itemPath: target,
                delivery: delivery)
        }

        do {
            try validateTarget()
        } catch {
            guard submittedUnitCount > 0 else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Menu target changed before \(action) '\(target)'.",
                    hint: "Refresh the application menu and retry against its current process generation.",
                    causeDescription: error.localizedDescription)
            }
            throw DesktopActionFailure.partial(
                delivery: delivery,
                unitCount: self.menuDispatchUnitCount(submittedUnitCount),
                message: "Menu target changed after \(submittedUnitCount) action(s) were dispatched.",
                hint: "Observe or dismiss the open application menu before retrying.",
                causeDescription: error.localizedDescription)
        }

        do {
            try checkCancellation()
        } catch {
            try self.rethrowMenuCancellation(
                submittedUnitCount: submittedUnitCount,
                itemPath: target,
                delivery: delivery)
        }

        do {
            try submit()
        } catch {
            throw DesktopActionFailure.indeterminate(
                delivery: delivery,
                evidence: .completionUnknown,
                unitCount: self.menuDispatchUnitCount(submittedUnitCount + 1),
                message: "Menu \(action) '\(target)' returned without reliable dispatch evidence.",
                hint: "Observe the application menu before retrying; the AXPress may have completed.",
                causeDescription: error.localizedDescription)
        }
        submittedUnitCount += 1
    }

    static func rethrowMenuCancellation(
        submittedUnitCount: Int,
        itemPath: String,
        delivery: DesktopActionOutcome.Delivery = .init(
            mechanism: .accessibilityAction,
            mode: .foreground)) throws -> Never
    {
        guard submittedUnitCount > 0 else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .requestCancelled,
                message: "Menu traversal for '\(itemPath)' was cancelled before AXPress.",
                hint: "Submit a new request only if the menu action is still wanted.")
        }
        throw DesktopActionFailure.indeterminate(
            delivery: delivery,
            evidence: .completionUnknown,
            unitCount: self.menuDispatchUnitCount(submittedUnitCount),
            message: "Menu traversal for '\(itemPath)' was cancelled after dispatch started.",
            hint: "Observe or dismiss the open application menu before retrying.")
    }

    static func menuDispatchUnitCount(_ count: Int) -> DesktopActionOutcome.DispatchUnitCount {
        guard let unitCount = DesktopActionOutcome.DispatchUnitCount(count) else {
            preconditionFailure("A completed menu traversal must submit at least one AXPress")
        }
        return unitCount
    }

    static func menuItemMatchIndexes(
        named name: String,
        candidateTitles: [[String]]) -> [Int]
    {
        let normalizedTarget = normalizedMenuTitle(name)
        return candidateTitles.indexed().compactMap { index, titles in
            titles.contains { title in
                titlesMatch(candidate: title, target: name, normalizedTarget: normalizedTarget)
            } ? index : nil
        }
    }

    private static func menuAmbiguityFailure(
        component: String,
        context: MenuTraversalContext,
        detail: String) -> DesktopActionFailure
    {
        let message = "Menu path '\(context.fullPath)' is ambiguous at '\(component)' (\(detail))."
        let hint = "Use a unique menu path or remove duplicate menu items before retrying."
        guard context.submittedUnitCount > 0 else {
            return .preDispatchRefusal(
                reason: .invalidRequest,
                message: message,
                hint: hint)
        }
        return .partial(
            delivery: context.delivery,
            unitCount: self.menuDispatchUnitCount(context.submittedUnitCount),
            message: message,
            hint: "Observe or dismiss the open menu, then \(hint.lowercased())")
    }
}
