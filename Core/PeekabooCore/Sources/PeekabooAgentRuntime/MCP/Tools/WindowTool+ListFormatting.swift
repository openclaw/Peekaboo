import Algorithms
import Foundation
import MCP
import PeekabooAutomation
import TachikomaMCP

enum WindowDetail: String, CaseIterable {
    case ids
    case bounds
    case offScreen = "off_screen"
}

struct WindowListFormatter {
    let appInfo: ServiceApplicationInfo?
    let identifier: String
    let windows: [ServiceWindowInfo]
    let details: Set<WindowDetail>

    func response() -> ToolResponse {
        var lines = self.headerLines()
        lines.append("")
        lines.append(contentsOf: self.windowLines())
        let baseMeta: Value = .object([
            "window_count": .int(self.windows.count),
            "app": self.appInfo?.name != nil ? .string(self.appInfo!.name) : .string(self.identifier),
        ])
        let summary = ToolEventSummary(
            targetApp: self.appInfo?.name ?? self.identifier,
            actionDescription: "List Windows",
            notes: "\(self.windows.count) windows")
        return ToolResponse.text(
            lines.joined(separator: "\n"),
            meta: ToolEventSummary.merge(summary: summary, into: baseMeta))
    }

    private func headerLines() -> [String] {
        let windowLabel = self.windows.count == 1 ? "window" : "windows"
        let countLine = "\(AgentDisplayTokens.Status.success) Found \(self.windows.count) \(windowLabel)"
        if let info = appInfo {
            var line = countLine + " for \(info.name)"
            if let bundleID = info.bundleIdentifier, !bundleID.isEmpty {
                line += " (\(bundleID))"
            }
            line += " - PID: \(info.processIdentifier)"
            return [line]
        }
        return [countLine + " for \(self.identifier)"]
    }

    private func windowLines() -> [String] {
        guard !self.windows.isEmpty else {
            return ["No windows found"]
        }

        var lines = ["Windows:"]
        for (index, window) in self.windows.indexed() {
            var entry = "\(index + 1). \"\(window.title)\""
            let detailText = self.detailDescription(for: window)
            if !detailText.isEmpty {
                entry += " \(detailText)"
            }
            lines.append(entry)
        }
        return lines
    }

    private func detailDescription(for window: ServiceWindowInfo) -> String {
        var parts: [String] = []
        if self.details.contains(.ids), window.windowID != 0 {
            parts.append("ID: \(window.windowID)")
        }
        if self.details.contains(.offScreen) {
            parts.append(window.isOffScreen ? "OFF-SCREEN" : "ON-SCREEN")
        }
        if self.details.contains(.bounds) {
            let bounds = window.bounds
            let text = "Bounds: \(Int(bounds.origin.x)), \(Int(bounds.origin.y)) " +
                "\(Int(bounds.width))×\(Int(bounds.height))"
            parts.append(text)
        }
        guard !parts.isEmpty else { return "" }
        return "[" + parts.joined(separator: ", ") + "]"
    }
}
