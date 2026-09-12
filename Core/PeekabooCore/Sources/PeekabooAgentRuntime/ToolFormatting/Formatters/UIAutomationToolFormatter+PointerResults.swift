//
//  UIAutomationToolFormatter+PointerResults.swift
//  PeekabooCore
//

import Foundation

extension UIAutomationToolFormatter {
    func formatClickResult(_ result: [String: Any]) -> String {
        var parts = ["→ Clicked"]

        if let elementDescription = self.elementDescription(from: result) {
            parts.append(elementDescription)
        }

        if let positionSummary = self.positionSummary(from: result) {
            parts.append(positionSummary)
        }

        let detailEntries = self.clickDetailEntries(from: result)
        if !detailEntries.isEmpty {
            parts.append("[\(detailEntries.joined(separator: ", "))]")
        }

        if let actionTriggered = ToolResultExtractor.string("actionTriggered", from: result) {
            parts.append("• Triggered: \(actionTriggered)")
        }

        return parts.joined(separator: " ")
    }

    func formatScrollResult(_ result: [String: Any]) -> String {
        var parts = ["→ Scrolled"]

        if let direction = ToolResultExtractor.string("direction", from: result) {
            parts.append(direction)
        }

        if let amount = ToolResultExtractor.int("amount", from: result) {
            parts.append("\(amount) units")
        } else if let pixels = ToolResultExtractor.int("pixels", from: result) {
            parts.append("\(pixels)px")
        } else if let lines = ToolResultExtractor.int("lines", from: result) {
            parts.append("\(lines) lines")
        } else if let pages = ToolResultExtractor.double("pages", from: result) {
            parts.append(String(format: "%.1f pages", pages))
        }

        if let element = ToolResultExtractor.string("element", from: result) {
            parts.append("in \(element)")
        } else if let container = ToolResultExtractor.string("container", from: result) {
            parts.append("in \(container)")
        }

        var details: [String] = []

        if let position = ToolResultExtractor.dictionary("scrollPosition", from: result),
           let x = position["x"] as? Int,
           let y = position["y"] as? Int
        {
            details.append("position: (\(x), \(y))")
        }

        if let percentage = ToolResultExtractor.double("scrollPercentage", from: result) {
            details.append(String(format: "%.0f%%", percentage))
        }

        if let atTop = ToolResultExtractor.bool("atTop", from: result), atTop {
            details.append("at top")
        } else if let atBottom = ToolResultExtractor.bool("atBottom", from: result), atBottom {
            details.append("at bottom")
        }

        if let revealed = ToolResultExtractor.string("revealed", from: result) {
            details.append("revealed: \(revealed)")
        }

        if !details.isEmpty {
            parts.append("[\(details.joined(separator: ", "))]")
        }

        return parts.joined(separator: " ")
    }

    func formatDragResult(_ result: [String: Any]) -> String {
        var parts = ["→ Dragged"]

        if let from = self.locationDescription("from", fallback: "source", from: result) {
            parts.append("from \(from)")
        }
        if let to = self.locationDescription("to", fallback: "destination", from: result) {
            parts.append("to \(to)")
        }

        var details = self.pointerDetailEntries(from: result)

        if let modifiers = ToolResultExtractor.string("modifiers", from: result), !modifiers.isEmpty {
            details.append("modifiers: \(modifiers)")
        }

        if !details.isEmpty {
            parts.append("[\(details.joined(separator: ", "))]")
        }

        return parts.joined(separator: " ")
    }

    func formatSwipeResult(_ result: [String: Any]) -> String {
        var parts = ["→ Swiped"]

        if let direction = ToolResultExtractor.string("direction", from: result) {
            parts.append(direction)
        }
        if let from = self.locationDescription("from", fallback: nil, from: result) {
            parts.append("from \(from)")
        }
        if let to = self.locationDescription("to", fallback: "element", from: result) {
            parts.append("to \(to)")
        }

        var details = self.pointerDetailEntries(from: result)

        if let percentage = ToolResultExtractor.double("percentage", from: result) {
            details.append(String(format: "%.0f%%", percentage))
        }
        if let speed = ToolResultExtractor.string("speed", from: result) {
            details.append(speed)
        }
        if let navigated = ToolResultExtractor.string("navigated", from: result) {
            details.append("navigated to: \(navigated)")
        }
        if let dismissed = ToolResultExtractor.bool("dismissed", from: result), dismissed {
            details.append("dismissed")
        }
        if let revealed = ToolResultExtractor.string("revealed", from: result) {
            details.append("revealed: \(revealed)")
        }
        if let gesture = ToolResultExtractor.string("gesture", from: result) {
            details.append("gesture: \(gesture)")
        }

        if !details.isEmpty {
            parts.append("[\(details.joined(separator: ", "))]")
        }

        return parts.joined(separator: " ")
    }

