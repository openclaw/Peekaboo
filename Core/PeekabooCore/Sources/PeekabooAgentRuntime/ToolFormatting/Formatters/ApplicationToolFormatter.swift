//
//  ApplicationToolFormatter.swift
//  PeekabooCore
//

import Foundation

/// Formatter for application tools with comprehensive result formatting
public class ApplicationToolFormatter: BaseToolFormatter {
    override public func formatCompactSummary(arguments: [String: Any]) -> String {
        switch self.toolType {
        case .app:
            let action = (arguments["action"] as? String) ?? "manage"
            let target = arguments["name"] as? String ?? arguments["bundleId"] as? String ??
                arguments["to"] as? String
            return [action.replacingOccurrences(of: "-", with: " "), target]
                .compactMap(\.self)
                .joined(separator: " ")
        case .list:
            switch arguments["item_type"] as? String {
            case "application_windows":
                if let app = arguments["app"] as? String {
                    return "windows for \(app)"
                }
                return "application windows"
            case "server_status":
                return "server status"
            case "running_applications":
                return "running applications"
            default:
                if let app = arguments["app"] as? String {
                    return "windows for \(app)"
                }
                return "running applications"
            }
        default:
            return super.formatCompactSummary(arguments: arguments)
        }
    }

    override public func formatResultSummary(result: [String: Any]) -> String {
        switch toolType {
        case .listApps:
            self.formatListAppsResult(result)
        case .launchApp:
            self.formatLaunchAppResult(result)
        case .quitApp:
            self.formatLifecycleResult(result, verb: "Quit")
        case .focusApp:
            self.formatLifecycleResult(result, verb: "Focused")
        case .hideApp:
            self.formatLifecycleResult(result, verb: "Hid")
        case .unhideApp:
            self.formatLifecycleResult(result, verb: "Showed")
        case .switchApp:
            self.formatLifecycleResult(result, verb: "Switched to")
        case .focusWindow:
            self.formatFocusWindowResult(result)
        case .listWindows:
            self.formatListWindowsResult(result)
        case .resizeWindow:
            self.formatResizeWindowResult(result)
        default:
            super.formatResultSummary(result: result)
        }
    }

    private func formatLifecycleResult(_ result: [String: Any], verb: String) -> String {
        guard let app = ToolResultExtractor.string("app", from: result) ??
            ToolResultExtractor.string("appName", from: result) ??
            ToolResultExtractor.string("application", from: result)
        else {
            return ""
        }
        return "→ \(verb) \(app)"
    }

    private func formatListAppsResult(_ result: [String: Any]) -> String {
        let apps: [[String: Any]]? = ToolResultExtractor.array("apps", from: result)
        let appCount = self.resolveAppCount(result: result, apps: apps)
        var parts = ["→ \(appCount) apps running"]

        if let apps {
            if let stateSummary = self.stateSummary(forApps: apps) {
                parts.append(stateSummary)
            }

            if let categorySummary = self.categorySummary(forApps: apps) {
                parts.append(categorySummary)
            }

            if let memorySummary = self.memorySummary(forApps: apps) {
                parts.append(memorySummary)
            }
        }

        return parts.joined(separator: " • ")
    }

    private func formatLaunchAppResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        // App name
        if let app = ToolResultExtractor.string("app", from: result) {
            parts.append("→ Launched \(app)")
        } else if let appName = ToolResultExtractor.string("appName", from: result) {
            parts.append("→ Launched \(appName)")
        } else {
            parts.append("→ Application launched")
        }

        // Process info
        var details: [String] = []

        if let pid = ToolResultExtractor.int("pid", from: result) {
            details.append("PID: \(pid)")
        }

        if let bundleId = ToolResultExtractor.string("bundleIdentifier", from: result) {
            details.append(bundleId)
        }

        // Launch time
        if let launchTime = ToolResultExtractor.double("launchTime", from: result) {
            details.append(String(format: "%.1fs", launchTime))
        }

        // Window info
        if let windowCount = ToolResultExtractor.int("windowCount", from: result) {
            details.append("\(windowCount) window\(windowCount == 1 ? "" : "s")")
        }

        if !details.isEmpty {
            parts.append("[\(details.joined(separator: ", "))]")
        }

        // Launch method
        if let method = ToolResultExtractor.string("launchMethod", from: result) {
            parts.append("via \(method)")
        }

