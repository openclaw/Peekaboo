//
//  VisionToolFormatter.swift
//  PeekabooCore
//

import Foundation
import PeekabooAutomation

/// Formatter for vision tools with comprehensive result formatting
public class VisionToolFormatter: BaseToolFormatter {
    override public func formatResultSummary(result: [String: Any]) -> String {
        switch toolType {
        case .see:
            self.formatSeeResult(result)
        case .screenshot:
            self.formatScreenshotResult(result)
        case .windowCapture:
            self.formatWindowCaptureResult(result)
        case .analyze:
            self.formatAnalyzeResult(result)
        default:
            super.formatResultSummary(result: result)
        }
    }

    override public func formatCompactSummary(arguments: [String: Any]) -> String {
        switch self.toolType {
        case .see, .image, .screenshot, .windowCapture:
            var parts: [String] = []

            if let target = self.describeCaptureTarget(arguments["app_target"] as? String) {
                parts.append(target)
            }

            if let annotate = arguments["annotate"] as? Bool, annotate {
                parts.append("annotated")
            }

            if let question = arguments["question"] as? String, !question.isEmpty {
                parts.append("Q: \(self.truncate(question, maxLength: 40))")
            }

            if parts.isEmpty,
               let path = arguments["path"] as? String
            {
                let filename = URL(fileURLWithPath: path).lastPathComponent
                parts.append(filename)
            }

            return parts.joined(separator: " · ")

        case .capture:
            let source = arguments["source"] as? String ?? "live"
            if source == "video" {
                if let input = arguments["input"] as? String {
                    return "video \(URL(fileURLWithPath: input).lastPathComponent)"
                }
                return "video"
            }

            var parts = [arguments["mode"] as? String ?? "frontmost"]
            if let app = arguments["app"] as? String {
                parts.append(app)
            }
            if let title = arguments["window_title"] as? String {
                parts.append("\"\(self.truncate(title, maxLength: 30))\"")
            }
            return parts.joined(separator: " · ")

        default:
            return super.formatCompactSummary(arguments: arguments)
        }
    }

    private func formatSeeResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        // Context (what was captured)
        let context = self.extractCaptureContext(from: result)
        parts.append("→ \(context)")

        // Element analysis
        if let elementSummary = extractElementSummary(from: result) {
            parts.append(elementSummary)
        }

        // Key findings
        if let findings = extractKeyFindings(from: result) {
            parts.append(findings)
        }

        // Performance metrics
        if let metrics = extractPerformanceMetrics(from: result) {
            parts.append(metrics)
        }

