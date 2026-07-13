import AppKit
import ApplicationServices
import AXorcist
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ActionInputDriverTests {
    @Test
    func `classifies unsupported AX action as fallback-eligible`() {
        let error = ActionInputDriver.classify(AccessibilitySystemError(.actionUnsupported))

        #expect(error == .unsupported(.actionUnsupported))
    }

    @Test
    func `classifies unsupported AX attribute as fallback-eligible`() {
        let error = ActionInputDriver.classify(AccessibilitySystemError(.attributeUnsupported))

        #expect(error == .unsupported(.attributeUnsupported))
    }

    @Test
    func `classifies invalid AX element as stale element`() {
        let error = ActionInputDriver.classify(AccessibilitySystemError(.invalidUIElement))

        #expect(error == .staleElement)
    }

    @Test
    func `classifies disabled AX API as permission denied`() {
        let error = ActionInputDriver.classify(AccessibilitySystemError(.apiDisabled))

        #expect(error == .permissionDenied)
    }

    @Test
    func `menu hotkey chord normalizes command character shortcuts`() throws {
        let chord = try ActionInputDriver.menuHotkeyChordForTesting(["command", "shift", "S"])

        #expect(chord.key == "s")
        #expect(chord.modifiers == ["cmd", "shift"])
    }

    @Test
    func `menu hotkey chord supports punctuation shortcuts`() throws {
        let chord = try ActionInputDriver.menuHotkeyChordForTesting(["cmd", "comma"])

        #expect(chord.key == ",")
        #expect(chord.modifiers == ["cmd"])
    }

    @Test
    func `menu hotkey chord rejects non menu backed keys`() throws {
        do {
            _ = try ActionInputDriver.menuHotkeyChordForTesting(["cmd", "escape"])
            Issue.record("Expected escape to be unsupported for menu hotkey resolution")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.menuShortcutUnavailable))
        }
    }

    @Test
    func `menu item modifier bits map to normalized modifier names`() {
        let modifiers = ActionInputDriver.menuHotkeyModifiersForTesting((1 << 0) | (1 << 2))

        #expect(modifiers == ["cmd", "shift", "ctrl"])
    }

    @Test
    func `menu item no command bit suppresses implicit command modifier`() {
        let modifiers = ActionInputDriver.menuHotkeyModifiersForTesting((1 << 3) | (1 << 1))

        #expect(modifiers == ["alt"])
    }

    @Test
    func `set value rejects secure text fields even when settable`() {
        let reason = ActionInputDriver.setValueRejectionReasonForTesting(
            role: "AXSecureTextField",
            isValueSettable: true)

        #expect(reason == .secureValueNotAllowed)
    }

    @Test
    func `set value rejects secure text fields by subrole`() {
        let reason = ActionInputDriver.setValueRejectionReasonForTesting(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            isValueSettable: true)

        #expect(reason == .secureValueNotAllowed)
    }

    @Test
    func `set value rejects elements without settable values`() {
        let reason = ActionInputDriver.setValueRejectionReasonForTesting(
            role: "AXTextField",
            isValueSettable: false)

        #expect(reason == .valueNotSettable)
    }

    @Test
    func `scroll action unavailable becomes fallback eligible`() {
        #expect(ActionInputDriver.shouldContinueTryingScrollActionForTesting(after: .targetUnavailable))
        #expect(ActionInputDriver.scrollFallbackErrorForTesting(from: .targetUnavailable) ==
            .unsupported(.actionUnsupported))
    }

    @Test
    func `scroll action keeps stale and permission errors as hard failures`() {
        #expect(!ActionInputDriver.shouldContinueTryingScrollActionForTesting(after: .staleElement))
        #expect(!ActionInputDriver.shouldContinueTryingScrollActionForTesting(after: .permissionDenied))
        #expect(ActionInputDriver.scrollFallbackErrorForTesting(from: .staleElement) == .staleElement)
    }

    @MainActor
    @Test
    func `directional scroll ignores scroll to visible action`() {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollToVisible"])

        do {
            _ = try ActionInputDriver().tryScrollForTesting(element: element, direction: .down, pages: 1)
            Issue.record("Expected scroll-to-visible-only element to fall back")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.actionUnsupported))
            #expect(element.performedActions.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @MainActor
    @Test
    func `directional scroll performs page scroll action`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"])

        let result = try ActionInputDriver().tryScrollForTesting(element: element, direction: .down, pages: 1)

        #expect(result.actionName == "AXScrollDownByPage")
        #expect(element.performedActions == ["AXScrollDownByPage"])
    }

    @MainActor
    @Test
    func `directional scroll reports fallback page action that actually ran`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXPageDown"])

        let result = try ActionInputDriver().tryScrollForTesting(element: element, direction: .down, pages: 1)

        #expect(result.actionName == "AXPageDown")
        #expect(element.performedActions == ["AXPageDown"])
    }

    @Test
    func `action input errors have user-readable descriptions`() {
        let error = ActionInputError.unsupported(.secureValueNotAllowed)

        #expect(error.localizedDescription.contains("secure text fields"))
    }

    @Test
    func `only unselected no-op tab presses require synthetic fallback`() {
        #expect(ActionInputDriver.tabPressDidNotSelectForTesting(
            subrole: "AXTabButton",
            valueBefore: 0,
            valueAfter: 0))
        #expect(!ActionInputDriver.tabPressDidNotSelectForTesting(
            subrole: "AXTabButton",
            valueBefore: 0,
            valueAfter: 1))
        #expect(!ActionInputDriver.tabPressDidNotSelectForTesting(
            subrole: "AXTabButton",
            valueBefore: 1,
            valueAfter: 1))
        #expect(!ActionInputDriver.tabPressDidNotSelectForTesting(
            subrole: "AXRadioButton",
            valueBefore: 0,
            valueAfter: 0))
    }

    @Test
    func `unsupported action message includes advertised action names`() {
        let message = UIAutomationService.unsupportedActionMessage(
            actionName: "AXIncrement",
            target: "S1 slider: Volume",
            advertisedActions: ["AXPress", "AXShowMenu"])

        #expect(message.contains("AXIncrement"))
        #expect(message.contains("S1 slider: Volume"))
        #expect(message.contains("AXPress, AXShowMenu"))
    }

    @Test
    func `unsupported set value message includes target and reason`() {
        let message = UIAutomationService.unsupportedSetValueMessage(
            target: "elem_2 other: scroll area",
            reason: "Accessibility value is not settable")

        #expect(message.contains("elem_2 other: scroll area"))
        #expect(message.contains("Accessibility value is not settable"))
    }

    @MainActor
    @Test
    func `element actions reject missing explicit snapshot instead of live lookup`() async throws {
        let service = UIAutomationService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: RecordingActionInputDriver(),
            automationElementResolver: AutomationElementResolver())

        do {
            _ = try await service.setValue(target: "Delete", value: .string("yes"), snapshotId: "missing-snapshot")
            Issue.record("Expected missing explicit snapshot to fail")
        } catch let error as PeekabooError {
            if case .snapshotNotFound("missing-snapshot") = error {
                return
            }
            Issue.record("Expected snapshotNotFound('missing-snapshot'), got \(error)")
        }
    }

    @MainActor
    @Test
    func `element action facade normalizes stale action driver failures`() async throws {
        let detected = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 10, y: 10, width: 80, height: 24))
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [detected]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "test"))
        let service = UIAutomationService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: RecordingActionInputDriver(elementActionError: .staleElement),
            automationElementResolver: FixedActionAutomationElementResolver())

        do {
            _ = try await service.setValue(target: "B1", value: .string("hello"), snapshotId: "snapshot")
            Issue.record("Expected stale snapshot error from setValue")
        } catch let PeekabooError.snapshotStale(reason) {
            #expect(reason.contains("no longer available"))
        }

        do {
            _ = try await service.performAction(target: "B1", actionName: "AXPress", snapshotId: "snapshot")
            Issue.record("Expected stale snapshot error from performAction")
        } catch let PeekabooError.snapshotStale(reason) {
            #expect(reason.contains("no longer available"))
        }
    }

    @MainActor
    @Test
    func `mock element can exercise action click without live AX`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXButtonRole,
            frame: CGRect(x: 10, y: 20, width: 30, height: 40),
            actionNames: [AXActionNames.kAXPressAction])

        let result = try ActionInputDriver().tryClickForTesting(element: element)

        #expect(element.performedActions == [AXActionNames.kAXPressAction])
        #expect(result.anchorPoint == CGPoint(x: 25, y: 40))
        #expect(result.elementRole == AXRoleNames.kAXButtonRole)
    }

    @MainActor
    @Test
    func `right click target unavailable becomes fallback eligible`() async throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXButtonRole,
            actionNames: [AXActionNames.kAXShowMenuAction],
            actionErrors: [AXActionNames.kAXShowMenuAction: AccessibilitySystemError(.cannotComplete)])

        do {
            _ = try await ActionInputDriver().tryRightClick(element: element)
            Issue.record("Expected right-click action to request synthetic fallback")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.actionUnsupported))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @MainActor
    @Test
    func `right click performs show menu action`() async throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXButtonRole,
            actionNames: [AXActionNames.kAXShowMenuAction])

        let result = try await ActionInputDriver().tryRightClick(element: element)

        #expect(element.performedActions == [AXActionNames.kAXShowMenuAction])
        #expect(result.actionName == AXActionNames.kAXShowMenuAction)
        #expect(result.elementRole == AXRoleNames.kAXButtonRole)
    }

    @MainActor
    @Test
    func `text field action click focuses when press is unavailable`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXTextFieldRole,
            frame: CGRect(x: 10, y: 20, width: 30, height: 40),
            isValueSettable: true,
            isFocusedSettable: true)

        let result = try ActionInputDriver().tryClickForTesting(element: element)

        #expect(element.performedActions.isEmpty)
        #expect(element.setFocusedValues == [true])
        #expect(result.actionName == AXAttributeNames.kAXFocusedAttribute)
        #expect(result.anchorPoint == CGPoint(x: 25, y: 40))
        #expect(result.elementRole == AXRoleNames.kAXTextFieldRole)
    }

    @MainActor
    @Test
    func `focus click target classification is limited to focusable inputs`() {
        #expect(ActionInputDriver.canFocusForClickForTesting(
            role: AXRoleNames.kAXTextFieldRole,
            isValueSettable: true,
            isFocusedSettable: true))
        #expect(!ActionInputDriver.canFocusForClickForTesting(
            role: AXRoleNames.kAXButtonRole,
            isValueSettable: false,
            isFocusedSettable: true))
        #expect(!ActionInputDriver.canFocusForClickForTesting(
            role: AXRoleNames.kAXTextFieldRole,
            isValueSettable: true,
            isFocusedSettable: false))
    }

    @MainActor
    @Test
    func `mock element can exercise direct value setter without live AX`() throws {
        let element = MockAutomationElement(
            role: AXRoleNames.kAXTextFieldRole,
            isValueSettable: true)

        let result = try ActionInputDriver().trySetValueForTesting(element: element, value: .string("hello"))

        #expect(element.setValues == [.string("hello")])
        #expect(result.actionName == AXActionNames.kAXSetValueAction)
    }

    @MainActor
    @Test
    func `mock menu tree can exercise hotkey menu resolution without live AX`() throws {
        let saveItem = MockAutomationElement(
            role: AXRoleNames.kAXMenuItemRole,
            actionNames: [AXActionNames.kAXPressAction],
            stringAttributes: ["AXMenuItemCmdChar": "s"],
            intAttributes: ["AXMenuItemCmdModifiers": 1 << 0])
        let fileMenu = MockAutomationElement(role: AXRoleNames.kAXMenuRole, children: [saveItem])
        let fileMenuBarItem = MockAutomationElement(role: AXRoleNames.kAXMenuBarItemRole, children: [fileMenu])
        let menuBar = MockAutomationElement(role: AXRoleNames.kAXMenuBarRole, children: [fileMenuBarItem])

        let result = try ActionInputDriver().tryHotkeyForTesting(keys: ["cmd", "shift", "s"], menuBar: menuBar)

        #expect(saveItem.performedActions == [AXActionNames.kAXPressAction])
        #expect(result.elementRole == AXRoleNames.kAXMenuItemRole)
    }

    @MainActor
    @Test
    func `mock element unsupported action classifies as fallback eligible`() {
        let element = MockAutomationElement(role: AXRoleNames.kAXButtonRole)

        do {
            _ = try ActionInputDriver().tryClickForTesting(element: element)
            Issue.record("Expected unsupported mock action to throw")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.actionUnsupported))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@MainActor
