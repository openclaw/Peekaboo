import AppKit
import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

/// Testable abstraction over a UI accessibility element.
///
/// The production implementation wraps AXorcist's `Element`; tests can provide an in-memory tree with the same
/// observable attributes and action behavior.
@MainActor
protocol AutomationElementRepresenting: Sendable {
    var name: String? { get }
    var label: String? { get }
    var roleDescription: String? { get }
    var identifier: String? { get }
    var role: String? { get }
    var subrole: String? { get }
    var frame: CGRect? { get }
    var value: Any? { get }
    var stringValue: String? { get }
    var actionNames: [String] { get }
    var isValueSettable: Bool { get }
    var isFocusedSettable: Bool { get }
    var isEnabled: Bool { get }
    var isFocused: Bool { get }
    var isOffscreen: Bool { get }
    var anchorPoint: CGPoint? { get }
    var automationChildren: [any AutomationElementRepresenting] { get }

    func performAutomationAction(_ actionName: String) throws
    func setAutomationValue(_ value: UIElementValue) throws
    func setAutomationFocused(_ focused: Bool) throws
    func stringAttribute(_ name: String) -> String?
    func intAttribute(_ name: String) -> Int?
}

/// Typed wrapper around an accessibility element used by action-first input paths.
struct AutomationElement: AutomationElementRepresenting {
    let element: Element

    init(_ element: Element) {
        self.element = element
    }

    @MainActor
    var name: String? {
        self.element.title()
            ?? self.element.label()
            ?? self.element.descriptionText()
            ?? self.element.roleDescription()
            ?? self.stringValue
    }

    @MainActor
    var label: String? {
        self.element.label()
    }

    @MainActor
    var roleDescription: String? {
        self.element.roleDescription()
    }

    @MainActor
    var identifier: String? {
        self.element.identifier()
    }

    @MainActor
    var role: String? {
        self.element.role()
    }

    @MainActor
    var subrole: String? {
        self.element.subrole()
    }

    @MainActor
    var frame: CGRect? {
        self.element.frame()
    }

    @MainActor
    var value: Any? {
        self.element.value()
    }

    @MainActor
    var stringValue: String? {
        self.value as? String
    }

    @MainActor
    var actionNames: [String] {
        self.element.supportedActions() ?? []
    }

    @MainActor
    var isValueSettable: Bool {
        self.element.isAttributeSettable(named: AXAttributeNames.kAXValueAttribute)
    }

    @MainActor
    var isFocusedSettable: Bool {
        self.element.isAttributeSettable(named: AXAttributeNames.kAXFocusedAttribute)
    }

    @MainActor
    var isEnabled: Bool {
        self.element.isEnabled() ?? true
    }

    @MainActor
    var isFocused: Bool {
        self.element.isFocused() ?? false
    }

    @MainActor
    var isOffscreen: Bool {
        guard let frame else { return false }
        let appKitFrame = GlobalScreenCoordinateGeometry.appKitRect(
            fromGlobalDisplay: frame,
            primaryScreenFrame: NSScreen.screens.first?.frame)
        let visibleFrame = NSScreen.screens
            .map(\.visibleFrame)
            .reduce(CGRect.null) { partial, screenFrame in
                partial.isNull ? screenFrame : partial.union(screenFrame)
            }
        guard !visibleFrame.isNull else { return false }
        return appKitFrame.intersection(visibleFrame).isNull
    }

    @MainActor
    var parent: AutomationElement? {
        self.element.parent().map(AutomationElement.init)
    }

    @MainActor
    var children: [AutomationElement] {
        (self.element.children() ?? []).map(AutomationElement.init)
    }

    @MainActor
    var anchorPoint: CGPoint? {
        self.frame.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    @MainActor
    var automationChildren: [any AutomationElementRepresenting] {
        self.children
    }

    @MainActor
    func performAutomationAction(_ actionName: String) throws {
        _ = try self.element.performAction(actionName)
    }

    @MainActor
    func setAutomationValue(_ value: UIElementValue) throws {
        let error = AXUIElementSetAttributeValue(
            self.element.underlyingElement,
            AXAttributeNames.kAXValueAttribute as CFString,
            value.accessibilityValue as CFTypeRef)
        guard error == .success else {
            throw AccessibilitySystemError(error)
        }
    }

    @MainActor
    func setAutomationFocused(_ focused: Bool) throws {
        let error = AXUIElementSetAttributeValue(
            self.element.underlyingElement,
            AXAttributeNames.kAXFocusedAttribute as CFString,
            (focused ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
        guard error == .success else {
            throw AccessibilitySystemError(error)
        }
    }

    @MainActor
    func stringAttribute(_ name: String) -> String? {
        self.element.attribute(Attribute<String>(name))
    }

    @MainActor
    func intAttribute(_ name: String) -> Int? {
        self.element.attribute(Attribute<Int>(name))
    }
}