    func formatMoveResult(_ result: [String: Any]) -> String {
        var parts = ["→ Moved cursor"]

        if let target = ToolResultExtractor.string("target_description", from: result) {
            parts.append("to \(target)")
        } else if let location = self.pointSummary("target_location", from: result) {
            parts.append("to \(location)")
        }

        let details = self.pointerDetailEntries(from: result)
        if !details.isEmpty {
            parts.append("[\(details.joined(separator: ", "))]")
        }

        return parts.joined(separator: " ")
    }

    func elementDescription(from result: [String: Any]) -> String? {
        if let element = ToolResultExtractor.string("element", from: result) {
            return "on \"\(self.truncate(element, maxLength: 40))\""
        }
        if let description = ToolResultExtractor.string("description", from: result) {
            return "on \(self.truncate(description, maxLength: 40))"
        }
        return nil
    }

    func positionSummary(from result: [String: Any]) -> String? {
        if let position = ToolResultExtractor.dictionary("position", from: result),
           let point = self.pointSummary(from: position)
        {
            return "at \(point)"
        }
        if let x = ToolResultExtractor.int("x", from: result),
           let y = ToolResultExtractor.int("y", from: result)
        {
            return "at (\(x), \(y))"
        }
        return nil
    }

    func clickDetailEntries(from result: [String: Any]) -> [String] {
        var details: [String] = []

        if let clickCount = ToolResultExtractor.int("clickCount", from: result), clickCount > 1 {
            details.append("\(clickCount) clicks")
        }
        if let button = ToolResultExtractor.string("button", from: result), button != "left" {
            details.append("\(button) button")
        }
        if let modifiers: [String] = ToolResultExtractor.array("modifiers", from: result), !modifiers.isEmpty {
            let shortcut = modifiers.joined(separator: "+")
            details.append("with \(FormattingUtilities.formatKeyboardShortcut(shortcut))")
        }
        if let elementType = ToolResultExtractor.string("elementType", from: result) {
            details.append(elementType)
        }
        if let role = ToolResultExtractor.string("role", from: result) {
            details.append("role: \(role)")
        }
        if let app = ToolResultExtractor.string("app", from: result) {
            details.append("in \(app)")
        }

        return details
    }

    func pointerDetailEntries(from result: [String: Any]) -> [String] {
        var details: [String] = []

        if let profile = ToolResultExtractor.string("profile", from: result) {
            details.append("\(profile) profile")
        }
        if let distance = ToolResultExtractor.double("distance", from: result) {
            details.append(String(format: "%.1fpx", distance))
        }
        if let duration = ToolResultExtractor.int("duration", from: result) {
            details.append("\(duration)ms")
        }
        if let steps = ToolResultExtractor.int("steps", from: result) {
            details.append("\(steps) steps")
        }
        if let smooth = ToolResultExtractor.bool("smooth", from: result), !smooth {
            details.append("instant")
        }

        return details
    }

    func locationDescription(_ key: String, fallback: String?, from result: [String: Any]) -> String? {
        if let location = ToolResultExtractor.dictionary(key, from: result) {
            if let description = location["description"] as? String {
                return self.truncate(description, maxLength: 50)
            }
            if let point = self.pointSummary(from: location) {
                return point
            }
        }
        if let fallback, let value = ToolResultExtractor.string(fallback, from: result) {
            return self.truncate(value, maxLength: 50)
        }
        return nil
    }

    func pointSummary(_ key: String, from result: [String: Any]) -> String? {
        guard let dictionary = ToolResultExtractor.dictionary(key, from: result) else {
            return nil
        }
        return self.pointSummary(from: dictionary)
    }

    func pointSummary(from dictionary: [String: Any]) -> String? {
        guard let x = self.numericCoordinate("x", from: dictionary),
              let y = self.numericCoordinate("y", from: dictionary)
        else {
            return nil
        }
        return "(\(x), \(y))"
    }

    func numericCoordinate(_ key: String, from dictionary: [String: Any]) -> Int? {
        if let value = dictionary[key] as? Int {
            return value
        }
        if let value = dictionary[key] as? Double {
            return Int(value)
        }
        return nil
    }
}