private final class RecordingActionInputDriver: ActionInputDriving {
    private let elementActionError: ActionInputError?

    init(elementActionError: ActionInputError? = nil) {
        self.elementActionError = elementActionError
    }

    func tryClick(element _: AutomationElement) throws -> ActionInputResult {
        Issue.record("Action driver should not be called")
        return ActionInputResult()
    }

    func tryRightClick(element _: any AutomationElementRepresenting) async throws -> ActionInputResult {
        Issue.record("Action driver should not be called")
        return ActionInputResult()
    }

    func tryScroll(
        element _: AutomationElement,
        direction _: PeekabooFoundation.ScrollDirection,
        pages _: Int) throws -> ActionInputResult
    {
        Issue.record("Action driver should not be called")
        return ActionInputResult()
    }

    func trySetText(element _: AutomationElement, text _: String, replace _: Bool) throws -> ActionInputResult {
        Issue.record("Action driver should not be called")
        return ActionInputResult()
    }

    func tryHotkey(application _: NSRunningApplication, keys _: [String]) throws -> ActionInputResult {
        Issue.record("Action driver should not be called")
        return ActionInputResult()
    }

    func trySetValue(element _: AutomationElement, value _: UIElementValue) throws -> ActionInputResult {
        if let elementActionError {
            throw elementActionError
        }
        Issue.record("Action driver should not be called")
        return ActionInputResult()
    }

