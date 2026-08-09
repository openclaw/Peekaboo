//
//  MenuSystemToolFormatter.swift
//  PeekabooCore
//

import Foundation
import PeekabooAutomation

/// Formatter for menu and dialog tools with comprehensive result formatting.
public class MenuSystemToolFormatter: BaseToolFormatter {
    override public func formatCompactSummary(arguments: [String: Any]) -> String {
        switch self.toolType {
        case .menu:
            let action = arguments["action"] as? String ?? "menu"
            var parts = [action.replacingOccurrences(of: "-", with: " ")]
            if let path = arguments["path"] as? String {
                parts.append(self.normalizedMenuPath(path))
            } else if let app = arguments["app"] as? String {
                parts.append("for \(app)")
            }
            return parts.joined(separator: " · ")

        case .dialog:
            let action = arguments["action"] as? String ?? "dialog"
            var parts = [action]
            if let button = arguments["button"] as? String {
                parts.append("\"\(button)\"")
            } else if let field = arguments["field"] as? String {
                parts.append("\(field) field")
            }
            if let app = arguments["app"] as? String {
                parts.append("in \(app)")
            }
            return parts.joined(separator: " ")

        case .dock:
            let action = arguments["action"] as? String ?? "dock"
            var parts = [action.replacingOccurrences(of: "-", with: " ")]
            if let app = arguments["app"] as? String {
                parts.append(app)
            }
            if let selection = arguments["select"] as? String {
                parts.append("→ \(selection)")
            }
            return parts.joined(separator: " ")

        case .menuClick:
            if let path = arguments["path"] as? String {
                return self.normalizedMenuPath(path)
            }
            if let menu = arguments["menu"] as? String {
                if let item = arguments["item"] as? String {
                    return "\(menu) → \(item)"
                }
                return menu
            }
            return ""

        case .listMenus:
            if let app = arguments["app"] as? String ?? arguments["appName"] as? String {
                return "for \(app)"
            }
            return ""

        default:
            return super.formatCompactSummary(arguments: arguments)
        }
    }

    override public func formatResultSummary(result: [String: Any]) -> String {
        switch self.toolType {
        case .menuClick:
            self.formatMenuClickResult(result)

        case .listMenus:
            self.formatListMenuItemsResult(result)

        case .dialogInput:
            self.formatDialogInputResult(result)

        case .dialogClick:
            self.formatDialogClickResult(result)

        default:
            super.formatResultSummary(result: result)
        }
    }

    func normalizedMenuPath(_ path: String) -> String {
        path.components(separatedBy: ">")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " → ")
    }
}
