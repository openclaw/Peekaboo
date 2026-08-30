import AppKit
import ApplicationServices
import AXorcist
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

@MainActor
final class PhantomSuccessAutomationElement: AutomationElementRepresenting, @unchecked Sendable {
    let name: String? = nil
    let label: String? = nil
    let roleDescription: String? = nil
    let identifier: String? = nil
    let role: String?
    let subrole: String? = nil
    let frame: CGRect? = nil
    let value: Any? = nil
    let stringValue: String? = nil
    let actionNames: [String] = []
    let isValueSettable = false
    let isFocusedSettable = false
    let isEnabled = true
    let isFocused = false
    let isOffscreen = false
    let anchorPoint: CGPoint? = nil
    let automationChildren: [any AutomationElementRepresenting] = []
    var performedActions: [String] = []

    init(role: String?) {
        self.role = role
    }

    func performAutomationAction(_ actionName: String) throws {
        self.performedActions.append(actionName)
    }

    func setAutomationValue(_: UIElementValue) throws {}

    func setAutomationFocused(_: Bool) throws {}

    func stringAttribute(_: String) -> String? {
        nil
    }

    func intAttribute(_: String) -> Int? {
        nil
    }
}

@MainActor
final class RecordingActionInputDriver: ActionInputDriving {
    private let elementActionError: ActionInputError?
    private let allowsElementActions: Bool
    private(set) var clickCallCount = 0
    private(set) var setValueCallCount = 0
    private(set) var performActionCallCount = 0

    init(
        elementActionError: ActionInputError? = nil,
        allowsElementActions: Bool = false)
    {
        self.elementActionError = elementActionError
        self.allowsElementActions = allowsElementActions
    }

    func tryClick(element _: AutomationElement) throws -> UIInputExecutionResult.Action {
        self.clickCallCount += 1
        Issue.record("Action driver should not be called")
        return UIInputExecutionResult.Action(outcome: .confirmedNoChange())
    }

    func tryRightClick(element _: any AutomationElementRepresenting) async throws -> UIInputExecutionResult.Action {
        Issue.record("Action driver should not be called")
        return UIInputExecutionResult.Action(outcome: .confirmedNoChange())
    }

    func tryScroll(
        element _: AutomationElement,
        direction _: PeekabooFoundation.ScrollDirection,
        pages _: Int) throws -> UIInputExecutionResult.Action
    {
        Issue.record("Action driver should not be called")
        return UIInputExecutionResult.Action(outcome: .confirmedNoChange())
    }

    func trySetText(element _: AutomationElement, text _: String, replace _: Bool) throws
    -> UIInputExecutionResult.Action {
        Issue.record("Action driver should not be called")
        return UIInputExecutionResult.Action(outcome: .confirmedNoChange())
    }

    func tryHotkey(application _: NSRunningApplication, keys _: [String]) throws
    -> UIInputExecutionResult.Action {
        Issue.record("Action driver should not be called")
        return UIInputExecutionResult.Action(outcome: .confirmedNoChange())
    }

    func trySetValue(element _: AutomationElement, value _: UIElementValue) throws
    -> UIInputExecutionResult.Action {
        self.setValueCallCount += 1
        if let elementActionError {
            throw elementActionError
        }
        if self.allowsElementActions {
            return UIInputExecutionResult.Action(
                outcome: .confirmedChange(
                    delivery: .init(mechanism: .accessibilityValue, mode: .background)),
                actionName: AXActionNames.kAXSetValueAction)
        }
        Issue.record("Action driver should not be called")
        return UIInputExecutionResult.Action(outcome: .confirmedNoChange())
    }

    func tryPerformAction(element _: AutomationElement, actionName _: String) throws
    -> UIInputExecutionResult.Action {
        self.performActionCallCount += 1
        if let elementActionError {
            throw elementActionError
        }
        if self.allowsElementActions {
            return UIInputExecutionResult.Action(
                outcome: .confirmedChange(
                    delivery: .init(mechanism: .accessibilityAction, mode: .background)),
                actionName: AXActionNames.kAXPressAction)
        }
        Issue.record("Action driver should not be called")
        return UIInputExecutionResult.Action(outcome: .confirmedNoChange())
    }
}

final class ProcessGenerationReadSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]
    private var reads = 0

    init(_ values: [UInt64]) {
        self.values = values
    }

    var readCount: Int {
        self.lock.withLock { self.reads }
    }

    func next() -> UInt64? {
        self.lock.withLock {
            self.reads += 1
            guard !self.values.isEmpty else { return nil }
            return self.values.removeFirst()
        }
    }
}

@MainActor
final class FixedActionAutomationElementResolver: AutomationElementResolving {
    private let element = AutomationElement(Element(AXUIElementCreateApplication(getpid())))
    private let onResolve: @MainActor () -> Void

    init(onResolve: @escaping @MainActor () -> Void = {}) {
        self.onResolve = onResolve
    }

    func resolve(detectedElement _: DetectedElement, windowContext _: WindowContext?) -> AutomationElement? {
        self.onResolve()
        return self.element
    }

    func resolve(
        detectedElement _: DetectedElement,
        windowContext _: WindowContext?,
        targetProcessIdentifier: pid_t?) -> AutomationElement?
    {
        self.onResolve()
        return targetProcessIdentifier.map {
            AutomationElement(Element(AXUIElementCreateApplication($0)))
        } ?? self.element
    }

    func resolve(query _: String, windowContext _: WindowContext?, requireTextInput _: Bool) -> AutomationElement? {
        self.onResolve()
        return self.element
    }

