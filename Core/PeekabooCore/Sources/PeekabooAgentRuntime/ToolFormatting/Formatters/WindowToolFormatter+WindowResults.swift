import Foundation
import PeekabooAutomation

extension WindowToolFormatter {
    // MARK: - Window Management

    func formatFocusWindowResult(_ result: [String: Any]) -> String {
        var parts = ["→ Focused"]

        if let title = self.truncatedTitle(from: result, limit: 40) {
            parts.append("\"\(title)\"")
        }

        if let app = self.windowAppName(from: result) {
            parts.append("(\(app))")
        }

        if let detailSummary = self.focusDetailSummary(result) {
            parts.append(detailSummary)
        }

        parts.append(contentsOf: self.focusStateChanges(result))

        return parts.joined(separator: " ")
    }

    func formatResizeWindowResult(_ result: [String: Any]) -> String {
        var parts = ["→ Resized"]

        if let description = self.resizeWindowDescription(result) {
            parts.append(contentsOf: description)
        }

        if let sizeSummary = self.resizeSizeSummary(result) {
            parts.append(sizeSummary)
        }

        if let positionSummary = self.resizePositionSummary(result) {
            parts.append(positionSummary)
        }

        if self.isConstrained(result) {
            parts.append("\(AgentDisplayTokens.Status.warning) Constrained to screen bounds")
        }

        return parts.joined(separator: " ")
    }

    func formatListWindowsResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        if let windows: [[String: Any]] = ToolResultExtractor.array("windows", from: result) {
            self.appendWindowCountDescription(for: windows, into: &parts)
            self.appendWindowAppBreakdown(from: windows, into: &parts)
            self.appendWindowStateSummary(for: windows, into: &parts)
            self.appendWindowTitlePreview(for: windows, into: &parts)
        } else {
            self.appendLegacyWindowCount(from: result, into: &parts)
        }

