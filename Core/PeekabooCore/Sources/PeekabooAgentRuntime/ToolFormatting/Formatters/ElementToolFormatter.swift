//
//  ElementToolFormatter.swift
//  PeekabooCore
//

import Foundation

/// Formatter for element query and search tools with comprehensive result formatting
public class ElementToolFormatter: BaseToolFormatter {
    override public func formatCompactSummary(arguments: [String: Any]) -> String {
        switch toolType {
        case .setValue:
            let target = arguments["on"] as? String ?? "element"
            if let value = arguments["value"] {
                return "\(target) to \(self.truncate(String(describing: value), maxLength: 30))"
            }
            return target
        case .action, .performAction:
            let action = arguments["action"] as? String ?? "action"
            let target = arguments["on"] as? String ?? "element"
            return "\(action) on \(target)"
        case .findElement:
            return self.compactSummaryForFind(arguments: arguments)
        case .listElements:
            return self.compactSummaryForList(arguments: arguments)
        case .focused:
            return self.compactSummaryForFocused(arguments: arguments)
        default:
            return super.formatCompactSummary(arguments: arguments)
        }
    }

    override public func formatResultSummary(result: [String: Any]) -> String {
        switch toolType {
        case .setValue:
            self.formatSetValueResult(result)
        case .performAction:
            self.formatPerformActionResult(result)
        case .findElement:
            self.formatFindElementResult(result)
        case .listElements:
            self.formatListElementsResult(result)
        case .focused:
            self.formatFocusedElementResult(result)
        case .inspectUI:
            self.formatInspectUIResult(result)
        default:
            super.formatResultSummary(result: result)
        }
    }

    private func formatSetValueResult(_ result: [String: Any]) -> String {
        guard let target = ToolResultExtractor.string("target", from: result) else { return "" }
        if let value = ToolResultExtractor.string("new_value", from: result) ??
            ToolResultExtractor.string("value", from: result)
        {
            return "→ Set \(target) to \"\(self.truncate(value, maxLength: 40))\""
        }
        return "→ Set value on \(target)"
    }

    private func formatPerformActionResult(_ result: [String: Any]) -> String {
        guard let target = ToolResultExtractor.string("target", from: result) else { return "" }
        if let action = ToolResultExtractor.string("action_name", from: result) {
            return "→ Performed \(action) on \(target)"
        }
        return "→ Performed action on \(target)"
    }

    private func formatInspectUIResult(_ result: [String: Any]) -> String {
        let count = ToolResultExtractor.int("count", from: result) ??
            ToolResultExtractor.int("elementCount", from: result) ??
            (ToolResultExtractor.array("elements", from: result) as [[String: Any]]?)?.count
        guard let count else { return "" }
        return "→ \(count) element\(count == 1 ? "" : "s")"
    }

    // MARK: - Find Element Formatting

    private func formatFindElementResult(_ result: [String: Any]) -> String {
        var parts: [String] = []
        if ToolResultExtractor.bool("found", from: result) ?? false {
            parts.append(contentsOf: self.foundElementSummary(result))
        } else {
            parts.append(contentsOf: self.missingElementSummary(result))
        }
        return parts.joined(separator: " ")
    }

    private func foundElementSummary(_ result: [String: Any]) -> [String] {
        var sections = ["→ Found"]
        sections.append(contentsOf: self.elementPrimaryText(result))
        sections.append(contentsOf: self.elementTypeSection(result))
        sections.append(contentsOf: self.elementPositionSection(result))
        sections.append(contentsOf: self.elementStateSection(result))
        if let depth = ToolResultExtractor.int("depth", from: result) {
            sections.append("depth: \(depth)")
        }
        if let app = ToolResultExtractor.string("app", from: result) {
            sections.append("in \(app)")
        }
        if let confidenceSummary = elementConfidenceSection(result) {
            sections.append(confidenceSummary)
        }
        if let alternatives = ToolResultExtractor.int("alternativesCount", from: result), alternatives > 0 {
            sections.append("• \(alternatives) similar element\(alternatives == 1 ? "" : "s") also found")
        }
        return sections
    }

