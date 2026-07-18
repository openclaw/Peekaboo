import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

/// Background positional clicks are delivered through accessibility actions (pid-routed mouse
/// events land at the window corner on modern macOS). These tests pin the candidate resolution
/// that picks the press/show-menu/focus target for a hit-tested point.
struct BackgroundInputDriverPositionalTargetTests {
    @Test
    @MainActor
    func `pressable hit-test element at depth 0 is pressed even when the actions attribute is empty`() {
        // Regression for the live failure: `AXUIElementCopyElementAtPosition` returns the SwiftUI
        // AXButton directly, but its `AXActionNames` *attribute* read is unsupported, so
        // `actionNames` is empty. Resolution must gate on `supportsAction` (the real actions API),
        // not on the empty `actionNames` list, and press the depth-0 hit.
        let point = CGPoint(x: 2396, y: 162)
        let button = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 2348.5, y: 150.5, width: 95, height: 24),
            supportedActions: [AXActionNames.kAXPressAction],
            advertisedActionNames: []) // AXActionNames attribute read returns nothing.

        #expect(button.actionNames.isEmpty)
        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [button],
            at: point,
            button: MouseButton.left)

        #expect(resolved?.action == .press)
        #expect((resolved?.element as? PositionalMockElement) === button)
    }

    @Test
    @MainActor
    func `pressable descendant is preferred when the hit-test container is not pressable`() {
        // SwiftUI can hit-test to a container whose pressable button is nested inside it. The
        // candidate list is ordered hit -> descendants -> ancestors, so the descendant wins.
        let point = CGPoint(x: 50, y: 50)
        let container = PositionalMockElement(
            role: "AXGroup",
            frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let descendantButton = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 30, y: 30, width: 60, height: 40),
            supportedActions: [AXActionNames.kAXPressAction])

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [container, descendantButton],
            at: point,
            button: MouseButton.left)

        #expect(resolved?.action == .press)
        #expect((resolved?.element as? PositionalMockElement) === descendantButton)
    }

    @Test
    @MainActor
    func `press target resolves from a pressable ancestor of the hit leaf`() {
        let point = CGPoint(x: 50, y: 50)
        let leaf = PositionalMockElement(role: "AXStaticText", frame: CGRect(x: 40, y: 40, width: 20, height: 20))
        let button = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 30, y: 30, width: 60, height: 40),
            supportedActions: [AXActionNames.kAXPressAction])

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [leaf, button],
            at: point,
            button: MouseButton.left)

        #expect(resolved?.action == .press)
        #expect((resolved?.element as? PositionalMockElement) === button)
    }

    @Test
    @MainActor
    func `the authoritative hit-test element is trusted even when its frame excludes the point`() {
        // Coordinate-space quirks must not veto the element macOS resolved for the point: the
        // depth-0 hit is pressed regardless of its reported frame.
        let point = CGPoint(x: 50, y: 50)
        let hit = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 900, y: 900, width: 10, height: 10),
            supportedActions: [AXActionNames.kAXPressAction])

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [hit],
            at: point,
            button: MouseButton.left)

        #expect(resolved?.action == .press)
        #expect((resolved?.element as? PositionalMockElement) === hit)
    }

    @Test
    @MainActor
    func `non-hit candidates that do not contain the point are skipped`() {
        let point = CGPoint(x: 50, y: 50)
        let leaf = PositionalMockElement(role: "AXStaticText", frame: CGRect(x: 40, y: 40, width: 20, height: 20))
        let strayAncestor = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 500, y: 500, width: 40, height: 40),
            supportedActions: [AXActionNames.kAXPressAction])

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [leaf, strayAncestor],
            at: point,
            button: MouseButton.left)

        #expect(resolved == nil)
    }

    @Test
    @MainActor
    func `non-hit pressable candidates with unknown frames are skipped`() {
        // Regression for Chrome web content: the hit is a non-pressable AXGroup, while traversal
        // can surface unrelated pressable descendants whose frames fail to decode. A missing frame
        // cannot prove that the descendant is under the click point.
        let point = CGPoint(x: 1117, y: 678)
        let webContainer = PositionalMockElement(
            role: "AXGroup",
            frame: CGRect(x: 773, y: 263, width: 1136, height: 785))
        let unrelatedButton = PositionalMockElement(
            role: "AXButton",
            supportedActions: [AXActionNames.kAXPressAction])

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [webContainer, unrelatedButton],
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
            supportedActions: [AXActionNames.kAXPressAction],
            isEnabled: false)

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [disabledButton],
            at: point,
            button: MouseButton.left)

        #expect(resolved == nil)
    }

    @Test
    @MainActor
    func `generic web containers are rejected even when they advertise press`() {
        let point = CGPoint(x: 1117, y: 678)
        for role in ["AXWebArea", "AXGroup", "AXRadioGroup"] {
            let container = PositionalMockElement(
                role: role,
                frame: CGRect(x: 1000, y: 500, width: 500, height: 500),
                supportedActions: [AXActionNames.kAXPressAction])

            let resolved = BackgroundInputDriver.positionalClickTarget(
                inCandidates: [container],
                at: point,
                button: MouseButton.left)

            #expect(resolved == nil, "\(role) must not produce a false-success background press")
        }
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
            inCandidates: [textField],
            at: point,
            button: MouseButton.left)

        #expect(resolved?.action == .focus)
        #expect((resolved?.element as? PositionalMockElement) === textField)
    }

    @Test
    @MainActor
    func `value settable web group does not masquerade as a focused click`() {
        // Chromium exposes full-page AXGroup containers as value/focus-settable. Setting focus on
        // that container returns success but delivers no click.
        let point = CGPoint(x: 1117, y: 678)
        let webContainer = PositionalMockElement(
            role: "AXGroup",
            frame: CGRect(x: 773, y: 139, width: 1151, height: 909),
            isValueSettable: true,
            isFocusedSettable: true)

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [webContainer],
            at: point,
            button: MouseButton.left)

        #expect(resolved == nil)
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
            supportedActions: [AXActionNames.kAXShowMenuAction])

        let withoutMenu = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [textField],
            at: point,
            button: MouseButton.right)
        #expect(withoutMenu == nil)

        let withMenu = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [textField, menuHost],
            at: point,
            button: MouseButton.right)
        #expect(withMenu?.action == .showMenu)
        #expect((withMenu?.element as? PositionalMockElement) === menuHost)
    }

    @Test
    @MainActor
    func `empty candidate list resolves to nothing`() {
        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [],
            at: CGPoint(x: 1, y: 1),
            button: MouseButton.left)
        #expect(resolved == nil)
    }

    @Test
    func `unactionable point error names the foreground escape hatch and reads as point-specific`() {
        let message = BackgroundInputDriver.noActionableElementMessage(
            at: CGPoint(x: 2396, y: 162),
            targetProcessIdentifier: 92941)
        #expect(message.contains("--foreground"))
        #expect(message.contains("--input-strategy synthOnly"))
        #expect(message.contains("(2396, 162)"))
        #expect(message.contains("92941"))
        // The message must describe the genuine "nothing pressable here" case, not claim that
        // positional background clicking is impossible.
        #expect(message.contains("pressable"))
        #expect(!message.lowercased().contains("cannot be routed"))
    }

    @Test
    func `background double and middle click messages point to foreground`() {
        #expect(BackgroundInputDriver.doubleClickUnsupportedMessage.contains("--foreground"))
        #expect(BackgroundInputDriver.middleClickUnsupportedMessage.contains("--foreground"))
    }

    @Test
    func `timed out press is a failure because delivery is unverified`() {
        #expect(throws: (any Error).self) {
            try BackgroundInputDriver.validateDetachedActionOutcome(
                .stillRunning,
                actionName: "AXPress")
        }
        #expect(BackgroundInputDriver.unverifiedPressMessage.contains("synthOnly"))
    }

    @Test
    func `timed out show menu remains delivered`() throws {
        try BackgroundInputDriver.validateDetachedActionOutcome(
            .stillRunning,
            actionName: "AXShowMenu")
    }

    @Test
    func `occluded window message names the pinned window and the escape hatches`() {
        let message = BackgroundInputDriver.occludedWindowMessage(at: CGPoint(x: 2396, y: 162), targetWindowID: 3279)
        #expect(message.contains("3279"))
        #expect(message.contains("(2396, 162)"))
        #expect(message.contains("--foreground"))
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

    /// Actions reported by the real `AXUIElementCopyActionNames` API in production. Kept separate
    /// from `actionNames` (the attribute read) so tests can model the SwiftUI case where the
    /// attribute read is empty but the actions API reports `AXPress`.
    private let supportedActions: Set<String>

    init(
        role: String? = nil,
        subrole: String? = nil,
        frame: CGRect? = nil,
        supportedActions: Set<String> = [],
        advertisedActionNames: [String]? = nil,
        isValueSettable: Bool = false,
        isFocusedSettable: Bool = false,
        isEnabled: Bool = true)
    {
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.supportedActions = supportedActions
        // Default: the attribute read agrees with the actions API. Pass an explicit value (e.g. [])
        // to model the attribute read diverging from the actions API.
        self.actionNames = advertisedActionNames ?? Array(supportedActions)
        self.isValueSettable = isValueSettable
        self.isFocusedSettable = isFocusedSettable
        self.isEnabled = isEnabled
    }

    func supportsAction(_ actionName: String) -> Bool {
        self.supportedActions.contains(actionName)
    }

    func performAutomationAction(_ actionName: String) throws {
        guard self.supportedActions.contains(actionName) else {
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
