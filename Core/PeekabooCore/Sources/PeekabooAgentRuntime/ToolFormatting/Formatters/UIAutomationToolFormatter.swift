//
//  UIAutomationToolFormatter.swift
//  PeekabooCore
//

import Foundation

/// Formatter for UI automation tools with comprehensive result formatting
public class UIAutomationToolFormatter: BaseToolFormatter {
    override public func formatCompactSummary(arguments: [String: Any]) -> String {
        guard self.toolType == .paste else {
            return super.formatCompactSummary(arguments: arguments)
        }

        var parts: [String] = []
        if let text = arguments["text"] as? String {
            parts.append("\"\(self.truncate(text, maxLength: 30))\"")
        } else if let path = arguments["filePath"] as? String ?? arguments["imagePath"] as? String {
            parts.append(URL(fileURLWithPath: path).lastPathComponent)
        } else {
            parts.append("clipboard payload")
        }
        if let app = arguments["app"] as? String {
            parts.append("to \(app)")
        }
        return parts.joined(separator: " ")
    }

    override public func formatResultSummary(result: [String: Any]) -> String {
        switch toolType {
        case .click:
            self.formatClickResult(result)
        case .type:
            self.formatTypeResult(result)
        case .hotkey:
            self.formatHotkeyResult(result)
        case .press:
            self.formatPressResult(result)
        case .scroll:
            self.formatScrollResult(result)
        case .drag:
            self.formatDragResult(result)
        case .swipe:
            self.formatSwipeResult(result)
        case .move:
            self.formatMoveResult(result)
        case .paste:
            self.formatPasteResult(result)
        default:
            super.formatResultSummary(result: result)
        }
    }

    private func formatPasteResult(_ result: [String: Any]) -> String {
        guard let pasted = ToolResultExtractor.dictionary("pasted", from: result) else {
            return ""
        }
        if let preview = ToolResultExtractor.string("textPreview", from: pasted), !preview.isEmpty {
            return "→ Pasted \"\(self.truncate(preview, maxLength: 40))\""
        }
        return "→ Pasted"
    }
}
