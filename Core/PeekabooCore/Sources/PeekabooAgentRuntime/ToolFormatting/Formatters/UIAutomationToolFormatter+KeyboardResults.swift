//
//  UIAutomationToolFormatter+KeyboardResults.swift
//  PeekabooCore
//

import Foundation

extension UIAutomationToolFormatter {
    func formatTypeResult(_ result: [String: Any]) -> String {
        var parts = ["→ Typed"]

        if let text = ToolResultExtractor.string("text", from: result) {
            let displayText = text.count > 50 ? String(text.prefix(47)) + "..." : text
            let escaped = displayText
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
            parts.append("\"\(escaped)\"")
        }

        if let field = ToolResultExtractor.string("field", from: result) {
            parts.append("in \(field)")
        } else if let element = ToolResultExtractor.string("element", from: result) {
            parts.append("in \(element)")
        }

        var details: [String] = []

        if let characterCount = ToolResultExtractor.int("characterCount", from: result) {
            details.append("\(characterCount) chars")
        }

        if let wordCount = ToolResultExtractor.int("wordCount", from: result) {
            details.append("\(wordCount) words")
        }

        if let cleared = ToolResultExtractor.bool("clearedFirst", from: result), cleared {
            details.append("cleared first")
        }

        if let submitted = ToolResultExtractor.bool("submitted", from: result), submitted {
            details.append("submitted")
        }

        if let typingSpeed = ToolResultExtractor.string("typingSpeed", from: result) {
            details.append(typingSpeed)
        }

        if !details.isEmpty {
            parts.append("[\(details.joined(separator: ", "))]")
        }

        if let validation = ToolResultExtractor.dictionary("validation", from: result),
           let isValid = validation["isValid"] as? Bool
        {
            if isValid {
                parts.append("✓ Valid")
            } else if let error = validation["error"] as? String {
                parts.append("✗ \(error)")
            }
        }

        return parts.joined(separator: " ")
    }

    func formatHotkeyResult(_ result: [String: Any]) -> String {
        var parts = ["→ Pressed"]

        if let keys = ToolResultExtractor.string("keys", from: result) {
            parts.append(FormattingUtilities.formatKeyboardShortcut(keys))
        } else if let shortcut = ToolResultExtractor.string("shortcut", from: result) {
            parts.append(FormattingUtilities.formatKeyboardShortcut(shortcut))
        }

        if let action = ToolResultExtractor.string("action", from: result) {
            parts.append("• \(action)")
        } else if let triggered = ToolResultExtractor.string("triggered", from: result) {
            parts.append("• \(triggered)")
        }

        if let app = ToolResultExtractor.string("app", from: result) {
            parts.append("in \(app)")
        }

        var details: [String] = []

        if let windowOpened = ToolResultExtractor.string("windowOpened", from: result) {
            details.append("opened: \(windowOpened)")
        }

        if let commandExecuted = ToolResultExtractor.string("commandExecuted", from: result) {
            details.append("executed: \(commandExecuted)")
        }

        if let modeChanged = ToolResultExtractor.string("modeChanged", from: result) {
            details.append("mode: \(modeChanged)")
        }

        if !details.isEmpty {
            parts.append("[\(details.joined(separator: ", "))]")
        }

        return parts.joined(separator: " ")
    }

    func formatPressResult(_ result: [String: Any]) -> String {
        var parts = ["→ Pressed"]

        if let key = ToolResultExtractor.string("key", from: result) {
            parts.append(self.formatSpecialKey(key))
        }

        if let repeatCount = ToolResultExtractor.int("repeatCount", from: result), repeatCount > 1 {
            parts.append("\(repeatCount) times")
        }

        var details: [String] = []

        if let moved = ToolResultExtractor.string("moved", from: result) {
            details.append("moved: \(moved)")
        }

        if let selected = ToolResultExtractor.string("selected", from: result) {
            details.append("selected: \(selected)")
        }

        if let navigated = ToolResultExtractor.string("navigated", from: result) {
            details.append("navigated: \(navigated)")
        }

        if let deleted = ToolResultExtractor.bool("deleted", from: result), deleted {
            details.append("deleted text")
        }

        if let inserted = ToolResultExtractor.string("inserted", from: result) {
            details.append("inserted: \(inserted)")
        }

        if !details.isEmpty {
            parts.append("• \(details.joined(separator: ", "))")
        }

        return parts.joined(separator: " ")
    }

    func formatSpecialKey(_ key: String) -> String {
        switch key.lowercased() {
        case "return", "enter": "⏎ Enter"
        case "tab": "⇥ Tab"
        case "escape", "esc": "⎋ Escape"
        case "space": "␣ Space"
        case "delete", "backspace", "del": "⌫ Delete"
        case "forwarddelete", "forward_delete": "⌦ Forward Delete"
        case "up", "arrow_up": "↑ Up"
        case "down", "arrow_down": "↓ Down"
        case "left", "arrow_left": "← Left"
        case "right", "arrow_right": "→ Right"
        case "home": "↖ Home"
        case "end": "↘ End"
        case "pageup", "page_up": "⇞ Page Up"
        case "pagedown", "page_down": "⇟ Page Down"
        case "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12":
            "[tap] \(key.uppercased())"
        default:
            key
        }
    }
}
