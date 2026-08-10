//
//  SystemToolFormatter.swift
//  PeekabooCore
//

import Foundation
import PeekabooAutomation

/// Formatter for system tools with comprehensive result formatting
public class SystemToolFormatter: BaseToolFormatter {
    override public func formatCompactSummary(arguments: [String: Any]) -> String {
        if let currentToolSummary = self.formatCurrentToolCompactSummary(arguments: arguments) {
            return currentToolSummary
        }

        switch toolType {
        case .shell:
            var parts: [String] = []
            if let command = arguments["command"] as? String {
                let truncated = command.count > 60 ? String(command.prefix(60)) + "..." : command
                parts.append("'\(truncated)'")
            } else {
                parts.append("command")
            }

            // Only show timeout if different from default (30s)
            if let timeout = arguments["timeout"] as? Double, timeout != 30.0 {
                parts.append("(timeout: \(Int(timeout))s)")
            }

            return parts.joined(separator: " ")

        case .wait:
            var parts: [String] = []

            if let seconds = arguments["seconds"] as? Double {
                parts.append("\(seconds)s")
            } else if let seconds = arguments["seconds"] as? Int {
                parts.append("\(seconds)s")
            } else if let time = arguments["time"] as? Double {
                parts.append("\(time)s")
            } else {
                parts.append("1s")
            }

            // Add wait reason if available
            if let reason = arguments["reason"] as? String {
                parts.append("for \(reason)")
            } else if let waitFor = arguments["for"] as? String {
                parts.append("for \(waitFor)")
            }

            return parts.joined(separator: " ")

        case .copyToClipboard:
            if let text = arguments["text"] as? String {
                let preview = text.count > 30 ? String(text.prefix(30)) + "..." : text
                return "\"\(preview)\""
            }
            return "text"

        case .pasteFromClipboard:
            if let app = arguments["app"] as? String {
                return "to \(app)"
            }
            return ""

        default:
            return super.formatCompactSummary(arguments: arguments)
        }
    }

    private func formatCurrentToolCompactSummary(arguments: [String: Any]) -> String? {
        switch self.toolType {
        case .browser:
            let action = arguments["action"] as? String ?? "browser"
            if let url = arguments["url"] as? String {
                return "\(action.replacingOccurrences(of: "_", with: " ")) \(self.truncate(url, maxLength: 50))"
            }
            if action == "call", let tool = arguments["mcp_tool"] as? String {
                return "call \(tool)"
            }
            return action.replacingOccurrences(of: "_", with: " ")
        case .permissions:
            return "macOS automation access"
        case .sleep:
            if let duration = arguments["duration"] as? Double {
                return self.formatMilliseconds(duration)
            }
            if let duration = arguments["duration"] as? Int {
                return self.formatMilliseconds(Double(duration))
            }
            return ""
        case .agent:
            if arguments["listSessions"] as? Bool == true {
                return "list sessions"
            }
            if let task = arguments["task"] as? String {
                return self.truncate(task, maxLength: 60)
            }
            return ""
        default:
            return nil
        }
    }

    private func formatMilliseconds(_ milliseconds: Double) -> String {
        if milliseconds < 1000 {
            return String(format: "%.0fms", milliseconds)
        }
        return String(format: "%.1fs", milliseconds / 1000)
    }

    override public func formatResultSummary(result: [String: Any]) -> String {
        switch toolType {
        case .shell:
            self.formatShellResult(result)
        case .wait:
            self.formatWaitResult(result)
        case .copyToClipboard:
            self.formatCopyResult(result)
        case .pasteFromClipboard:
            self.formatPasteResult(result)
        case .clipboard:
            self.formatClipboardResult(result)
        default:
            super.formatResultSummary(result: result)
        }
    }

    // MARK: - Shell Formatting

    private func formatShellResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        // Exit code and status
        let exitCode = ToolResultExtractor.int("exitCode", from: result) ?? 0
        if exitCode == 0 {
            parts.append("→ Success")
        } else {
            parts.append("→ Failed (exit code: \(exitCode))")
        }

        // Command info
        if let command = ToolResultExtractor.string("command", from: result) {
            let truncated = command.count > 50 ? String(command.prefix(50)) + "..." : command
            parts.append("\"\(truncated)\"")
        }

        // Execution time
        if let duration = ToolResultExtractor.double("duration", from: result) {
            if duration > 1.0 {
                parts.append(String(format: "[%.1fs]", duration))
            } else {
                parts.append(String(format: "[%.0fms]", duration * 1000))
            }
        }

        // Output summary
        if let output = ToolResultExtractor.string("output", from: result), !output.isEmpty {
            let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
            if exitCode == 0, !lines.isEmpty {
                // Show first line for successful commands
                let firstLine = lines.first!
                let truncated = firstLine.count > 60 ? String(firstLine.prefix(60)) + "..." : firstLine
                parts.append("• Output: \(truncated)")

                if lines.count > 1 {
                    parts.append("(\(lines.count) lines)")
                }
            } else if exitCode != 0 {
                // Show error output for failed commands
                let errorPreview = lines.prefix(2).joined(separator: " | ")
                let truncated = errorPreview.count > 80 ? String(errorPreview.prefix(80)) + "..." : errorPreview
                parts.append("• Error: \(truncated)")
            }
        }

