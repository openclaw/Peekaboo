@preconcurrency import AXorcist
import CoreGraphics
import PeekabooFoundation

/// Converts an application's AX menu bar into Peekaboo detection elements.
@MainActor
struct MenuBarElementCollector {
    func appendMenuBar(
        _ menuBar: Element,
        elements: inout [DetectedElement],
        elementIdMap: inout [String: DetectedElement],
        budget: AXTraversalBudget? = nil) -> DetectionTruncationInfo?
    {
        let resolvedBudget = AXTraversalBudget.normalizedForTraversal(budget)
        var truncationInfo: DetectionTruncationInfo?
        guard let menus = menuBar.children() else { return nil }
        if menus.count > resolvedBudget.maxChildrenPerNode {
            truncationInfo = DetectionTruncationInfo.merge(
                truncationInfo,
                DetectionTruncationInfo(maxChildrenPerNodeReached: true))
        }

        for menu in menus.prefix(resolvedBudget.maxChildrenPerNode) {
            guard self.canAppendElement(
                depth: 0,
                elementCount: elements.count,
                budget: resolvedBudget,
                truncationInfo: &truncationInfo)
            else {
                break
            }

            let menuId = "menu_\(elements.count)"
            let menuElement = DetectedElement(
                id: menuId,
                type: .menu,
                label: menu.title() ?? "Menu",
                value: nil,
                bounds: menu.frame() ?? .zero,
                isEnabled: menu.isEnabled() ?? true,
                isSelected: nil,
                attributes: ["role": "AXMenu"])

            elements.append(menuElement)
            elementIdMap[menuId] = menuElement

            if let menuItems = menu.children() {
                self.appendMenuItems(
                    menuItems,
                    depth: 1,
                    elements: &elements,
                    elementIdMap: &elementIdMap,
                    budget: resolvedBudget,
                    truncationInfo: &truncationInfo)
            }
        }
        return truncationInfo
    }

    private func appendMenuItems(
        _ items: [Element],
        depth: Int,
        elements: inout [DetectedElement],
        elementIdMap: inout [String: DetectedElement],
        budget: AXTraversalBudget,
        truncationInfo: inout DetectionTruncationInfo?)
    {
        guard depth < budget.maxDepth else {
            truncationInfo = DetectionTruncationInfo.merge(
                truncationInfo,
                DetectionTruncationInfo(maxDepthReached: true))
            return
        }

        if items.count > budget.maxChildrenPerNode {
            truncationInfo = DetectionTruncationInfo.merge(
                truncationInfo,
                DetectionTruncationInfo(maxChildrenPerNodeReached: true))
        }

        for item in items.prefix(budget.maxChildrenPerNode) {
            guard self.canAppendElement(
                depth: depth,
                elementCount: elements.count,
                budget: budget,
                truncationInfo: &truncationInfo)
            else {
                break
            }

            let itemId = "menuitem_\(elements.count)"
            let menuItemElement = DetectedElement(
                id: itemId,
                type: .other,
                label: item.title() ?? "Menu Item",
                value: nil,
                bounds: item.frame() ?? .zero,
                isEnabled: item.isEnabled() ?? true,
                isSelected: nil,
                attributes: self.menuItemAttributes(item))

            elements.append(menuItemElement)
            elementIdMap[itemId] = menuItemElement

            if let submenu = item.children(), !submenu.isEmpty {
                self.appendMenuItems(
                    submenu,
                    depth: depth + 1,
                    elements: &elements,
                    elementIdMap: &elementIdMap,
                    budget: budget,
                    truncationInfo: &truncationInfo)
            }
        }
    }

    private func canAppendElement(
        depth: Int,
        elementCount: Int,
        budget: AXTraversalBudget,
        truncationInfo: inout DetectionTruncationInfo?) -> Bool
    {
        guard depth < budget.maxDepth else {
            truncationInfo = DetectionTruncationInfo.merge(
                truncationInfo,
                DetectionTruncationInfo(maxDepthReached: true))
            return false
        }

        guard elementCount < budget.maxElementCount else {
            truncationInfo = DetectionTruncationInfo.merge(
                truncationInfo,
                DetectionTruncationInfo(maxElementCountReached: true))
            return false
        }

        return true
    }

    private func menuItemAttributes(_ item: Element) -> [String: String] {
        var attributes = ["role": "AXMenuItem"]

        if let title = item.title() {
            attributes["title"] = title
        }
        if let shortcut = self.keyboardShortcut(item) {
            attributes["keyboardShortcut"] = shortcut
        }
        if item.isEnabled() == false {
            attributes["isEnabled"] = "false"
        }

        return attributes
    }

    private func keyboardShortcut(_ item: Element) -> String? {
        if let shortcut = item.keyboardShortcut() {
            return shortcut
        }

        if let description = item.descriptionText(),
           description.contains("⌘") || description.contains("⌥") || description.contains("⌃")
        {
            return description
        }

        return nil
    }
}
