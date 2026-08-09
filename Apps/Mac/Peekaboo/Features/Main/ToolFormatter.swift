import Foundation
import PeekabooCore

/// Formats tool executions to match CLI's compact output format.
/// This compatibility layer delegates to the shared formatter system.
@MainActor
struct ToolFormatter {
    /// Format duration with clock symbol
    /// Uses the shared FormattingUtilities from PeekabooCore
    static func formatDuration(_ duration: TimeInterval?) -> String {
        guard let duration else { return "" }
        return " ⌖ " + FormattingUtilities.formatDetailedDuration(duration)
    }

    /// Get compact summary of what the tool will do based on arguments
    /// Delegates to the shared registry-based system
    static func compactToolSummary(toolName: String, arguments: String) -> String {
        guard let toolType = ToolType(rawValue: toolName) else {
            return self.defaultToolName(toolName)
        }

        let formatter = ToolFormatterRegistry.shared.formatter(for: toolType)
        let summary = formatter.formatCompactSummary(arguments: self.parseJSON(arguments))
        return summary.isEmpty ? toolType.displayName : summary
    }

    /// Get result summary for completed tool execution
    /// Delegates to the shared registry-based system
    static func toolResultSummary(toolName: String, result: String?) -> String? {
        guard let result else { return nil }

        let resultJSON = self.parseJSON(result)
        guard let toolType = ToolType(rawValue: toolName) else {
            if let success = resultJSON["success"] as? Bool {
                return success ? "Completed" : "Failed"
            }
            return nil
        }

        if let summary = ToolEventSummary.from(resultJSON: resultJSON)?.shortDescription(toolName: toolName),
           !summary.isEmpty
        {
            return summary
        }

        let formatter = ToolFormatterRegistry.shared.formatter(for: toolType)
        let summary = formatter.formatResultSummary(result: resultJSON)
        return summary.isEmpty ? nil : summary
    }

    private static func parseJSON(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return dictionary
    }

    private static func defaultToolName(_ toolName: String) -> String {
        toolName.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