        // Working directory
        if let workingDir = ToolResultExtractor.string("workingDirectory", from: result) {
            parts.append("in \(workingDir)")
        }

        // Resource usage
        if let memoryUsed = ToolResultExtractor.int("memoryUsed", from: result) {
            let memoryMB = memoryUsed / 1024 / 1024
            if memoryMB > 100 {
                parts.append("• Memory: \(memoryMB)MB")
            }
        }

        // Environment variables
        if let envVars = ToolResultExtractor.dictionary("environment", from: result), !envVars.isEmpty {
            parts.append("• \(envVars.count) env var\(envVars.count == 1 ? "" : "s") set")
        }

        // Signal information
        if let signal = ToolResultExtractor.string("signal", from: result) {
            parts.append("\(AgentDisplayTokens.Status.warning) Terminated by signal: \(signal)")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Wait Formatting

    private func formatWaitResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        parts.append("→ Waited")

        // Duration
        if let seconds = ToolResultExtractor.double("seconds", from: result) {
            if seconds >= 1.0 {
                parts.append(String(format: "%.1fs", seconds))
            } else {
                parts.append(String(format: "%.0fms", seconds * 1000))
            }
        } else if let seconds = ToolResultExtractor.int("seconds", from: result) {
            parts.append("\(seconds)s")
        }

        // Actual vs requested
        if let actualDuration = ToolResultExtractor.double("actualDuration", from: result),
           let requestedDuration = ToolResultExtractor.double("requestedDuration", from: result)
        {
            let diff = abs(actualDuration - requestedDuration)
            if diff > 0.1 {
                parts.append(String(format: "(requested: %.1fs, actual: %.1fs)", requestedDuration, actualDuration))
            }
        }

        // Reason
        if let reason = ToolResultExtractor.string("reason", from: result) {
            parts.append("for \(reason)")
        }

        // What happened during wait
        if let events = ToolResultExtractor.array("events", from: result) as [[String: Any]]? {
            if !events.isEmpty {
                parts.append("• \(events.count) event\(events.count == 1 ? "" : "s") occurred")
            }
        }

        // Interrupted
        if ToolResultExtractor.bool("interrupted", from: result) == true {
            parts.append("\(AgentDisplayTokens.Status.warning) Interrupted early")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Clipboard Formatting

    private func formatClipboardResult(_ result: [String: Any]) -> String {
        let action = ToolResultExtractor.string("action", from: result)?.lowercased()
        switch action {
        case "set", "write", "load":
            return "→ Copied to clipboard"
        case "clear":
            return "→ Clipboard cleared"
        case "get", "read":
            guard let content = self.clipboardContent(from: result) else { return "" }
            return "→ \"\(self.truncate(content, maxLength: 40))\""
        default:
            break
        }

        guard let response = ToolResultExtractor.string("result", from: result) else { return "" }
        if response.hasPrefix("Set clipboard") {
            return "→ Copied to clipboard"
        }
        if response.hasPrefix("Cleared clipboard") {
            return "→ Clipboard cleared"
        }
        return "→ \"\(self.truncate(response, maxLength: 40))\""
    }

    private func clipboardContent(from result: [String: Any]) -> String? {
        ToolResultExtractor.string("content", from: result) ??
            ToolResultExtractor.string("text", from: result) ??
            ToolResultExtractor.string("textPreview", from: result) ??
            ToolResultExtractor.string("result", from: result)
    }

    private func formatCopyResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        parts.append("→ Copied to clipboard")

        // Text preview
        if let text = ToolResultExtractor.string("text", from: result) {
            let lines = text.components(separatedBy: .newlines)
            let preview = text.count > 50 ? String(text.prefix(50)) + "..." : text
            parts.append("\"\(preview)\"")

            // Size info
            if text.count > 100 {
                parts.append("(\(text.count) characters")
                if lines.count > 1 {
                    parts.append(", \(lines.count) lines")
                }
                parts.append(")")
            }
        }

        // Format
        if let format = ToolResultExtractor.string("format", from: result) {
            parts.append("as \(format)")
        }

        // Previous clipboard
        if let previousContent = ToolResultExtractor.string("previousContent", from: result), !previousContent.isEmpty {
            let preview = previousContent.count > 30 ? String(previousContent.prefix(30)) + "..." : previousContent
            parts.append("• Replaced: \"\(preview)\"")
        }

        return parts.joined(separator: " ")
    }

    private func formatPasteResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        parts.append("→ Pasted")

        // Content preview
        if let content = ToolResultExtractor.string("content", from: result) {
            let preview = content.count > 50 ? String(content.prefix(50)) + "..." : content
            parts.append("\"\(preview)\"")

            // Size
            if content.count > 100 {
                parts.append("(\(content.count) characters)")
            }
        }

        // Target app
        if let app = ToolResultExtractor.string("app", from: result) {
            parts.append("to \(app)")
        }

        // Target field
        if let field = ToolResultExtractor.string("field", from: result) {
            parts.append("in field: \"\(field)\"")
        }

        // Method used
        if let method = ToolResultExtractor.string("method", from: result) {
            switch method {
            case "keyboard":
                parts.append("• Via keyboard simulation")
            case "api":
                parts.append("• Via system API")
            case "menu":
                parts.append("• Via Edit menu")
            default:
                break
            }
        }

        return parts.joined(separator: " ")
    }