    func resolve(
        query _: String,
        windowContext _: WindowContext?,
        targetProcessIdentifier: pid_t?,
        requireTextInput _: Bool) -> AutomationElement?
    {
        self.onResolve()
        return targetProcessIdentifier.map {
            AutomationElement(Element(AXUIElementCreateApplication($0)))
        } ?? self.element
    }
}

@MainActor
final class CrossProcessActionAutomationElementResolver: AutomationElementResolving {
    private let returnedProcessIdentifier: pid_t
    private(set) var targetProcessIdentifiers: [pid_t?] = []

    init(returnedProcessIdentifier: pid_t) {
        self.returnedProcessIdentifier = returnedProcessIdentifier
    }

    func resolve(
        detectedElement _: DetectedElement,
        windowContext _: WindowContext?,
        targetProcessIdentifier: pid_t?) -> AutomationElement?
    {
        self.targetProcessIdentifiers.append(targetProcessIdentifier)
        return AutomationElement(Element(AXUIElementCreateApplication(self.returnedProcessIdentifier)))
    }

    func resolve(
        query _: String,
        windowContext _: WindowContext?,
        targetProcessIdentifier _: pid_t?,
        requireTextInput _: Bool) -> AutomationElement?
    {
        nil
    }
}

actor ActionLaneLatch {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool {
        self.opened
    }

    func open() {
        guard !self.opened else { return }
        self.opened = true
        let pending = self.continuations
        self.continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !self.opened else { return }
        await withCheckedContinuation { self.continuations.append($0) }
    }

    func opensWithin(_ duration: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while !self.opened, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return self.opened
    }
}

@MainActor
final class ActionInputMockAutomationElement: AutomationElementRepresenting, @unchecked Sendable {
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
    let isSelectedSettable: Bool
    var selectedValue: Bool?
    let isEnabled: Bool
    var isFocused: Bool
    let focusedElementIdentity: FocusedElementIdentity?
    let isOffscreen: Bool
    var anchorPoint: CGPoint? {
        self.frame.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    private let children: [ActionInputMockAutomationElement]
    private let stringAttributes: [String: String]
    private let intAttributes: [String: Int]
    private let doubleAttributes: [String: Double]
    private let actionErrors: [String: any Error]
    private let actionFailureAfterSuccesses: Int?
    private let sequencedActionFailure: (any Error)?
    private let valueSetterDoesNotChange: Bool
    private let focusSetterDoesNotChange: Bool
    var performedActions: [String] = []
    var attemptedActions: [String] = []
    var setValues: [UIElementValue] = []
    var setFocusedValues: [Bool] = []
    var setSelectedValues: [Bool] = []

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
        isSelectedSettable: Bool = false,
        selectedValue: Bool? = nil,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        focusedElementIdentity: FocusedElementIdentity? = nil,
        isOffscreen: Bool = false,
        children: [ActionInputMockAutomationElement] = [],
        stringAttributes: [String: String] = [:],
        intAttributes: [String: Int] = [:],
        doubleAttributes: [String: Double] = [:],
        actionErrors: [String: any Error] = [:],
        actionFailureAfterSuccesses: Int? = nil,
        sequencedActionFailure: (any Error)? = nil,
        valueSetterDoesNotChange: Bool = false,
        focusSetterDoesNotChange: Bool = false)
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
        self.isSelectedSettable = isSelectedSettable
        self.selectedValue = selectedValue
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.focusedElementIdentity = focusedElementIdentity ?? role.flatMap { role in
            frame.map { frame in
                FocusedElementIdentity(
                    processIdentifier: 777,
                    windowID: 42,
                    role: role,
                    identifier: identifier,
                    frame: frame)
            }
        }
        self.isOffscreen = isOffscreen
        self.children = children
        self.stringAttributes = stringAttributes
        self.intAttributes = intAttributes
        self.doubleAttributes = doubleAttributes
        self.actionErrors = actionErrors
        self.actionFailureAfterSuccesses = actionFailureAfterSuccesses
        self.sequencedActionFailure = sequencedActionFailure
        self.valueSetterDoesNotChange = valueSetterDoesNotChange
        self.focusSetterDoesNotChange = focusSetterDoesNotChange
    }

    func performAutomationAction(_ actionName: String) throws {
        self.attemptedActions.append(actionName)
        if let error = self.actionErrors[actionName] {
            throw error
        }
        if let actionFailureAfterSuccesses,
           self.performedActions.count >= actionFailureAfterSuccesses,
           let sequencedActionFailure
        {
            throw sequencedActionFailure
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
        self.setValues.append(value)
        guard !self.valueSetterDoesNotChange else { return }
        switch value {
        case let .bool(value):
            self.value = value
        case let .int(value):
            self.value = value
        case let .double(value):
            self.value = value
        case let .string(value):
            self.value = value
        }
    }

    func setAutomationFocused(_ focused: Bool) throws {
        guard self.isFocusedSettable else {
            throw AccessibilitySystemError(.attributeUnsupported)
        }
        self.setFocusedValues.append(focused)
        guard !self.focusSetterDoesNotChange else { return }
        self.isFocused = focused
    }

    func setAutomationSelected(_ selected: Bool) throws {
        guard self.isSelectedSettable else {
            throw AccessibilitySystemError(.attributeUnsupported)
        }
        self.setSelectedValues.append(selected)
        self.selectedValue = selected
    }

    func stringAttribute(_ name: String) -> String? {
        self.stringAttributes[name]
    }

    func intAttribute(_ name: String) -> Int? {
        self.intAttributes[name]
    }

    func doubleAttribute(_ name: String) -> Double? {
        self.doubleAttributes[name]
    }
}
