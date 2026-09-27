import ApplicationServices
import AXorcist
import Foundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct MenuShortcutReaderTests {
    @Test
    func `missing modifiers never imply Command or press a later matching item`() {
        let missing = Self.item(modifiers: nil)
        let later = Self.item(modifiers: 0)
        let menu = Self.menu([missing, later])

        #expect(throws: ActionInputError.unsupported(.menuShortcutUnavailable)) {
            try ActionInputDriver().tryHotkeyForTesting(keys: ["cmd", "s"], menuBar: menu)
        }
        #expect(missing.performedActions.isEmpty)
        #expect(later.performedActions.isEmpty)
    }

    @Test
    func `explicit zero modifiers and duplicate first match retain existing order`() throws {
        let first = Self.item(modifiers: 0)
        let second = Self.item(modifiers: 0)

        _ = try ActionInputDriver().tryHotkeyForTesting(keys: ["cmd", "s"], menuBar: Self.menu([first, second]))

        #expect(first.performedActions == [kAXPressAction])
        #expect(second.performedActions.isEmpty)
    }

    @Test
    func `known disabled candidate does not require shortcut modifier metadata`() throws {
        let disabled = Self.item(modifiers: nil, isEnabled: false)
        let enabled = Self.item(modifiers: 0)

        _ = try ActionInputDriver().tryHotkeyForTesting(keys: ["cmd", "s"], menuBar: Self.menu([disabled, enabled]))

        #expect(disabled.performedActions.isEmpty)
        #expect(enabled.performedActions == [kAXPressAction])
    }

    @Test(arguments: [AXError.cannotComplete, .apiDisabled, .invalidUIElement])
    func `native read failures stop menu resolution before any fallback candidate`(_ error: AXError) {
        let fixture = NativeMenuFixture()
        fixture.set(kAXMenuItemCmdModifiersAttribute, error: error)
        #expect(throws: ActionInputDriver.classify(error)) {
            try fixture.driver.tryHotkeyForTesting(keys: ["cmd", "s"], menuBar: fixture.menuBar)
        }
        #expect(fixture.reads.contains(kAXMenuItemCmdModifiersAttribute))
    }

    @Test(arguments: [kAXEnabledAttribute, kAXMenuItemCmdModifiersAttribute])
    func `absent native eligibility metadata never becomes an actionable default`(_ attribute: String) {
        let fixture = NativeMenuFixture()
        fixture.set(attribute, error: .attributeUnsupported)
        let expected = attribute == kAXEnabledAttribute
            ? ActionInputError.unsupported(.attributeUnsupported)
            : ActionInputError.unsupported(.menuShortcutUnavailable)
        #expect(throws: expected) {
            try fixture.driver.tryHotkeyForTesting(keys: ["cmd", "s"], menuBar: fixture.menuBar)
        }
        #expect(fixture.reads.contains(attribute))
    }

    @Test
    func `malformed native metadata is not coerced into a valid shortcut`() {
        let fixture = NativeMenuFixture()
        fixture.set(kAXMenuItemCmdModifiersAttribute, value: kCFBooleanFalse)
        #expect(throws: ActionInputError.self) {
            try fixture.reader.modifiers(of: fixture.item)
        }
        fixture.set(kAXMenuItemCmdModifiersAttribute, value: NSNumber(value: 0.5))
        #expect(throws: ActionInputError.self) {
            try fixture.reader.modifiers(of: fixture.item)
        }
        fixture.set(kAXEnabledAttribute, value: NSNumber(value: 1))
        #expect(throws: ActionInputError.self) {
            try fixture.reader.isEnabled(fixture.item)
        }
    }

    @Test
    func `native menu leaf reads only AXChildren and distinguishes empty from failed`() throws {
        let fixture = NativeMenuFixture()
        #expect(try fixture.reader.children(of: fixture.item).isEmpty)
        #expect(fixture.reads == [kAXChildrenAttribute])

        fixture.set(kAXChildrenAttribute, error: .attributeUnsupported)
        #expect(try fixture.reader.children(of: fixture.item).isEmpty)
        fixture.set(kAXChildrenAttribute, error: .cannotComplete)
        #expect(throws: ActionInputError.targetUnavailable) {
            try fixture.reader.children(of: fixture.item)
        }
        fixture.set(kAXChildrenAttribute, value: ["not an AX element"] as CFArray)
        #expect(throws: ActionInputError.self) {
            try fixture.reader.children(of: fixture.item)
        }
        #expect(fixture.reads.allSatisfy { $0 == kAXChildrenAttribute })
    }

    @Test
    func `native unrelated shortcut avoids reading enabled state and child alternatives`() {
        let fixture = NativeMenuFixture()
        fixture.set(kAXMenuItemCmdCharAttribute, value: "x" as CFString)
        #expect(throws: ActionInputError.unsupported(.menuShortcutUnavailable)) {
            try fixture.driver.tryHotkeyForTesting(keys: ["cmd", "s"], menuBar: fixture.menuBar)
        }
        #expect(!fixture.reads.contains(kAXEnabledAttribute))
        #expect(!fixture.reads.contains(kAXMenuItemCmdModifiersAttribute))
        #expect(Set(fixture.reads) == [kAXChildrenAttribute, kAXRoleAttribute, kAXMenuItemCmdCharAttribute])
    }

    @Test
    func `existing node budget stops before an out of budget matching item`() {
        let skipped = (0..<600).map { _ in Self.item(modifiers: 0, character: "x") }
        let outOfBudget = Self.item(modifiers: 0)
        #expect(throws: ActionInputError.unsupported(.menuShortcutUnavailable)) {
            try ActionInputDriver().tryHotkeyForTesting(
                keys: ["cmd", "s"], menuBar: Self.menu(skipped + [outOfBudget]))
        }
        #expect(outOfBudget.performedActions.isEmpty)
    }

    private static func item(
        modifiers: Int?, character: String = "s", isEnabled: Bool = true) -> ActionInputMockAutomationElement
    {
        ActionInputMockAutomationElement(
            role: kAXMenuItemRole,
            actionNames: [kAXPressAction],
            isEnabled: isEnabled,
            stringAttributes: [kAXMenuItemCmdCharAttribute: character],
            intAttributes: modifiers.map { [kAXMenuItemCmdModifiersAttribute: $0] } ?? [:])
    }

    private static func menu(_ items: [ActionInputMockAutomationElement]) -> ActionInputMockAutomationElement {
        let menu = ActionInputMockAutomationElement(role: kAXMenuRole, children: items)
        let barItem = ActionInputMockAutomationElement(role: kAXMenuBarItemRole, children: [menu])
        return ActionInputMockAutomationElement(role: kAXMenuBarRole, children: [barItem])
    }
}

