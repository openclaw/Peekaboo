//
//  ToolFormatter.swift
//  PeekabooCore
//

import Foundation

/// Protocol for formatting tool execution information
public protocol ToolFormatter {
    /// The tool type this formatter handles
    var toolType: ToolType { get }

    /// The display name for this tool
    var displayName: String { get }

    /// Format the tool execution start message
    func formatStarting(arguments: [String: Any]) -> String

    /// Format the tool completion message
    func formatCompleted(result: [String: Any], duration: TimeInterval) -> String

    /// Format an error message
    func formatError(error: String, result: [String: Any]) -> String

    /// Format a compact summary for the tool arguments (used in concise mode)
    func formatCompactSummary(arguments: [String: Any]) -> String

    /// Format the result summary (shown after the checkmark)
    func formatResultSummary(result: [String: Any]) -> String

    /// Format for terminal title
    func formatForTitle(arguments: [String: Any]) -> String
}

/// Base implementation of ToolFormatter with common functionality
open class BaseToolFormatter: ToolFormatter {
    /// The tool type this formatter handles.
    public let toolType: ToolType

    public init(toolType: ToolType) {
        self.toolType = toolType
    }

    /// The icon for this tool
    public var icon: String {
        self.toolType.icon
    }

    /// The display name for this tool
    public var displayName: String {
        self.toolType.displayName
    }

    // MARK: - Default Implementations

    open func formatStarting(arguments: [String: Any]) -> String {
        let summary = self.formatCompactSummary(arguments: arguments)
        if !summary.isEmpty {
            return "\(self.displayName): \(summary)"
        }
        return self.displayName
    }

    open func formatCompleted(result: [String: Any], duration: TimeInterval) -> String {
        let summary = self.formatResultSummary(result: result)
        if !summary.isEmpty {
            return summary
        }
        return "→ completed"
    }

    open func formatError(error: String, result: [String: Any]) -> String {
        "✗ \(error)"
    }

    open func formatCompactSummary(arguments: [String: Any]) -> String {
        ""
    }

    open func formatResultSummary(result: [String: Any]) -> String {
        // Default: check for common patterns
        if let count = ToolResultExtractor.int("count", from: result) {
            return "→ \(count) item\(count == 1 ? "" : "s")"
        }
        return ""
    }

    open func formatForTitle(arguments: [String: Any]) -> String {
        self.formatCompactSummary(arguments: arguments)
    }

    // MARK: - Helper Methods

    /// Truncate text if too long
    func truncate(_ text: String, maxLength: Int = 30) -> String {
        if text.count > maxLength {
            return String(text.prefix(maxLength)) + "..."
        }
        return text
    }
}