    private func missingElementSummary(_ result: [String: Any]) -> [String] {
        var sections = ["→ Not found"]
        if let query = ToolResultExtractor.string("query", from: result)
            ?? ToolResultExtractor.string("text", from: result)
        {
            let truncated = query.count > 50 ? String(query.prefix(50)) + "..." : query
            sections.append("\"\(truncated)\"")
        }
        if let scope = ToolResultExtractor.string("searchScope", from: result)
            ?? ToolResultExtractor.string("app", from: result)
        {
            sections.append("in \(scope)")
        }
        if let suggestions: [String] = ToolResultExtractor.array("suggestions", from: result),
           !suggestions.isEmpty
        {
            let suggestionList = suggestions.prefix(3).map { "\"\($0)\"" }.joined(separator: ", ")
            sections.append("• Did you mean: \(suggestionList)?")
        }
        if let similarCount = ToolResultExtractor.int("similarElementsCount", from: result), similarCount > 0 {
            sections.append("• \(similarCount) similar element\(similarCount == 1 ? "" : "s") found")
        }
        return sections
    }

    // MARK: Find Element helpers

    private func elementPrimaryText(_ result: [String: Any]) -> [String] {
        if let text = ToolResultExtractor.string("text", from: result) {
            let truncated = text.count > 40 ? String(text.prefix(40)) + "..." : text
            return ["\"\(truncated)\""]
        }
        if let label = ToolResultExtractor.string("label", from: result) {
            return ["\"\(label)\""]
        }
        return []
    }

    private func elementTypeSection(_ result: [String: Any]) -> [String] {
        var typeInfo: [String] = []
        if let type = ToolResultExtractor.string("type", from: result) {
            typeInfo.append(type)
        }
        if let role = ToolResultExtractor.string("role", from: result) {
            typeInfo.append("role: \(role)")
        }
        guard !typeInfo.isEmpty else { return [] }
        return ["(\(typeInfo.joined(separator: ", ")))"]
    }

    private func elementPositionSection(_ result: [String: Any]) -> [String] {
        if let frame = ToolResultExtractor.dictionary("frame", from: result),
           let x = self.intValue(frame["x"]),
           let y = self.intValue(frame["y"]),
           let width = self.intValue(frame["width"]),
           let height = self.intValue(frame["height"])
        {
            return ["[\(width)×\(height) at (\(x), \(y))]"]
        }
        if let coords = ToolResultExtractor.coordinates(from: result) {
            return ["at (\(coords.x), \(coords.y))"]
        }
        return []
    }

    private func elementStateSection(_ result: [String: Any]) -> [String] {
        var states: [String] = []
        if ToolResultExtractor.bool("enabled", from: result) == false {
            states.append("disabled")
        }
        if ToolResultExtractor.bool("focused", from: result) == true {
            states.append("focused")
        }
        if ToolResultExtractor.bool("selected", from: result) == true {
            states.append("selected")
        }
        if ToolResultExtractor.bool("visible", from: result) == true {
            states.append("visible")
        }
        return states.isEmpty ? [] : ["• \(states.joined(separator: ", "))"]
    }

    private func elementConfidenceSection(_ result: [String: Any]) -> String? {
        guard let confidence = ToolResultExtractor.double("confidence", from: result), confidence < 1.0 else {
            return nil
        }
        return String(format: "%.0f%% match", confidence * 100)
    }

    // MARK: - List Elements Formatting

    private func formatListElementsResult(_ result: [String: Any]) -> String {
        var sections: [String] = []
        sections.append(self.listElementCountSection(result))
        if let breakdown = listTypeBreakdownSection(result) {
            sections.append(breakdown)
        }
        if let states = listStateBreakdownSection(result) {
            sections.append(states)
        }
        if let interactions = listInteractionSection(result) {
            sections.append(interactions)
        }
        if let samples = listSamplesSection(result) {
            sections.append(samples)
        }
        if let filter = listFilterSection(result) {
            sections.append(filter)
        }
        if let context = listContextSection(result) {
            sections.append(context)
        }
        if let perf = listPerformanceSection(result) {
            sections.append(perf)
        }
        return sections.isEmpty ? "→ listed" : sections.joined(separator: " ")
    }