@MainActor
private final class NativeMenuFixture {
    private let handles = (1...4).map { AXUIElementCreateApplication(pid_t(9_000_000 + $0)) }
    private var attributes = [[String: MenuShortcutReader.AttributeRead]](repeating: [:], count: 4)
    private(set) var reads: [String] = []

    var menuBar: AutomationElement {
        AutomationElement(Element(self.handles[0]))
    }

    var item: AutomationElement {
        AutomationElement(Element(self.handles[3]))
    }

    var reader: MenuShortcutReader {
        MenuShortcutReader { element, attribute in
            self.reads.append(attribute)
            guard let index = self.handles.firstIndex(where: { CFEqual($0, element) }) else {
                return .init(error: .invalidUIElement, value: nil)
            }
            return self.attributes[index][attribute] ?? .init(error: .attributeUnsupported, value: nil)
        }
    }

    var driver: ActionInputDriver {
        ActionInputDriver(menuReader: self.reader)
    }

    init() {
        for (index, role) in [kAXMenuBarRole, kAXMenuBarItemRole, kAXMenuRole, kAXMenuItemRole].enumerated() {
            let children = index < 3 ? [self.handles[index + 1]] : []
            self.attributes[index] = [
                kAXRoleAttribute: .init(error: .success, value: role as CFString),
                kAXChildrenAttribute: .init(error: .success, value: children as CFArray),
            ]
        }
        self.set(kAXMenuItemCmdCharAttribute, value: "s" as CFString)
        self.set(kAXMenuItemCmdModifiersAttribute, value: NSNumber(value: 0))
        self.set(kAXEnabledAttribute, value: kCFBooleanTrue)
    }

    func set(_ attribute: String, error: AXError = .success, value: CFTypeRef? = nil) {
        self.attributes[3][attribute] = .init(error: error, value: value)
    }
}
