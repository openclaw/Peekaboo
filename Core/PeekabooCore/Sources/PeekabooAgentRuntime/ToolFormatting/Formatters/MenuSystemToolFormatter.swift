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
