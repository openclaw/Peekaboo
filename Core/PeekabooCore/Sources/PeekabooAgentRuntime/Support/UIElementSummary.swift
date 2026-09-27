import CoreGraphics
import Foundation
import PeekabooAutomationKit

/// Structured row of an observed element table.
///
/// This is the wire shape of `ui_elements[]` in `peekaboo see --json` and of the opt-in
/// `_meta.ui_elements` table on the MCP `see` and `inspect_ui` tools, so both surfaces stay in lockstep.
public struct UIElementSummary: Codable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let ax_role: String?
    public let title: String?
    public let label: String?
    public let value: String?
    public let description: String?
    public let role_description: String?
    public let help: String?
    public let identifier: String?
    public let confidence: Double?
    public let bounds: UIElementBounds
    public let is_actionable: Bool
    public let is_enabled: Bool?
    public let is_selected: Bool?
    public let is_value_settable: Bool?
    public let keyboard_shortcut: String?
    public let selected_text_range: TextSelectionRange?

    public init(
        id: String,
        role: String,
        ax_role: String?,
        title: String?,
        label: String?,
        value: String?,
        description: String?,
        role_description: String?,
        help: String?,
        identifier: String?,
        confidence: Double?,
        bounds: UIElementBounds,
        is_actionable: Bool,
        is_enabled: Bool?,
        is_selected: Bool?,
        is_value_settable: Bool?,
        keyboard_shortcut: String?,
        selected_text_range: TextSelectionRange? = nil)
    {
        self.id = id
        self.role = role
        self.ax_role = ax_role
        self.title = title
        self.label = label
        self.value = value
        self.description = description
        self.role_description = role_description
        self.help = help
        self.identifier = identifier
        self.confidence = confidence
        self.bounds = bounds
        self.is_actionable = is_actionable
        self.is_enabled = is_enabled
        self.is_selected = is_selected
        self.is_value_settable = is_value_settable
        self.keyboard_shortcut = keyboard_shortcut
        self.selected_text_range = selected_text_range
    }

    /// Projects a detected element into its table row.
    ///
    /// `mutationTargetingAvailable` is false for application-partial observations; those rows are read-only
    /// context, so they make no actionable or value-settable claims.
    public init(_ element: DetectedElement, mutationTargetingAvailable: Bool) {
        self.init(
            id: element.id,
            role: element.type.rawValue,
            ax_role: element.attributes["role"],
            title: element.attributes["title"],
            label: element.label,
            value: element.value,
            description: element.attributes["description"],
            role_description: element.attributes["roleDescription"],
            help: element.attributes["help"],
            identifier: element.attributes["identifier"],
            confidence: element.attributes["confidence"].flatMap(Double.init),
            bounds: UIElementBounds(element.bounds),
            is_actionable: mutationTargetingAvailable && element.isActionable,
            is_enabled: element.knownIsEnabled,
            is_selected: element.isSelected,
            is_value_settable: mutationTargetingAvailable ? element.isValueSettable : nil,
            keyboard_shortcut: element.attributes["keyboardShortcut"],
            selected_text_range: mutationTargetingAvailable ? element.selectedTextRange : nil)
    }
}

public struct UIElementBounds: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }
}

enum ObservedTextSelectionSummary {
    static func lines(for elements: [DetectedElement]) -> [String] {
        elements.compactMap { element in
            element.selectedTextRange.map {
                "Text selection \(element.id): UTF-16 location \($0.location), length \($0.length)"
            }
        }
    }
}
