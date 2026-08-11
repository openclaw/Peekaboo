import Foundation
import PeekabooAutomation

struct SeeElementTextFormatter {
    static func describe(_ element: UIElement) -> String {
        var parts = ["  \(element.id)"]
        if let label = self.primaryLabel(for: element) {
            parts.append("\"\(label)\"")
        }
        let sizeText = "size \(Int(element.frame.width))×\(Int(element.frame.height))"
        parts
            .append(
                "at (\(Int(element.frame.origin.x)), \(Int(element.frame.origin.y))) \(sizeText)")
        if let value = element.value, element.title != nil || element.label != nil {
            parts.append("value: \"\(value)\"")
        }
        if let desc = element.description, !desc.isEmpty {
            parts.append("desc: \"\(desc)\"")
        }
        if let help = element.help, !help.isEmpty {
            parts.append("help: \"\(help)\"")
        }
        if let shortcut = element.keyboardShortcut, !shortcut.isEmpty {
            parts.append("shortcut: \(shortcut)")
        }
        if let identifier = element.identifier, !identifier.isEmpty {
            parts.append("identifier: \(identifier)")
        }
        if let confidence = element.confidence {
            parts.append(String(format: "confidence: %.0f%%", confidence * 100))
        }
        if let isValueSettable = element.isValueSettable {
            parts.append(isValueSettable ? "[value settable]" : "[value read-only]")
        }
        if !element.isActionable {
            parts.append("[not actionable]")
        }
        return parts.joined(separator: " - ")
    }

    static func primaryLabel(for element: UIElement) -> String? {
        if let title = element.title {
            return title
        }
        if let label = element.label {
            return label
        }
        if let value = element.value {
            return "value: \(value)"
        }
        return nil
    }
}
