//
//  WindowToolFormatter.swift
//  PeekabooCore
//

import Foundation
import PeekabooAutomation

/// Formatter for window management tools with comprehensive result formatting
public class WindowToolFormatter: BaseToolFormatter {
    override public func formatCompactSummary(arguments: [String: Any]) -> String {
        switch toolType {
        case .window:
            var parts = [(arguments["action"] as? String ?? "window").replacingOccurrences(of: "-", with: " ")]
            if let app = arguments["app"] as? String {
                parts.append(app)
            }
            if let title = arguments["title"] as? String {
                parts.append("\"\(self.truncate(title, maxLength: 30))\"")
            }
            if let width = arguments["width"], let height = arguments["height"] {
                parts.append("\(width)×\(height)")
            }
            return parts.joined(separator: " · ")

        case .space:
            let action = arguments["action"] as? String ?? "space"
            var parts = [action.replacingOccurrences(of: "-", with: " ")]
            if let app = arguments["app"] as? String {
                parts.append(app)
            }
            if let target = arguments["to"] {
                parts.append("to \(target)")
            } else if arguments["to_current"] as? Bool == true {
                parts.append("to current space")
            }
            return parts.joined(separator: " ")

        case .focusWindow:
            if let app = arguments["appName"] as? String {
                return app
            }
            return "active window"

        case .resizeWindow:
            var parts: [String] = []
            if let app = arguments["appName"] as? String {
                parts.append(app)
            }
            if let width = arguments["width"], let height = arguments["height"] {
                parts.append("to \(width)x\(height)")
            }
            return parts.isEmpty ? "active window" : parts.joined(separator: " ")

        case .listWindows:
            if let app = arguments["appName"] as? String {
                return "for \(app)"
            }
            return ""

        case .minimizeWindow, .maximizeWindow:
            if let app = arguments["appName"] as? String {
                return app
            }
            return "active window"

        case .listScreens:
            return ""

        default:
            return super.formatCompactSummary(arguments: arguments)
        }
    }

    override public func formatResultSummary(result: [String: Any]) -> String {
        switch toolType {
        case .focusWindow:
            self.formatFocusWindowResult(result)
        case .resizeWindow:
            self.formatResizeWindowResult(result)
        case .listWindows:
            self.formatListWindowsResult(result)
        case .minimizeWindow:
            self.formatMinimizeWindowResult(result)
        case .maximizeWindow:
            self.formatMaximizeWindowResult(result)
        case .listScreens:
            self.formatListScreensResult(result)
        case .listSpaces:
            self.formatListSpacesResult(result)
        case .switchSpace:
            self.formatSwitchSpaceResult(result)
        case .moveWindowToSpace:
            self.formatMoveWindowToSpaceResult(result)
        default:
            super.formatResultSummary(result: result)
        }
    }

    override public func formatStarting(arguments: [String: Any]) -> String {
        switch toolType {
        case .focusWindow:
            let app = arguments["appName"] as? String ?? "window"
            return "Focusing \(app)..."

        case .resizeWindow:
            let summary = self.formatCompactSummary(arguments: arguments)
            if !summary.isEmpty {
                return "Resizing \(summary)..."
            }
            return "Resizing window..."

        case .listWindows:
            if let app = arguments["appName"] as? String {
                return "Listing windows for \(app)..."
            }
            return "Listing windows..."

        case .minimizeWindow:
            if let app = arguments["appName"] as? String {
                return "Minimizing \(app)..."
            }
            return "Minimizing window..."

        case .maximizeWindow:
            if let app = arguments["appName"] as? String {
                return "Maximizing \(app)..."
            }
            return "Maximizing window..."

        case .listScreens:
            return "Listing screens..."

        case .listSpaces:
            return "Listing Spaces..."

        case .switchSpace:
            if let space = arguments["to"] {
                return "Switching to Space \(space)..."
            }
            return "Switching Space..."

        case .moveWindowToSpace:
            if let app = arguments["appName"] as? String {
                let target = arguments["to"] ?? arguments["to_current"] ?? arguments["follow"]
                return "Moving \(app) window to space \(target ?? "target")..."
            }
            return "Moving window to another space..."

        default:
            return super.formatStarting(arguments: arguments)
        }
    }
}