    // MARK: - Compact summary helpers

    private func compactSummaryForFind(arguments: [String: Any]) -> String {
        let query = (arguments["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let query, !query.isEmpty {
            let truncated = query.count > 40 ? String(query.prefix(40)) + "…" : query
            return "\"\(truncated)\""
        }
        return "element"
    }

    private func compactSummaryForList(arguments: [String: Any]) -> String {
        if let scope = (arguments["scope"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !scope.isEmpty
        {
            return scope
        }
        if let app = (arguments["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !app.isEmpty
        {
            return app
        }
        return "current UI"
    }

    private func compactSummaryForFocused(arguments: [String: Any]) -> String {
        if let app = (arguments["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !app.isEmpty
        {
            return app
        }
        return ""
    }

    override public func formatStarting(arguments: [String: Any]) -> String {
        switch toolType {
        case .findElement:
            let summary = self.formatCompactSummary(arguments: arguments)
            if !summary.isEmpty {
                return "🔍 Searching for \(summary)..."
            }
            return "🔍 Searching for element..."

        case .listElements:
            let summary = self.formatCompactSummary(arguments: arguments)
            if !summary.isEmpty {
                return "[menu] Scanning \(summary)..."
            }
            return "[menu] Scanning UI elements..."

        case .focused:
            if let app = arguments["app"] as? String {
                return "[focus] Checking focused element in \(app)..."
            }
            return "[focus] Checking focused element..."

        default:
            return super.formatStarting(arguments: arguments)
        }
    }

    // MARK: - Focused Element Formatting

    private func formatFocusedElementResult(_ result: [String: Any]) -> String {
        if ToolResultExtractor.bool("found", from: result) == false {
            return "→ No focused element"
        }

        if let message = ToolResultExtractor.string("message", from: result),
           ToolResultExtractor.dictionary("element", from: result) == nil
        {
            return "→ \(message)"
        }

        let element = ToolResultExtractor.dictionary("element", from: result) ?? result
        var sections = ["→ Focused"]
        sections.append(contentsOf: self.elementPrimaryText(element))
        sections.append(contentsOf: self.elementTypeSection(element))
        sections.append(contentsOf: self.elementPositionSection(element))
        sections.append(contentsOf: self.elementStateSection(element))

        if let app = self.focusedAppName(from: result, element: element) {
            sections.append("in \(app)")
        }
        if let bundle = ToolResultExtractor.string("bundleIdentifier", from: result) {
            sections.append("(\(bundle))")
        }

        if sections.count == 1,
           let fallback = ToolResultExtractor.string("message", from: result)
        {
            sections.append(fallback)
        }

        return sections.joined(separator: " ")
    }

    private func focusedAppName(from result: [String: Any], element: [String: Any]) -> String? {
        if let app = ToolResultExtractor.string("app", from: result) {
            return app
        }
        if let app = ToolResultExtractor.string("applicationName", from: result) {
            return app
        }
        if let app = ToolResultExtractor.string("application", from: element) {
            return app
        }
        return nil
    }

    // MARK: - List Helpers

    private func listElementCountSection(_ result: [String: Any]) -> String {
        let explicitCount = ToolResultExtractor.int("count", from: result)
        let derivedCount: Int? = if explicitCount == nil,
                                    let elements: [[String: Any]] = ToolResultExtractor.array("elements", from: result)
        {
            elements.count
        } else {
            nil
        }
        let total = explicitCount ?? derivedCount ?? 0
        if let type = ToolResultExtractor.string("type", from: result) {
            return "→ \(total) \(type) element\(total == 1 ? "" : "s")"
        }
        return "→ \(total) element\(total == 1 ? "" : "s")"
    }

    private func listTypeBreakdownSection(_ result: [String: Any]) -> String? {
        guard let elements: [[String: Any]] = ToolResultExtractor.array("elements", from: result) else {
            return nil
        }
        let typeGroups = Dictionary(grouping: elements) { element in
            (element["type"] as? String) ?? "unknown"
        }
        guard typeGroups.count > 1 else { return nil }
        let breakdown = typeGroups.map { type, items in
            "\(type): \(items.count)"
        }.sorted().prefix(5).joined(separator: ", ")
        return "[\(breakdown)]"
    }

    private func listStateBreakdownSection(_ result: [String: Any]) -> String? {
        guard let elements: [[String: Any]] = ToolResultExtractor.array("elements", from: result) else {
            return nil
        }
        let total = elements.count
        let enabledCount = elements.count(where: { ($0["enabled"] as? Bool) == true })
        let disabledCount = elements.count(where: { ($0["enabled"] as? Bool) == false })
        let visibleCount = elements.count(where: { ($0["visible"] as? Bool) == true })
        let focusedCount = elements.count(where: { ($0["focused"] as? Bool) == true })
        var states: [String] = []
        if enabledCount > 0 {
            states.append("\(enabledCount) enabled")
        }
        if disabledCount > 0 {
            states.append("\(disabledCount) disabled")
        }
        if visibleCount > 0, visibleCount != total {
            states.append("\(visibleCount) visible")
        }
        if focusedCount > 0 {
            states.append("\(focusedCount) focused")
        }
        guard !states.isEmpty else { return nil }
        return "(\(states.joined(separator: ", ")))"
    }

    private func listInteractionSection(_ result: [String: Any]) -> String? {
        guard let elements: [[String: Any]] = ToolResultExtractor.array("elements", from: result) else {
            return nil
        }
        let clickableCount = elements.count(where: {
            ($0["clickable"] as? Bool) == true ||
                ($0["type"] as? String)?.lowercased().contains("button") == true
        })
        let editableCount = elements.count(where: {
            ($0["editable"] as? Bool) == true ||
                ($0["type"] as? String)?.lowercased().contains("field") == true
        })
        guard clickableCount > 0 || editableCount > 0 else { return nil }
        var interactive: [String] = []
        if clickableCount > 0 {
            interactive.append("\(clickableCount) clickable")
        }
        if editableCount > 0 {
            interactive.append("\(editableCount) editable")
        }
        return "• \(interactive.joined(separator: ", "))"
    }

    private func listSamplesSection(_ result: [String: Any]) -> String? {
        guard let elements: [[String: Any]] = ToolResultExtractor.array("elements", from: result),
              !elements.isEmpty,
              elements.count <= 5
        else {
            return nil
        }
        let samples = elements.prefix(3).compactMap { element -> String? in
            if let text = element["text"] as? String, !text.isEmpty {
                let truncated = text.count > 25 ? String(text.prefix(25)) + "..." : text
                return "\"\(truncated)\""
            } else if let type = element["type"] as? String {
                return type
            }
            return nil
        }
        guard !samples.isEmpty else { return nil }
        return "• \(samples.joined(separator: ", "))"
    }

    private func listFilterSection(_ result: [String: Any]) -> String? {
        guard let filter = ToolResultExtractor.string("filter", from: result) else { return nil }
        return "filtered by: \(filter)"
    }

    private func listContextSection(_ result: [String: Any]) -> String? {
        if let app = ToolResultExtractor.string("app", from: result) {
            return "in \(app)"
        }
        if let window = ToolResultExtractor.string("window", from: result) {
            return "in window: \"\(self.truncate(window))\""
        }
        return nil
    }

    private func listPerformanceSection(_ result: [String: Any]) -> String? {
        guard let scanTime = ToolResultExtractor.double("scanTime", from: result), scanTime > 1.0 else {
            return nil
        }
        return String(format: "• Scan time: %.1fs", scanTime)
    }

    // MARK: - Shared Helpers

    private func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let doubleValue = value as? Double {
            return Int(doubleValue.rounded())
        }
        if let stringValue = value as? String,
           let doubleValue = Double(stringValue)
        {
            return Int(doubleValue.rounded())
        }
        return nil
    }
}