    override public func formatStarting(arguments: [String: Any]) -> String {
        switch toolType {
        case .shell:
            if let command = arguments["command"] as? String {
                let truncated = command.count > 60 ? String(command.prefix(60)) + "..." : command
                return "[sh] Executing: \(truncated)..."
            }
            return "[sh] Executing command..."

        case .wait:
            let summary = self.formatCompactSummary(arguments: arguments)
            return "\(AgentDisplayTokens.Status.time) Waiting \(summary)..."

        case .copyToClipboard:
            if let text = arguments["text"] as? String {
                let preview = text.count > 40 ? String(text.prefix(40)) + "..." : text
                return "[menu] Copying \"\(preview)\" to clipboard..."
            }
            return "[menu] Copying to clipboard..."

        case .pasteFromClipboard:
            if let app = arguments["app"] as? String {
                return "[menu] Pasting to \(app)..."
            }
            return "[menu] Pasting from clipboard..."

        case .clipboard:
            if let action = arguments["action"] as? String {
                return "[clip] \(action.capitalized) clipboard..."
            }
            return "[clip] Working with clipboard..."

        default:
            return super.formatStarting(arguments: arguments)
        }
    }

    override public func formatError(error: String, result: [String: Any]) -> String {
        switch toolType {
        case .shell:
            // Enhanced shell error formatting
            var parts: [String] = []

            let exitCode = ToolResultExtractor.int("exitCode", from: result) ?? -1
            parts.append("\(AgentDisplayTokens.Status.failure) Command failed (exit code: \(exitCode))")

            // Command that failed
            if let command = ToolResultExtractor.string("command", from: result) {
                let truncated = command.count > 60 ? String(command.prefix(60)) + "..." : command
                parts.append("   Command: \(truncated)")
            }

            // Error output
            if let stderr = ToolResultExtractor.string("stderr", from: result), !stderr.isEmpty {
                let lines = stderr.components(separatedBy: .newlines).filter { !$0.isEmpty }
                let preview = lines.prefix(3).joined(separator: "\n   ")
                parts.append("   Error output:\n   \(preview)")
            } else if let output = ToolResultExtractor.string("output", from: result), !output.isEmpty {
                let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                let preview = lines.prefix(3).joined(separator: "\n   ")
                parts.append("   Output:\n   \(preview)")
            }

            // Common error hints
            if exitCode == 127 {
                parts.append("   💡 Command not found - check if the program is installed")
            } else if exitCode == 126 {
                parts.append("   💡 Permission denied - check file permissions")
            } else if exitCode == 1, error.lowercased().contains("permission") {
                parts.append("   💡 May need elevated privileges (sudo)")
            }

            return parts.joined(separator: "\n")

        case .wait:
            if error.lowercased().contains("interrupt") {
                return "\(AgentDisplayTokens.Status.warning) Wait interrupted: \(error)"
            }
            return "\(AgentDisplayTokens.Status.failure) Wait failed: \(error)"

        case .copyToClipboard:
            return "\(AgentDisplayTokens.Status.failure) Failed to copy to clipboard: \(error)"

        case .pasteFromClipboard:
            if error.lowercased().contains("empty") {
                return "\(AgentDisplayTokens.Status.failure) Clipboard is empty"
            }
            return "\(AgentDisplayTokens.Status.failure) Failed to paste: \(error)"

        case .clipboard:
            return "\(AgentDisplayTokens.Status.failure) Clipboard error: \(error)"

        default:
            return super.formatError(error: error, result: result)
        }
    }

    override public func formatCompleted(result: [String: Any], duration: TimeInterval) -> String {
        // Override for shell to show more detail on long-running commands
        if toolType == .shell {
            let exitCode = ToolResultExtractor.int("exitCode", from: result) ?? 0
            if duration > 5.0 {
                let durationText = formatDuration(duration)
                if exitCode == 0 {
                    return "\(AgentDisplayTokens.Status.success) Command completed successfully after \(durationText)"
                }
                return "\(AgentDisplayTokens.Status.failure) Command failed after \(durationText)"
            }
        }

        return super.formatCompleted(result: result, duration: duration)
    }
}