        return parts.joined(separator: " ")
    }

    private func formatFocusWindowResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        // App and window
        if let app = ToolResultExtractor.string("app", from: result) {
            parts.append("→ Focused \(app)")

            if let windowTitle = ToolResultExtractor.string("windowTitle", from: result),
               !windowTitle.isEmpty
            {
                let truncated = windowTitle.count > 40
                    ? String(windowTitle.prefix(40)) + "..."
                    : windowTitle
                parts.append("\"\(truncated)\"")
            }
        } else {
            parts.append("→ Window focused")
        }

        // Window details
        var details: [String] = []

        if let windowIndex = ToolResultExtractor.int("windowIndex", from: result) {
            details.append("Window #\(windowIndex)")
        }

        if let previousApp = ToolResultExtractor.string("previousApp", from: result) {
            details.append("from \(previousApp)")
        }

        // Focus method
        if let method = ToolResultExtractor.string("focusMethod", from: result) {
            details.append("via \(method)")
        }

        if !details.isEmpty {
            parts.append("[\(details.joined(separator: ", "))]")
        }

        return parts.joined(separator: " ")
    }

    private func formatListWindowsResult(_ result: [String: Any]) -> String {
        let windows: [[String: Any]]? = ToolResultExtractor.array("windows", from: result)
        let windowCount = self.resolveWindowCount(result: result, windows: windows)
        var parts = [self.windowCountSummary(count: windowCount, result: result)]

        if let windows {
            if let stateSummary = self.windowStateSummary(for: windows) {
                parts.append(stateSummary)
            }

            if let titleSummary = self.windowTitleSummary(for: windows, count: windowCount) {
                parts.append(titleSummary)
            }
        }

        return parts.joined(separator: " ")
    }

    private func formatResizeWindowResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        parts.append("→ Window resized")

        // New size
        if let newSize = ToolResultExtractor.dictionary("newSize", from: result) {
            if let width = newSize["width"] as? Int,
               let height = newSize["height"] as? Int
            {
                parts.append("to \(width)×\(height)")
            }
        }

        // Old size for comparison
        if let oldSize = ToolResultExtractor.dictionary("oldSize", from: result) {
            if let width = oldSize["width"] as? Int,
               let height = oldSize["height"] as? Int
            {
                parts.append("(was \(width)×\(height))")
            }
        }

        // Position if changed
        if let newPosition = ToolResultExtractor.dictionary("newPosition", from: result) {
            if let x = newPosition["x"] as? Int,
               let y = newPosition["y"] as? Int
            {
                parts.append("at (\(x), \(y))")
            }
        }

        // Resize action
        if let action = ToolResultExtractor.string("action", from: result) {
            parts.append("[\(action)]")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Helper Methods

    private func resolveAppCount(result: [String: Any], apps: [[String: Any]]?) -> Int {
        if let count = ToolResultExtractor.int("count", from: result) {
            return count
        }

        return apps?.count ?? 0
    }

    private func stateSummary(forApps apps: [[String: Any]]) -> String? {
        var active = 0
        var hidden = 0
        var background = 0

        for app in apps {
            if let isActive = app["isActive"] as? Bool, isActive {
                active += 1
            }
            if let isHidden = app["isHidden"] as? Bool, isHidden {
                hidden += 1
            }
            if let isBackground = app["isBackground"] as? Bool, isBackground {
                background += 1
            }
        }

        var segments: [String] = []
        if active > 0 {
            segments.append("\(active) active")
        }
        if hidden > 0 {
            segments.append("\(hidden) hidden")
        }
        if background > 0 {
            segments.append("\(background) background")
        }

        guard !segments.isEmpty else { return nil }
        return "[\(segments.joined(separator: ", "))]"
    }

    private func categorySummary(forApps apps: [[String: Any]]) -> String? {
        var categories: [String: Int] = [:]
        for app in apps {
            if let category = app["category"] as? String {
                categories[category, default: 0] += 1
            }
        }

        guard !categories.isEmpty else { return nil }
        let top = categories.sorted { $0.value > $1.value }.prefix(3)
        let text = top.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        return "Categories: \(text)"
    }

    private func memorySummary(forApps apps: [[String: Any]]) -> String? {
        let total = apps.compactMap { $0["memoryUsage"] as? Int }.reduce(0, +)
        guard total > 0 else { return nil }
        return "Total memory: \(self.formatMemorySize(total))"
    }

    private func resolveWindowCount(result: [String: Any], windows: [[String: Any]]?) -> Int {
        if let count = ToolResultExtractor.int("count", from: result) {
            return count
        }
        return windows?.count ?? 0
    }

    private func windowCountSummary(count: Int, result: [String: Any]) -> String {
        let suffix = count == 1 ? "" : "s"
        if let app = ToolResultExtractor.string("app", from: result) {
            return "→ \(count) window\(suffix) for \(app)"
        }

        return "→ \(count) window\(suffix)"
    }

    private func windowStateSummary(for windows: [[String: Any]]) -> String? {
        var visible = 0
        var minimized = 0
        var fullscreen = 0

        for window in windows {
            if let isVisible = window["isVisible"] as? Bool, isVisible {
                visible += 1
            }
            if let isMinimized = window["isMinimized"] as? Bool, isMinimized {
                minimized += 1
            }
            if let isFullscreen = window["isFullscreen"] as? Bool, isFullscreen {
                fullscreen += 1
            }
        }

        var segments: [String] = []
        if visible > 0 {
            segments.append("\(visible) visible")
        }
        if minimized > 0 {
            segments.append("\(minimized) minimized")
        }
        if fullscreen > 0 {
            segments.append("\(fullscreen) fullscreen")
        }

        guard !segments.isEmpty else { return nil }
        return "[\(segments.joined(separator: ", "))]"
    }

    private func windowTitleSummary(for windows: [[String: Any]], count: Int) -> String? {
        guard count <= 3 else { return nil }
        let titles = windows.compactMap { window -> String? in
            guard let title = window["title"] as? String, !title.isEmpty else { return nil }
            return title
        }.prefix(3)

        guard !titles.isEmpty else { return nil }
        return titles.map { title -> String in
            let truncated = title.count > 30 ? String(title.prefix(30)) + "..." : title
            return "\"\(truncated)\""
        }.joined(separator: ", ")
    }

    private func formatMemorySize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = bytes < 1024 * 1024 ? .useKB :
            bytes < 1024 * 1024 * 1024 ? .useMB : .useGB
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
