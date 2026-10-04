struct InspectUIElementTextFormatter {
    static let maxRenderedElements = 120
    private static let maxFieldLength = 240
    static let interactionHint = """
    Use element IDs with click, type, and other interaction commands.
    If text looks incomplete, use `see` for a screenshot-based observation.
    """

    static func section(_ elements: [UIElementSummary]) -> [String] {
        guard !elements.isEmpty else {
            return ["No accessible UI elements found. Try `see` for screenshot-based detection."]
        }
        let renderedElements = Array(elements.prefix(Self.maxRenderedElements))
        let omittedCount = elements.count - renderedElements.count
        let elementsByRole = Dictionary(grouping: renderedElements, by: { $0.role })
        var lines = ["UI Elements:"]
        for (role, roleElements) in elementsByRole.sorted(by: { $0.key < $1.key }) {
            let actionableCount = roleElements.count(where: \.is_actionable)
            lines.append("")
            lines.append("\(role) (\(roleElements.count) found, \(actionableCount) actionable):")
            lines.append(contentsOf: roleElements.map(Self.describe))
        }
        if omittedCount > 0 {
            lines.append("")
            lines.append(
                "\(omittedCount) additional elements omitted from text output. " +
                    "Use `see` or a narrower app_target if you need more context.")
        }
        return lines
    }

    private static func describe(_ element: UIElementSummary) -> String {
        var parts = ["  \(element.id)"]
        if let label = self.clipped(element.label) {
            parts.append("\"\(label)\"")
        }
        let sizeText = "size \(Int(element.bounds.width))x\(Int(element.bounds.height))"
        parts.append("at (\(Int(element.bounds.x)), \(Int(element.bounds.y))) \(sizeText)")
        if let value = self.clipped(element.value) {
            parts.append("value: \"\(value)\"")
        }
        if let desc = self.clipped(element.description) {
            parts.append("desc: \"\(desc)\"")
        }
        if let help = self.clipped(element.help) {
            parts.append("help: \"\(help)\"")
        }
        if let shortcut = self.clipped(element.keyboard_shortcut) {
            parts.append("shortcut: \(shortcut)")
        }
        if let identifier = self.clipped(element.identifier) {
            parts.append("identifier: \(identifier)")
        }
        if let isValueSettable = element.is_value_settable {
            parts.append(isValueSettable ? "[value settable]" : "[value read-only]")
        }
        if element.is_enabled == false {
            parts.append("[not actionable]")
        }
        return parts.joined(separator: " - ")
    }

    private static func clipped(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.count > Self.maxFieldLength else { return value }
        let index = value.index(value.startIndex, offsetBy: Self.maxFieldLength)
        return String(value[..<index]) + "..."
    }
}