        self.appendWindowFilterInfo(from: result, into: &parts)
        return parts.isEmpty ? "→ listed" : parts.joined(separator: " ")
    }

    func formatMinimizeWindowResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        parts.append("→ Minimized")

        // Window info
        if let app = ToolResultExtractor.string("app", from: result) {
            parts.append(app)
        }

        if let title = ToolResultExtractor.string("windowTitle", from: result) {
            let truncated = title.count > 40
                ? String(title.prefix(40)) + "..."
                : title
            parts.append("\"\(truncated)\"")
        }

        // Animation info
        if let animated = ToolResultExtractor.bool("animated", from: result), animated {
            parts.append("with animation")
        }

        // Dock position
        if let dockPosition = ToolResultExtractor.string("dockPosition", from: result) {
            parts.append("to \(dockPosition) of Dock")
        }

        return parts.joined(separator: " ")
    }

    func formatMaximizeWindowResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        parts.append("→ Maximized")

        // Window info
        if let app = ToolResultExtractor.string("app", from: result) {
            parts.append(app)
        }

        if let title = ToolResultExtractor.string("windowTitle", from: result) {
            let truncated = title.count > 40
                ? String(title.prefix(40)) + "..."
                : title
            parts.append("\"\(truncated)\"")
        }

        // Size info
        if let newBounds = ToolResultExtractor.dictionary("bounds", from: result) {
            if let width = newBounds["width"] as? Int,
               let height = newBounds["height"] as? Int
            {
                parts.append("to \(width)×\(height)")
            }
        }

        // Fullscreen state
        if let fullscreen = ToolResultExtractor.bool("fullscreen", from: result), fullscreen {
            parts.append("• Entered fullscreen")
        }

        // Screen info
        if let screen = ToolResultExtractor.string("screen", from: result) {
            parts.append("on \(screen)")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Screen Management

    func formatListScreensResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        // Screen count
        if let screens: [[String: Any]] = ToolResultExtractor.array("screens", from: result) {
            let count = screens.count
            parts.append("→ \(count) screen\(count == 1 ? "" : "s")")

            // Main screen
            if let mainScreen = screens.first(where: {
                ($0["isMain"] as? Bool) == true || ($0["isPrimary"] as? Bool) == true
            }) {
                if let name = mainScreen["name"] as? String {
                    parts.append("Main: \(name)")
                }

                if let resolution = self.screenResolution(mainScreen) {
                    parts.append("(\(resolution))")
                }
            } else if screens.count == 1, let screen = screens.first,
                      let resolution = self.screenResolution(screen)
            {
                parts.append("(\(resolution))")
            }

            // External screens
            let externalCount = screens.count(where: { ($0["isBuiltin"] as? Bool) == false })
            if externalCount > 0 {
                parts.append("• \(externalCount) external")
            }

            // Total resolution
            let resolutions = screens.compactMap(self.screenDimensions)
            if screens.count > 1, resolutions.count == screens.count {
                let totalWidth = resolutions.map(\.width).reduce(0, +)
                let totalHeight = resolutions.map(\.height).max() ?? 0
                if totalWidth > 0, totalHeight > 0 {
                    parts.append("• Total: \(totalWidth)×\(totalHeight)")
                }
            }
        } else if let count = ToolResultExtractor.int("count", from: result) {
            parts.append("→ \(count) screen\(count == 1 ? "" : "s")")
        }

        return parts.isEmpty ? "→ listed" : parts.joined(separator: " ")
    }

    private func screenResolution(_ screen: [String: Any]) -> String? {
        if let dimensions = self.screenDimensions(screen) {
            return "\(dimensions.width)×\(dimensions.height)"
        }
        guard let resolution = screen["resolution"] as? String else { return nil }
        let normalized = resolution.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "x", with: "×")
            .replacingOccurrences(of: "X", with: "×")
        return normalized.isEmpty ? nil : normalized
    }

    private func screenDimensions(_ screen: [String: Any]) -> (width: Int, height: Int)? {
        if let width = ToolResultExtractor.int("width", from: screen),
           let height = ToolResultExtractor.int("height", from: screen)
        {
            return (width, height)
        }
        guard let resolution = ToolResultExtractor.dictionary("resolution", from: screen),
              let width = ToolResultExtractor.int("width", from: resolution),
              let height = ToolResultExtractor.int("height", from: resolution)
        else {
            return nil
        }
        return (width, height)
    }

    private func appendWindowCountDescription(
        for windows: [[String: Any]],
        into parts: inout [String])
    {
        let count = windows.count
        parts.append("→ \(count) window\(count == 1 ? "" : "s")")
    }

    private func appendWindowAppBreakdown(
        from windows: [[String: Any]],
        into parts: inout [String])
    {
        let appGroups = Dictionary(grouping: windows) { window in
            (window["app"] as? String) ?? "Unknown"
        }

        guard !appGroups.isEmpty else { return }

        if appGroups.count > 1 {
            let appSummary = appGroups
                .map { app, wins in "\(app): \(wins.count)" }
                .sorted()
                .prefix(3)
                .joined(separator: ", ")
            parts.append("[\(appSummary)]")
        } else if let app = appGroups.keys.first,
                  !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  app.caseInsensitiveCompare("Unknown") != .orderedSame
        {
            parts.append("for \(app)")
        }
    }

    private func appendWindowStateSummary(
        for windows: [[String: Any]],
        into parts: inout [String])
    {
        let minimized = windows.count(where: { ($0["isMinimized"] as? Bool) == true })
        let hidden = windows.count(where: { ($0["isHidden"] as? Bool) == true })
        let fullscreen = windows.count(where: { ($0["isFullscreen"] as? Bool) == true })

        var states: [String] = []
        if minimized > 0 {
            states.append("\(minimized) minimized")
        }
        if hidden > 0 {
            states.append("\(hidden) hidden")
        }
        if fullscreen > 0 {
            states.append("\(fullscreen) fullscreen")
        }

        guard !states.isEmpty else { return }
        let summary = states.joined(separator: ", ")
        parts.append("(\(summary))")
    }

    private func appendWindowTitlePreview(
        for windows: [[String: Any]],
        into parts: inout [String])
    {
        guard windows.count <= 3 else { return }

        let titles = windows.compactMap { $0["title"] as? String }.prefix(3)
        guard !titles.isEmpty else { return }

        let titleList = titles.map { title -> String in
            let truncated = title.count > 25 ? String(title.prefix(25)) + "..." : title
            return "\"\(truncated)\""
        }.joined(separator: ", ")
        parts.append("• \(titleList)")
    }

    private func appendLegacyWindowCount(
        from result: [String: Any],
        into parts: inout [String])
    {
        if let count = ToolResultExtractor.int("count", from: result) {
            parts.append("→ \(count) window\(count == 1 ? "" : "s")")
            return
        }

        if let data = result["data"] as? [String: Any],
           let windows = data["windows"] as? [[String: Any]]
        {
            let count = windows.count
            parts.append("→ \(count) window\(count == 1 ? "" : "s")")
        }
    }

    private func appendWindowFilterInfo(
        from result: [String: Any],
        into parts: inout [String])
    {
        if let app = ToolResultExtractor.string("app", from: result) ??
            ToolResultExtractor.string("appName", from: result),
            !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            app.caseInsensitiveCompare("Unknown") != .orderedSame
        {
            if !parts.joined(separator: " ").contains(app) {
                parts.append("for \(app)")
            }
        }

        if let screen = ToolResultExtractor.string("screen", from: result) {
            parts.append("on \(screen)")
        }
    }

    // MARK: - Focus Helpers

    private func truncatedTitle(from result: [String: Any], limit: Int) -> String? {
        guard let title = ToolResultExtractor.string("windowTitle", from: result) else { return nil }
        if title.count > limit {
            return String(title.prefix(limit)) + "..."
        }
        return title
    }

    private func windowAppName(from result: [String: Any]) -> String? {
        ToolResultExtractor.string("app", from: result) ??
            ToolResultExtractor.string("appName", from: result)
    }

    private func focusDetailSummary(_ result: [String: Any]) -> String? {
        var details: [String] = []
        if let windowId = ToolResultExtractor.int("windowId", from: result) {
            details.append("ID: \(windowId)")
        }
        if let bounds = ToolResultExtractor.dictionary("bounds", from: result),
           let width = bounds["width"] as? Int,
           let height = bounds["height"] as? Int
        {
            details.append("\(width)×\(height)")
        }
        if let space = ToolResultExtractor.int("space", from: result) {
            details.append("space \(space)")
        }
        if let screen = ToolResultExtractor.string("screen", from: result) {
            details.append("on \(screen)")
        }
        guard !details.isEmpty else { return nil }
        return "[\(details.joined(separator: ", "))]"
    }

    private func focusStateChanges(_ result: [String: Any]) -> [String] {
        var states: [String] = []
        if ToolResultExtractor.bool("wasMinimized", from: result) == true {
            states.append("• Restored from minimized")
        }
        if ToolResultExtractor.bool("wasHidden", from: result) == true {
            states.append("• Unhidden")
        }
        return states
    }

    // MARK: - Resize Helpers

    private func resizeWindowDescription(_ result: [String: Any]) -> [String]? {
        guard let app = ToolResultExtractor.string("app", from: result) else { return nil }
        var description = [app]
        if let title = ToolResultExtractor.string("windowTitle", from: result) {
            description.append("\"\(self.truncated(title: title, limit: 30))\"")
        }
        return description
    }

    private func truncated(title: String, limit: Int) -> String {
        if title.count > limit {
            return String(title.prefix(limit)) + "..."
        }
        return title
    }

    private func resizeSizeSummary(_ result: [String: Any]) -> String? {
        if let newBounds = ToolResultExtractor.dictionary("newBounds", from: result),
           let oldBounds = ToolResultExtractor.dictionary("oldBounds", from: result),
           let newWidth = newBounds["width"] as? Int,
           let newHeight = newBounds["height"] as? Int,
           let oldWidth = oldBounds["width"] as? Int,
           let oldHeight = oldBounds["height"] as? Int
        {
            var summary = "from \(oldWidth)×\(oldHeight) to \(newWidth)×\(newHeight)"
            let widthChange = self.percentageChange(newValue: newWidth, oldValue: oldWidth)
            let heightChange = self.percentageChange(newValue: newHeight, oldValue: oldHeight)
            if abs(widthChange) > 5 || abs(heightChange) > 5 {
                summary += String(format: " [%+.0f%% width, %+.0f%% height]", widthChange, heightChange)
            }
            return summary
        }

        if let width = ToolResultExtractor.int("width", from: result),
           let height = ToolResultExtractor.int("height", from: result)
        {
            return "to \(width)×\(height)"
        }
        return nil
    }

    private func resizePositionSummary(_ result: [String: Any]) -> String? {
        guard let newX = ToolResultExtractor.int("x", from: result),
              let newY = ToolResultExtractor.int("y", from: result)
        else { return nil }
        return "at (\(newX), \(newY))"
    }

    private func percentageChange(newValue: Int, oldValue: Int) -> Double {
        guard oldValue != 0 else { return 0 }
        return ((Double(newValue) - Double(oldValue)) / Double(oldValue)) * 100
    }

    private func isConstrained(_ result: [String: Any]) -> Bool {
        ToolResultExtractor.bool("constrained", from: result) ?? false
    }
}
