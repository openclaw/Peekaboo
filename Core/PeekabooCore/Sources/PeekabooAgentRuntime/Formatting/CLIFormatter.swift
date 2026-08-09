import Algorithms
import Foundation
import PeekabooAutomation

/// Formatter for presenting UnifiedToolOutput in CLI contexts
public enum CLIFormatter {
    /// Format any UnifiedToolOutput for CLI display
    public static func format(_ output: UnifiedToolOutput<some Any>) -> String {
        // Format any UnifiedToolOutput for CLI display
        var result = output.summary.brief

        // Add counts if any
        if !output.summary.counts.isEmpty {
            let countsStr = output.summary.counts
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            result += " (\(countsStr))"
        }

        // Add highlights
        for highlight in output.summary.highlights {
            result += "\n"
            switch highlight.kind {
            case .primary:
                result += "→ \(highlight.label): \(highlight.value)"
            case .warning:
                result += "\(AgentDisplayTokens.Status.warning)  \(highlight.label): \(highlight.value)"
            case .info:
                result += "ℹ️  \(highlight.label): \(highlight.value)"
            }
        }

        // Add type-specific formatting
        result += self.formatSpecificData(output.data)

        // Add warnings if any
        if !output.metadata.warnings.isEmpty {
            result += "\n\nWarnings:"
            for warning in output.metadata.warnings {
                result += "\n\(AgentDisplayTokens.Status.warning)  \(warning)"
            }
        }

        // Add hints if any
        if !output.metadata.hints.isEmpty {
            result += "\n\nHints:"
            for hint in output.metadata.hints {
                result += "\n💡 \(hint)"
            }
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "\(AgentDisplayTokens.Status.info)  No output available."
        }
        return result
    }

    /// Format specific data types
    private static func formatSpecificData(_ data: Any) -> String {
        // Format specific data types
        var result = ""

        switch data {
        case let appData as ServiceApplicationListData:
            result += self.formatApplicationList(appData)

        case let windowData as ServiceWindowListData:
            result += self.formatWindowList(windowData)

        default:
            // No specific formatting for unknown types
            break
        }

        return result
    }

    private static func formatApplicationList(_ data: ServiceApplicationListData) -> String {
        guard !data.applications.isEmpty else { return "" }

        var result = "\n\nApplications:"
        for (index, app) in data.applications.indexed() {
            result += "\n\(index + 1). \(app.name)"
            if let bundleId = app.bundleIdentifier {
                result += " (\(bundleId))"
            }
            result += " - PID: \(app.processIdentifier)"
            if app.isActive {
                result += " [ACTIVE]"
            }
            if app.isHidden {
                result += " [HIDDEN]"
            }
            result += " - Windows: \(app.windowCount)"
        }
        return result
    }

    private static func formatWindowList(_ data: ServiceWindowListData) -> String {
        guard !data.windows.isEmpty else {
            let appName = data.targetApplication?.name ?? "the requested application"
            return "\n\n\(AgentDisplayTokens.Status.warning)  No windows found for \(appName)"
        }

        var result = "\n\nWindows:"
        for (index, window) in data.windows.indexed() {
            result += "\n\(index + 1). \(window.title.isEmpty ? "[Untitled]" : window.title)"
            result += " - ID: \(window.windowID)"

            // Format bounds
            let bounds = window.bounds
            result += "\n   Position: (\(Int(bounds.origin.x)), \(Int(bounds.origin.y)))"
            result += " Size: \(Int(bounds.size.width))×\(Int(bounds.size.height))"

            // Show screen information
            if let screenName = window.screenName {
                result += "\n   Screen: \(screenName)"
            } else if let screenIndex = window.screenIndex {
                result += "\n   Screen: Display \(screenIndex + 1)"
            }

            if window.isMinimized {
                result += " [MINIMIZED]"
            }
            if window.isOffScreen {
                result += " [OFF-SCREEN]"
            }
        }
        return result
    }
}
