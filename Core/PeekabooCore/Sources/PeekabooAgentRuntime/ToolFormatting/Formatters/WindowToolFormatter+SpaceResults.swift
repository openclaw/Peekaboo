import Foundation
import PeekabooAutomation

extension WindowToolFormatter {
    // MARK: - Space Management

    func formatListSpacesResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        // Space count
        if let spaces: [[String: Any]] = ToolResultExtractor.array("spaces", from: result) {
            let count = spaces.count
            parts.append("→ \(count) space\(count == 1 ? "" : "s")")

            let spacesWithWindows = spaces.count(where: { ($0["hasWindows"] as? Bool) == true })
            if spacesWithWindows > 0 {
                parts.append("(\(spacesWithWindows) with windows)")
            }

            // Current space
            if let currentSpace = spaces.first(where: { ($0["isCurrent"] as? Bool) == true }) {
                if let index = currentSpace["index"] as? Int {
                    parts.append("Current: Space \(index)")
                }

                if let windowCount = currentSpace["windowCount"] as? Int {
                    parts.append("(\(windowCount) windows)")
                }
            }

            // Space types
            let fullscreenSpaces = spaces.count(where: { ($0["isFullscreen"] as? Bool) == true })
            let visibleSpaces = spaces.count(where: { ($0["isVisible"] as? Bool) == true })

            var details: [String] = []
            if fullscreenSpaces > 0 {
                details.append("\(fullscreenSpaces) fullscreen")
            }
            if visibleSpaces > 1 {
                details.append("\(visibleSpaces) visible")
            }

            if !details.isEmpty {
                parts.append("[\(details.joined(separator: ", "))]")
            }
        } else if let count = ToolResultExtractor.int("count", from: result) {
            parts.append("→ \(count) space\(count == 1 ? "" : "s")")
        }

        // Current space info
        if let current = ToolResultExtractor.int("currentSpace", from: result) {
            parts.append("• Currently on Space \(current)")
        }

        return parts.isEmpty ? "→ listed" : parts.joined(separator: " ")
    }

    func formatSwitchSpaceResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        parts.append("→ Switched to")

        // Space info
        if let spaceIndex = ToolResultExtractor.int("spaceIndex", from: result) {
            parts.append("Space \(spaceIndex)")
        } else if let spaceName = ToolResultExtractor.string("spaceName", from: result) {
            parts.append(spaceName)
        }

        // Previous space
        if let previousSpace = ToolResultExtractor.int("previousSpace", from: result) {
            parts.append("(from Space \(previousSpace))")
        }

        // Animation
        if let animated = ToolResultExtractor.bool("animated", from: result), animated {
            parts.append("with animation")
        }

        // Windows on new space
        if let windowCount = ToolResultExtractor.int("windowCount", from: result) {
            parts.append("• \(windowCount) window\(windowCount == 1 ? "" : "s") here")
        }

        // Apps on new space
        if let apps: [String] = ToolResultExtractor.array("apps", from: result) {
            if !apps.isEmpty {
                let appList = apps.prefix(3).joined(separator: ", ")
                parts.append("• Apps: \(appList)")
            }
        }

        return parts.isEmpty ? "→ switched" : parts.joined(separator: " ")
    }

    func formatMoveWindowToSpaceResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        parts.append("→ Moved")

        // Window info
        if let app = ToolResultExtractor.string("app", from: result) {
            parts.append(app)

            if let title = ToolResultExtractor.string("windowTitle", from: result) {
                let truncated = title.count > 30
                    ? String(title.prefix(30)) + "..."
                    : title
                parts.append("\"\(truncated)\"")
            }
        }

        // Space transition
        if let toSpace = ToolResultExtractor.int("toSpace", from: result) {
            parts.append("to Space \(toSpace)")

            if let fromSpace = ToolResultExtractor.int("fromSpace", from: result) {
                parts.append("(from Space \(fromSpace))")
            }
        }

        // Follow window
        if let followed = ToolResultExtractor.bool("followedWindow", from: result), followed {
            parts.append("• Switched to new space")
        }

        // Other windows
        if let remainingWindows = ToolResultExtractor.int("remainingWindows", from: result) {
            parts.append("• \(remainingWindows) windows remain on original space")
        }

        return parts.isEmpty ? "→ moved" : parts.joined(separator: " ")
    }
}
