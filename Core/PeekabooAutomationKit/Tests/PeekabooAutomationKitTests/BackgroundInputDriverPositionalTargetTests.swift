import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

/// Background positional clicks are delivered through accessibility actions (pid-routed mouse
/// events land at the window corner on modern macOS). These tests pin the element-chain walk
/// that picks the press/show-menu/focus target for a hit-tested point.
struct BackgroundInputDriverPositionalTargetTests {
    @Test
    @MainActor
    func `press target resolves from a pressable ancestor of the hit leaf`() {
        let point = CGPoint(x: 50, y: 50)
        let leaf = PositionalMockElement(role: "AXStaticText", frame: CGRect(x: 40, y: 40, width: 20, height: 20))
        let button = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 30, y: 30, width: 60, height: 40),
            actionNames: [AXActionNames.kAXPressAction])

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inChain: [leaf, button],
            at: point,
            button: MouseButton.left)

        #expect(resolved?.action == .press)
        #expect((resolved?.element as? PositionalMockElement) === button)
    }

    @Test
    @MainActor
    func `ancestors that do not contain the point are skipped`() {
        let point = CGPoint(x: 50, y: 50)
        let leaf = PositionalMockElement(role: "AXStaticText", frame: CGRect(x: 40, y: 40, width: 20, height: 20))
        let strayAncestor = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 500, y: 500, width: 40, height: 40),
            actionNames: [AXActionNames.kAXPressAction])

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inChain: [leaf, strayAncestor],
            at: point,
            button: MouseButton.left)

        #expect(resolved == nil)
    }

    @Test
    @MainActor
    func `disabled elements are not pressable`() {
        let point = CGPoint(x: 50, y: 50)
        let disabledButton = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 30, y: 30, width: 60, height: 40),
            actionNames: [AXActionNames.kAXPressAction],
            isEnabled: false)

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inChain: [disabledButton],
            at: point,
            button: MouseButton.left)

        #expect(resolved == nil)
    }

    @Test
    @MainActor
    func `left click on a text field falls back to focusing it`() {
        let point = CGPoint(x: 50, y: 50)
        let textField = PositionalMockElement(
            role: "AXTextField",
            frame: CGRect(x: 30, y: 30, width: 200, height: 30),
            isValueSettable: true,
            isFocusedSettable: true)

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inChain: [textField],
            at: point,
            button: MouseButton.left)

        #expect(resolved?.action == .focus)
        #expect((resolved?.element as? PositionalMockElement) === textField)
    }

    @Test
    @MainActor
    func `right click requires a show menu action and never focus-falls-back`() {
        let point = CGPoint(x: 50, y: 50)
        let textField = PositionalMockElement(
            role: "AXTextField",
            frame: CGRect(x: 30, y: 30, width: 200, height: 30),
            isValueSettable: true,
            isFocusedSettable: true)
        let menuHost = PositionalMockElement(
            role: "AXGroup",
            frame: CGRect(x: 0, y: 0, width: 400, height: 400),
            actionNames: [AXActionNames.kAXShowMenuAction])

        let withoutMenu = BackgroundInputDriver.positionalClickTarget(
            inChain: [textField],
            at: point,
            button: MouseButton.right)
        #expect(withoutMenu == nil)

        let withMenu = BackgroundInputDriver.positionalClickTarget(
            inChain: [textField, menuHost],
            at: point,
            button: MouseButton.right)
        #expect(withMenu?.action == .showMenu)
        #expect((withMenu?.element as? PositionalMockElement) === menuHost)
    }

    @Test
    @MainActor
    func `empty chain resolves to nothing`() {
        let resolved = BackgroundInputDriver.positionalClickTarget(
            inChain: [],
            at: CGPoint(x: 1, y: 1),
            button: MouseButton.left)
        #expect(resolved == nil)
    }

    @Test
    func `unactionable point error names the foreground escape hatch`() {
        let message = BackgroundInputDriver.noActionableElementMessage(
            at: CGPoint(x: 2396, y: 162),
            targetProcessIdentifier: 92941)
        #expect(message.contains("--foreground"))
        #expect(message.contains("(2396, 162)"))
        #expect(message.contains("92941"))
    }

    @Test
    func `background double and middle click messages point to foreground`() {
        #expect(BackgroundInputDriver.doubleClickUnsupportedMessage.contains("--foreground"))
        #expect(BackgroundInputDriver.middleClickUnsupportedMessage.contains("--foreground"))
    }
}

@MainActor
private final class PositionalMockElement: AutomationElementRepresenting, @unchecked Sendable {
    let name: String? = nil
    let label: String? = nil
    let roleDescription: String? = nil
    let identifier: String? = nil
    let role: String?
    let subrole: String?
    let frame: CGRect?
    let value: Any? = nil
    let stringValue: String? = nil
    let actionNames: [String]
    let isValueSettable: Bool
    let isFocusedSettable: Bool
    let isEnabled: Bool
    let isFocused = false
    let isOffscreen = false
    var anchorPoint: CGPoint? {
        self.frame.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    let automationChildren: [any AutomationElementRepresenting] = []
    var setFocusedValues: [Bool] = []

    init(
        role: String? = nil,
        subrole: String? = nil,
        frame: CGRect? = nil,
        actionNames: [String] = [],
        isValueSettable: Bool = false,
        isFocusedSettable: Bool = false,
        isEnabled: Bool = true)
    {
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.actionNames = actionNames
        self.isValueSettable = isValueSettable
        self.isFocusedSettable = isFocusedSettable
        self.isEnabled = isEnabled
    }

    func performAutomationAction(_ actionName: String) throws {
        guard self.actionNames.contains(actionName) else {
            throw AccessibilitySystemError(.actionUnsupported)
        }
    }

    func setAutomationValue(_ value: UIElementValue) throws {
        _ = value
    }

    func setAutomationFocused(_ focused: Bool) throws {
        self.setFocusedValues.append(focused)
    }

    func stringAttribute(_ name: String) -> String? {
        nil
    }

    func intAttribute(_ name: String) -> Int? {
        nil
    }
}