    func tryPerformAction(element _: AutomationElement, actionName _: String) throws -> ActionInputResult {
        if let elementActionError {
            throw elementActionError
        }
        Issue.record("Action driver should not be called")
        return ActionInputResult()
    }
}

@MainActor
private final class FixedActionAutomationElementResolver: AutomationElementResolving {
    private let element = AutomationElement(Element(AXUIElementCreateApplication(getpid())))

    func resolve(detectedElement _: DetectedElement, windowContext _: WindowContext?) -> AutomationElement? {
        self.element
    }

    func resolve(
        detectedElement _: DetectedElement,
        windowContext _: WindowContext?,
        targetProcessIdentifier _: pid_t?) -> AutomationElement?
    {
        self.element
    }

    func resolve(query _: String, windowContext _: WindowContext?, requireTextInput _: Bool) -> AutomationElement? {
        self.element
    }

    func resolve(
        query _: String,
        windowContext _: WindowContext?,
        targetProcessIdentifier _: pid_t?,
        requireTextInput _: Bool) -> AutomationElement?
    {
        self.element
    }
}

@MainActor
private final class MockAutomationElement: AutomationElementRepresenting, @unchecked Sendable {
    let name: String?
    let label: String?
    let roleDescription: String?
    let identifier: String?
    let role: String?
    let subrole: String?
    let frame: CGRect?
    var value: Any?
    var stringValue: String? {
        self.value as? String
    }