        return parts.joined(separator: " • ")
    }

    private func formatScreenshotResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        // File info
        if let path = ToolResultExtractor.string("path", from: result) {
            let filename = URL(fileURLWithPath: path).lastPathComponent
            parts.append("→ \(filename)")
        } else {
            parts.append("→ Screenshot saved")
        }

        // Image details
        var details: [String] = []

        // Dimensions
        let size = ToolResultExtractor.dictionary("size", from: result)
        if let width = ToolResultExtractor.int("width", from: result),
           let height = ToolResultExtractor.int("height", from: result)
        {
            details.append("\(width)×\(height)px")
        } else if let size,
                  let width = ToolResultExtractor.int("width", from: size),
                  let height = ToolResultExtractor.int("height", from: size)
        {
            details.append("\(width)×\(height)px")
        }

        // File size
        if let size = ToolResultExtractor.int("fileSize", from: result) {
            details.append(self.formatFileSize(size))
        } else if size == nil, let sizeStr = ToolResultExtractor.string("size", from: result) {
            details.append(sizeStr)
        }

        // Format
        if let format = ToolResultExtractor.string("format", from: result) {
            details.append(format.uppercased())
        }

        // Color space
        if let colorSpace = ToolResultExtractor.string("colorSpace", from: result) {
            details.append(colorSpace)
        }

        if !details.isEmpty {
            parts.append("(\(details.joined(separator: ", ")))")
        }

        // Processing time
        if let duration = ToolResultExtractor.double("processingTime", from: result) {
            parts.append(String(format: "%.1fms", duration * 1000))
        }

        return parts.joined(separator: " ")
    }

    private func formatAnalyzeResult(_ result: [String: Any]) -> String {
        guard let analysis = ToolResultExtractor.string("analysis", from: result) ??
            ToolResultExtractor.string("text", from: result) ??
            ToolResultExtractor.string("result", from: result)
        else {
            return ""
        }
        return "→ \"\(self.truncate(analysis, maxLength: 60))\""
    }

    private func formatWindowCaptureResult(_ result: [String: Any]) -> String {
        var parts: [String] = []

        // App and window info
        if let app = ToolResultExtractor.string("app", from: result) {
            parts.append("→ \(app)")

            if let windowTitle = ToolResultExtractor.string("windowTitle", from: result),
               !windowTitle.isEmpty
            {
                let truncated = windowTitle.count > 40
                    ? String(windowTitle.prefix(40)) + "..."
                    : windowTitle
                parts.append("\"\(truncated)\"")
            }
        } else {
            parts.append("→ Window captured")
        }

        // Window details
        var details: [String] = []

        // Window ID
        if let windowId = ToolResultExtractor.int("windowId", from: result) {
            details.append("ID: \(windowId)")
        }

        // Window bounds
        if let bounds = ToolResultExtractor.dictionary("bounds", from: result) {
            if let width = bounds["width"] as? Int,
               let height = bounds["height"] as? Int
            {
                details.append("\(width)×\(height)")
            }
            if let x = bounds["x"] as? Int,
               let y = bounds["y"] as? Int
            {
                details.append("at (\(x), \(y))")
            }
        }

        // Window state
        if let isMinimized = ToolResultExtractor.bool("isMinimized", from: result), isMinimized {
            details.append("minimized")
        }
        if let isFullscreen = ToolResultExtractor.bool("isFullscreen", from: result), isFullscreen {
            details.append("fullscreen")
        }

        if !details.isEmpty {
            parts.append("[\(details.joined(separator: ", "))]")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Helper Methods

    private func describeCaptureTarget(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "Screen"
        }

        let lower = raw.lowercased()
        if lower.hasPrefix("screen:") {
            let index = raw.dropFirst("screen:".count)
            return "Screen \(index)"
        }

        switch lower {
        case "screen":
            return "Screen"
        case "frontmost":
            return "Frontmost window"
        case "menubar":
            return "Menu bar"
        default:
            break
        }

        if lower.hasPrefix("pid:") {
            let pid = raw.dropFirst(4)
            return "PID \(pid)"
        }

        let parts = raw.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
            return "\(parts[0]) window \(parts[1])"
        }

        return raw
    }

    private func extractCaptureContext(from result: [String: Any]) -> String {
        if let description = ToolResultExtractor.string("description", from: result) {
            return self.truncate(description, maxLength: 60)
        } else if let app = ToolResultExtractor.string("app", from: result), app != "entire screen" {
            return app
        } else if let mode = ToolResultExtractor.string("mode", from: result) {
            if mode == "window" {
                if let windowTitle = ToolResultExtractor.string("windowTitle", from: result) {
                    return "Window: \(windowTitle)"
                }
                return "Active window"
            }
            return mode.capitalized
        }
        return "Screen"
    }

    private func extractElementSummary(from result: [String: Any]) -> String? {
        var counts: [(String, Int)] = []

        // Direct element count
        if let total = ToolResultExtractor.int("elementCount", from: result) {
            counts.append(("total", total))
        }

        // Element breakdown
        if let elements: [[String: Any]] = ToolResultExtractor.array("elements", from: result) {
            let typeCount = Dictionary(grouping: elements) { element in
                guard let type = (element["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !type.isEmpty,
                      type.lowercased() != "unknown"
                else {
                    return "element"
                }
                return type
            }.mapValues { $0.count }

            // Sort by count and take top 3
            let topTypes = typeCount.sorted { $0.value > $1.value }.prefix(3)
            for (type, count) in topTypes {
                counts.append((type.lowercased(), count))
            }
        }

        // Parse from result text
        if let resultText = ToolResultExtractor.string("result", from: result) {
            let patterns: [(String, String)] = [
                (#"(\d+) buttons?"#, "buttons"),
                (#"(\d+) text fields?"#, "text fields"),
                (#"(\d+) links?"#, "links"),
                (#"(\d+) images?"#, "images"),
                (#"(\d+) labels?"#, "labels"),
            ]

            for (pattern, label) in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(
                       in: resultText,
                       range: NSRange(resultText.startIndex..., in: resultText)),
                   match.numberOfRanges > 1,
                   let countRange = Range(match.range(at: 1), in: resultText),
                   let count = Int(resultText[countRange])
                {
                    counts.append((label, count))
                }
            }
        }

        guard !counts.isEmpty else { return nil }

        let formatted = counts.map { type, count in
            if type == "total" {
                return "\(count) element\(count == 1 ? "" : "s")"
            }
            if type == "element" {
                return "\(count) element\(count == 1 ? "" : "s")"
            }
            return "\(count) \(type)"
        }.joined(separator: ", ")

        return "[\(formatted)]"
    }

    private func extractKeyFindings(from result: [String: Any]) -> String? {
        var findings: [String] = []

        // Dialog detection
        if let dialogDetected = ToolResultExtractor.bool("dialogDetected", from: result), dialogDetected {
            findings.append("\(AgentDisplayTokens.Status.warning) Dialog detected")

            if let dialogType = ToolResultExtractor.string("dialogType", from: result) {
                findings.append("(\(dialogType))")
            }
        }

        // Error states
        if let hasErrors = ToolResultExtractor.bool("hasErrors", from: result), hasErrors {
            findings.append("\(AgentDisplayTokens.Status.failure) Errors found")
        }

        // Active element
        if let focusedElement = ToolResultExtractor.string("focusedElement", from: result) {
            findings.append("Focus: \(focusedElement)")
        }

        // Key UI states
        if let isLoading = ToolResultExtractor.bool("isLoading", from: result), isLoading {
            findings.append("⏳ Loading")
        }

        return findings.isEmpty ? nil : findings.joined(separator: " ")
    }

    private func extractPerformanceMetrics(from result: [String: Any]) -> String? {
        var metrics: [String] = []

        // Capture time
        if let captureTime = ToolResultExtractor.double("captureTime", from: result) {
            metrics.append(String(format: "Capture: %.0fms", captureTime * 1000))
        }

        // Analysis time
        if let analysisTime = ToolResultExtractor.double("analysisTime", from: result) {
            metrics.append(String(format: "Analysis: %.0fms", analysisTime * 1000))
        }

        // Total time
        if let totalTime = ToolResultExtractor.double("totalTime", from: result) {
            metrics.append(String(format: "Total: %.0fms", totalTime * 1000))
        }

        return metrics.isEmpty ? nil : "\(AgentDisplayTokens.Status.time) \(metrics.joined(separator: ", "))"
    }

    private func formatFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = bytes < 1024 ? .useBytes :
            bytes < 1024 * 1024 ? .useKB :
            bytes < 1024 * 1024 * 1024 ? .useMB : .useGB
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
