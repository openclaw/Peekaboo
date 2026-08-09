//
//  MenuSystemToolFormatter+Menu.swift
//  PeekabooCore
//

import Foundation
import PeekabooAutomation

extension MenuSystemToolFormatter {
    // MARK: - Menu Tools

    func formatMenuClickResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        parts.append("→ Clicked menu")

        if let menuPath: [String] = ToolResultExtractor.array("menuPath", from: result) {
            let path = menuPath.joined(separator: " → ")
            parts.append("\"\(path)\"")
        } else if let item = ToolResultExtractor.string("menuItem", from: result) {
            parts.append("\"\(item)\"")
        } else if let clicked = ToolResultExtractor.string("clicked", from: result) {
            parts.append("\"\(clicked)\"")
        } else if let path = ToolResultExtractor.string("path", from: result) {
            parts.append("\"\(self.normalizedMenuPath(path))\"")
        }

        if let app = ToolResultExtractor.string("app", from: result) {
            parts.append("in \(app)")
        }

        var details: [String] = []

        if let action = ToolResultExtractor.string("actionTriggered", from: result) {
            details.append("triggered: \(action)")
        }

        if let windowOpened = ToolResultExtractor.string("windowOpened", from: result) {
            details.append("opened: \(windowOpened)")
        }

        if let shortcut = ToolResultExtractor.string("shortcut", from: result) {
            let formatted = FormattingUtilities.formatKeyboardShortcut(shortcut)
            details.append("shortcut: \(formatted)")
        }

        if let enabled = ToolResultExtractor.bool("wasEnabled", from: result), !enabled {
            details.append("was disabled")
        }

        if !details.isEmpty {
            parts.append("[\(details.joined(separator: ", "))]")
        }

        return parts.joined(separator: " ")
    }

    func formatListMenuItemsResult(_ result: [String: Any]) -> String {
        let items: [[String: Any]]? = ToolResultExtractor.array("items", from: result)
        if items == nil, ToolResultExtractor.int("count", from: result) == nil {
            let menuCount: Int? = if let menus: [[String: Any]] = ToolResultExtractor.array("menus", from: result) {
                menus.count
            } else {
                ToolResultExtractor.int("menuCount", from: result)
            }

            guard let menuCount else { return "" }

            var summary = "→ \(menuCount) menu\(menuCount == 1 ? "" : "s")"
            if let app = ToolResultExtractor.string("app", from: result) ??
                ToolResultExtractor.string("appName", from: result)
            {
                summary += " for \(app)"
            }
            if let totalItems = ToolResultExtractor.int("totalItems", from: result) {
                summary += " (\(totalItems) item\(totalItems == 1 ? "" : "s"))"
            }
            return summary
        }

        var parts: [String] = []

        if let items {
            let count = items.count
            parts.append("→ \(count) menu item\(count == 1 ? "" : "s")")
        } else if let count = ToolResultExtractor.int("count", from: result) {
            parts.append("→ \(count) menu item\(count == 1 ? "" : "s")")
        }

        if let menu = ToolResultExtractor.string("menu", from: result) {
            parts.append("in \(menu) menu")
        }

        if let app = ToolResultExtractor.string("app", from: result) ??
            ToolResultExtractor.string("appName", from: result)
        {
            parts.append("for \(app)")
        }

        if let items {
            let details = self.menuItemDetails(items)
            if !details.isEmpty {
                parts.append("[\(details.joined(separator: ", "))]")
            }
        }

        return parts.joined(separator: " ")
    }

    private func menuItemDetails(_ items: [[String: Any]]) -> [String] {
        var enabledCount = 0
        var disabledCount = 0
        var hasShortcuts = 0
        var hasSubmenus = 0

        for item in items {
            if let enabled = item["enabled"] as? Bool {
                if enabled {
                    enabledCount += 1
                } else {
                    disabledCount += 1
                }
            }
            if let shortcut = item["shortcut"] as? String, !shortcut.isEmpty {
                hasShortcuts += 1
            }
            if let hasSubmenu = item["hasSubmenu"] as? Bool, hasSubmenu {
                hasSubmenus += 1
            }
        }

        var details: [String] = []
        if enabledCount > 0 {
            details.append("\(enabledCount) enabled")
        }
        if disabledCount > 0 {
            details.append("\(disabledCount) disabled")
        }
        if hasShortcuts > 0 {
            details.append("\(hasShortcuts) with shortcuts")
        }
        if hasSubmenus > 0 {
            details.append("\(hasSubmenus) with submenus")
        }

        return details
    }
}
