import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

struct InspectUIRequest {
    let appTarget: String?
    let windowIDValue: Value?
    let snapshotId: String?
    let webFocus: Bool
    let fresh: Bool
    let includeElements: Bool
    let traversalBudget: AXTraversalBudget

    init(arguments: ToolArguments) throws {
        self.appTarget = arguments.getString("app_target")
        self.windowIDValue = arguments.getValue(for: "window_id")
        self.snapshotId = arguments.getString("snapshot")
        self.webFocus = arguments.getBool("web_focus") ?? false
        switch arguments.getValue(for: "fresh") {
        case nil:
            self.fresh = false
        case let .bool(value)?:
            self.fresh = value
        default:
            throw PeekabooError.invalidInput("fresh must be a boolean")
        }
        self.includeElements = arguments.getBool(ObservedElementTableMetadata.argumentName) ?? false
        self.traversalBudget = try AXTraversalBudget.resolved(
            maxDepth: Self.positiveInt("max_depth", in: arguments),
            maxElementCount: Self.positiveInt("max_elements", in: arguments),
            maxChildrenPerNode: Self.positiveInt("max_children", in: arguments))
    }

    private static func positiveInt(_ key: String, in arguments: ToolArguments) throws -> Int? {
        guard let value = try arguments.validatedInt(key) else { return nil }
        guard value > 0 else {
            throw PeekabooError.invalidInput("\(key) must be a positive integer")
        }
        return value
    }
}

@MainActor
struct InspectUISummaryBuilder {
    let snapshot: UISnapshot
    let result: ElementDetectionResult
    let target: ObservationTargetArgument

    func build() async -> String {
        var lines = self.headerLines()
        await lines.append(contentsOf: self.metadataLines())
        lines.append("Elements found: \(self.result.elements.all.count)")
        lines.append(contentsOf: ObservedTextSelectionSummary.lines(for: self.result.elements.all))
        if self.result.metadata.method.contains("cached") {
            lines.append("(Result from cached accessibility tree)")
        }
        lines.append(contentsOf: self.truncationWarningLines())
        lines.append("")
        lines.append(contentsOf: InspectUIElementTextFormatter.section(self.result.elements.all.map {
            UIElementSummary($0, mutationTargetingAvailable: true)
        }))
        lines.append("")
        lines.append(InspectUIElementTextFormatter.interactionHint)
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

    private func truncationWarningLines() -> [String] {
        guard let truncationInfo = self.result.metadata.truncationInfo, truncationInfo.isTruncated else {
            return []
        }
        return [truncationInfo.automationToolRemediationMessage(
            budget: self.result.metadata.windowContext?.traversalBudget,
            applicationScopedFallback: self.result.metadata.isApplicationScopedAccessibilityFallback)]
    }
}