    let actionNames: [String]
    let isValueSettable: Bool
    let isFocusedSettable: Bool
    let isEnabled: Bool
    let isFocused: Bool
    let isOffscreen: Bool
    var anchorPoint: CGPoint? {
        self.frame.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    private let children: [MockAutomationElement]
    private let stringAttributes: [String: String]
    private let intAttributes: [String: Int]
    private let actionErrors: [String: any Error]
    var performedActions: [String] = []
    var setValues: [UIElementValue] = []
    var setFocusedValues: [Bool] = []

    var automationChildren: [any AutomationElementRepresenting] {
        self.children
    }

    init(
        name: String? = nil,
        label: String? = nil,
        roleDescription: String? = nil,
        identifier: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        frame: CGRect? = nil,
        value: Any? = nil,
        actionNames: [String] = [],
        isValueSettable: Bool = false,
        isFocusedSettable: Bool = false,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        isOffscreen: Bool = false,
        children: [MockAutomationElement] = [],
        stringAttributes: [String: String] = [:],
        intAttributes: [String: Int] = [:],
        actionErrors: [String: any Error] = [:])
    {
        self.name = name
        self.label = label
        self.roleDescription = roleDescription
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.value = value
        self.actionNames = actionNames
        self.isValueSettable = isValueSettable
        self.isFocusedSettable = isFocusedSettable
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.isOffscreen = isOffscreen
        self.children = children
        self.stringAttributes = stringAttributes
        self.intAttributes = intAttributes
        self.actionErrors = actionErrors
    }

    func performAutomationAction(_ actionName: String) throws {
        if let error = self.actionErrors[actionName] {
            throw error
        }
        guard self.actionNames.contains(actionName) else {
            throw AccessibilitySystemError(.actionUnsupported)
        }
        self.performedActions.append(actionName)
    }

    func setAutomationValue(_ value: UIElementValue) throws {
        guard self.isValueSettable else {
            throw AccessibilitySystemError(.attributeUnsupported)
        }
        self.value = value.displayString
        self.setValues.append(value)
    }

    func setAutomationFocused(_ focused: Bool) throws {
        guard self.isFocusedSettable else {
            throw AccessibilitySystemError(.attributeUnsupported)
        }
        self.setFocusedValues.append(focused)
    }

    func stringAttribute(_ name: String) -> String? {
        self.stringAttributes[name]
    }

    func intAttribute(_ name: String) -> Int? {
        self.intAttributes[name]
    }
}
