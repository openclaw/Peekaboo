import PeekabooAutomationKit
import TachikomaMCP

struct InspectUIRequest {
    let appTarget: String?
    let snapshotId: String?
    let traversalBudget: AXTraversalBudget

    init(arguments: ToolArguments) {
        self.appTarget = arguments.getString("app_target")
        self.snapshotId = arguments.getString("snapshot")
        self.traversalBudget = AXTraversalBudget.resolved(
            maxDepth: Self.positiveInt("max_depth", in: arguments),
            maxElementCount: Self.positiveInt("max_elements", in: arguments),
            maxChildrenPerNode: Self.positiveInt("max_children", in: arguments))
    }

    private static func positiveInt(_ key: String, in arguments: ToolArguments) -> Int? {
        guard let value = arguments.getInt(key), value > 0 else {
            return nil
        }
        return value
    }
}

@MainActor
struct InspectUISummaryBuilder {
    private static let maxRenderedElements = 120
    private static let maxFieldLength = 240

    let snapshot: UISnapshot
    let result: ElementDetectionResult
    let target: ObservationTargetArgument

    func build() async -> String {
        var lines = self.headerLines()
        await lines.append(contentsOf: self.metadataLines())
        lines.append("Elements found: \(self.result.elements.all.count)")
        if self.result.metadata.method.contains("cached") {
            lines.append("(Result from cached accessibility tree)")
        }
        lines.append(contentsOf: self.truncationWarningLines())
        lines.append("")
        lines.append(contentsOf: self.elementSection())
        lines.append("")
        lines.append("Use element IDs with click, type, and other interaction commands.")
        lines.append("If text looks incomplete, use `see` for a screenshot-based observation.")
        return lines.joined(separator: "\n")
    }

    private func headerLines() -> [String] {
        [
            "UI Text Inspection",
            "Snapshot ID: \(self.snapshot.id)",
        ]
    }

    private func metadataLines() async -> [String] {
        var lines: [String] = []
        if let appName = self.result.metadata.windowContext?.applicationName {
            lines.append("Application: \(appName)")
        }
        if let windowTitle = self.result.metadata.windowContext?.windowTitle {
            lines.append("Window: \(windowTitle)")
        }
        return lines
    }

    private func elementSection() -> [String] {
        let elements = self.result.elements.all
        guard !elements.isEmpty else {
            return ["No accessible UI elements found. Try `see` for screenshot-based detection."]
        }

        let renderedElements = Array(elements.prefix(Self.maxRenderedElements))
        let omittedCount = elements.count - renderedElements.count
        let elementsByRole = Dictionary(grouping: renderedElements, by: { $0.type.rawValue })
        var lines = ["UI Elements:"]
        for (role, roleElements) in elementsByRole.sorted(by: { $0.key < $1.key }) {
            lines.append("")
            lines.append(self.roleHeader(role: role, elements: roleElements))
            lines.append(contentsOf: roleElements.map(self.describeElement))
        }
        if omittedCount > 0 {
            lines.append("")
            lines.append(
                "\(omittedCount) additional elements omitted from text output. " +
                    "Use `see` or a narrower app_target if you need more context.")
        }
        return lines
    }

    private func truncationWarningLines() -> [String] {
        guard let truncationInfo = self.result.metadata.truncationInfo, truncationInfo.isTruncated else {
            return []
        }
        return [truncationInfo.remediationMessage(budget: self.result.metadata.windowContext?.traversalBudget)]
    }

    private func roleHeader(role: String, elements: [DetectedElement]) -> String {
        let actionableCount = elements.count(where: { $0.isEnabled })
        return "\(role) (\(elements.count) found, \(actionableCount) actionable):"
    }

    private func describeElement(_ element: DetectedElement) -> String {
        var parts = ["  \(element.id)"]
        if let label = self.clipped(element.label) {
            parts.append("\"\(label)\"")
        }
        let sizeText = "size \(Int(element.bounds.width))x\(Int(element.bounds.height))"
        parts.append("at (\(Int(element.bounds.origin.x)), \(Int(element.bounds.origin.y))) \(sizeText)")
        if let value = self.clipped(element.value) {
            parts.append("value: \"\(value)\"")
        }
        if let desc = self.clipped(element.attributes["description"]) {
            parts.append("desc: \"\(desc)\"")
        }
        if let help = self.clipped(element.attributes["help"]) {
            parts.append("help: \"\(help)\"")
        }
        if let shortcut = self.clipped(element.attributes["keyboardShortcut"]) {
            parts.append("shortcut: \(shortcut)")
        }
        if let identifier = self.clipped(element.attributes["identifier"]) {
            parts.append("identifier: \(identifier)")
        }
        if !element.isEnabled {
            parts.append("[not actionable]")
        }
        return parts.joined(separator: " - ")
    }

    private func clipped(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.count > Self.maxFieldLength else { return value }
        let index = value.index(value.startIndex, offsetBy: Self.maxFieldLength)
        return String(value[..<index]) + "..."
    }
}
