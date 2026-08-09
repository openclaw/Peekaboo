//
//  ToolFormatterBridge.swift
//  Peekaboo
//

import Foundation
import PeekabooCore

/// Bridge to connect the CLI formatter system to the Mac app
@MainActor
class ToolFormatterBridge {
    static let shared = ToolFormatterBridge()

    private init() {}

    /// Format tool call for display in the Mac app
    func formatToolCall(name: String, arguments: String) -> String {
        // Parse tool type
        guard let toolType = ToolType(rawValue: name) else {
            return self.formatUnknownTool(name: name)
        }

        // Get formatter from registry
        let formatter = ToolFormatterRegistry.shared.formatter(for: toolType)

        // Parse arguments
        let args = self.parseArguments(arguments)

        let summary = formatter.formatCompactSummary(arguments: args)
        if !summary.isEmpty {
            return "\(AgentDisplayTokens.Status.running) \(toolType.displayName): \(summary)"
        } else {
            return "\(AgentDisplayTokens.Status.running) \(toolType.displayName)"
        }
    }

    /// Format tool arguments for detailed view
    func formatArguments(name: String, arguments: String) -> String {
        guard let toolType = ToolType(rawValue: name) else {
            return arguments
        }

        let formatter = ToolFormatterRegistry.shared.formatter(for: toolType)
        let args = self.parseArguments(arguments)

        let summary = formatter.formatCompactSummary(arguments: args)
        if !summary.isEmpty {
            return summary
        }

        // Fall back to formatted JSON
        return self.formatJSON(arguments)
    }

    /// Get icon for tool
    func toolIcon(for name: String) -> String {
        AgentDisplayTokens.icon(for: name)
    }

    /// Get display name for tool
    func toolDisplayName(for name: String) -> String {
        if let toolType = ToolType(rawValue: name) {
            return toolType.displayName
        }

        // Format unknown tool name
        return name.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map(\.capitalized)
            .joined(separator: " ")
    }

    // MARK: - Private Helpers

    private func parseArguments(_ arguments: String) -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return args
    }

    private func formatJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: object, options: .prettyPrinted),
              let result = String(data: formatted, encoding: .utf8)
        else {
            return json
        }
        return result
    }

    private func formatUnknownTool(name: String) -> String {
        let displayName = self.toolDisplayName(for: name)
        return "\(AgentDisplayTokens.Status.running) \(displayName)"
    }
}
