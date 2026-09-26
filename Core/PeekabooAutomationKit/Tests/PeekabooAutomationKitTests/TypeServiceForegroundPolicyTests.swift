import AppKit
import ApplicationServices
import struct AXorcist.AccessibilitySystemError
import enum AXorcist.AXMessagingTimeoutError
import struct AXorcist.Element
import enum AXorcist.MouseButton
import enum AXorcist.SpecialKey
import Foundation
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct TypeServiceForegroundPolicyTests {
    @Test(arguments: [UIInputStrategy.actionFirst, .actionOnly])
    func `already-focused zero-delay replacement uses fresh focus despite cached unfocused state`(
        strategy: UIInputStrategy) async throws
    {
        let fixture = try await ForegroundTypePolicyFixture(
            policy: UIInputPolicy(defaultStrategy: strategy),
            cachedFocused: false)
        defer { fixture.cleanup() }

        let result = try await fixture.service.type(
            text: "after",
            target: "Input",
            clearExisting: true,
            typingDelay: 0,
            snapshotId: fixture.snapshotID)

        #expect(result.strategy == strategy)
        #expect(result.path == .action)
        #expect(result.fallbackReason == nil)
        #expect(result.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
        #expect(fixture.focus.readCount == 2)
        #expect(fixture.route.receivers == [
            ObjectIdentifier(fixture.focus.element),
            ObjectIdentifier(fixture.focus.element),
        ])
        #expect(fixture.action.replacementFlags == [true])
        #expect(fixture.action.field.setValues == [.string("after")])
        #expect(fixture.action.field.stringValue == "after")
        #expect(fixture.synthetic.events.isEmpty)
        #expect(fixture.synthetic.pointer.events.isEmpty)
    }

    @Test(arguments: [TextInputRoute.nativeAX, .webKeyboard, .unproven], [false, true])
    func `built-in named legacy replacement remains synthetic without reading AX focus or ancestry`(
        route: TextInputRoute,
        focusReadFails: Bool) async throws
    {
        let fixture = try await ForegroundTypePolicyFixture(policy: .currentBehavior)
        defer { fixture.cleanup() }
        fixture.route.result = route
        if focusReadFails {
            fixture.focus.failure = ActionInputError.permissionDenied
        }

        let result = try await fixture.service.type(
            text: "ab",
            target: "Input",
            clearExisting: true,
            typingDelay: 0,
            snapshotId: fixture.snapshotID)

        #expect(result.strategy == .synthFirst)
        #expect(result.path == .synth)
        #expect(result.fallbackReason == nil)
        #expect(result.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        #expect(fixture.focus.readCount == 0)
        #expect(fixture.route.receivers.isEmpty)
        #expect(fixture.action.replacementFlags.isEmpty)
        #expect(fixture.action.field.setValues.isEmpty)
        #expect(fixture.action.field.stringValue == "before")
        #expect(fixture.synthetic.events == Self.clearAndTypeEvents)
        #expect(fixture.synthetic.pointer.events == [.click(
            point: CGPoint(x: 120, y: 45), button: .left, count: 1)])
    }

    @Test(arguments: [false, true])
    func `positive legacy typing delay stays synthetic without an AX replacement`(
        usesBuiltInPolicy: Bool) async throws
    {
        let policy = usesBuiltInPolicy ? UIInputPolicy.currentBehavior : UIInputPolicy(defaultStrategy: .actionFirst)
        let fixture = try await ForegroundTypePolicyFixture(policy: policy)
        defer { fixture.cleanup() }
        fixture.focus.failure = ActionInputError.permissionDenied
        fixture.route.result = .unproven

        let result = try await fixture.service.type(
            text: "ab",
            target: "Input",
            clearExisting: true,
            typingDelay: 1,
            snapshotId: fixture.snapshotID)

        #expect(result.strategy == (usesBuiltInPolicy ? .synthFirst : .actionFirst))
        #expect(result.path == .synth)
        #expect(result.fallbackReason == (usesBuiltInPolicy ? nil : .actionUnsupported))
        #expect(result.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        #expect(fixture.focus.readCount == 0)
        #expect(fixture.route.receivers.isEmpty)
        #expect(fixture.action.replacementFlags.isEmpty)
        #expect(fixture.action.field.setValues.isEmpty)
        #expect(fixture.action.field.stringValue == "before")
        #expect(fixture.synthetic.events == Self.clearAndTypeEvents)
        #expect(fixture.synthetic.pointer.events == [.click(
            point: CGPoint(x: 120, y: 45), button: .left, count: 1)])
    }

    @Test
    func `action-only refuses positive legacy typing delay without dispatch`() async throws {
        let fixture = try await ForegroundTypePolicyFixture(policy: UIInputPolicy(defaultStrategy: .actionOnly))
        defer { fixture.cleanup() }
        fixture.focus.failure = ActionInputError.permissionDenied

        await #expect(throws: ActionInputError.unsupported(.actionUnsupported)) {
            try await fixture.service.type(
                text: "ab",
                target: "Input",
                clearExisting: true,
                typingDelay: 1,
                snapshotId: fixture.snapshotID)
        }

        #expect(fixture.focus.readCount == 0)
        #expect(fixture.route.receivers.isEmpty)
        #expect(fixture.action.replacementFlags.isEmpty)
        #expect(fixture.action.field.setValues.isEmpty)
        #expect(fixture.action.field.stringValue == "before")
        #expect(fixture.synthetic.events.isEmpty)
        #expect(fixture.synthetic.pointer.events.isEmpty)
    }

    @Test
    func `fresh mismatched focus ignores cached focused state and falls back before AX`() async throws {
        let fixture = try await ForegroundTypePolicyFixture(
            policy: UIInputPolicy(defaultStrategy: .actionFirst),
            cachedFocused: true)
        defer { fixture.cleanup() }
        fixture.focus.element = AXUIElementCreateApplication(getpid() + 1)
        fixture.route.result = .unproven

        let result = try await fixture.service.type(
            text: "ab",
            target: "Input",
            clearExisting: true,
            typingDelay: 0,
            snapshotId: fixture.snapshotID)

        #expect(result.strategy == .actionFirst)
        #expect(result.path == .synth)
        #expect(result.fallbackReason == .actionUnsupported)
        #expect(result.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        #expect(fixture.focus.readCount == 1)
        #expect(fixture.route.receivers.isEmpty)
        #expect(fixture.action.replacementFlags.isEmpty)
        #expect(fixture.action.field.setValues.isEmpty)
        #expect(fixture.action.field.stringValue == "before")
        #expect(fixture.synthetic.events == Self.clearAndTypeEvents)
        #expect(fixture.synthetic.pointer.events == [.click(
            point: CGPoint(x: 120, y: 45), button: .left, count: 1)])
    }

    @Test
    func `action-only refuses fresh mismatched focus despite cached focused state`() async throws {
        let fixture = try await ForegroundTypePolicyFixture(
            policy: UIInputPolicy(defaultStrategy: .actionOnly),
            cachedFocused: true)
        defer { fixture.cleanup() }
        fixture.focus.element = AXUIElementCreateApplication(getpid() + 1)
        fixture.route.result = .unproven

        await #expect(throws: ActionInputError.unsupported(.actionUnsupported)) {
            try await fixture.service.type(
                text: "ab",
                target: "Input",
                clearExisting: true,
                typingDelay: 0,
                snapshotId: fixture.snapshotID)
        }

        #expect(fixture.focus.readCount == 1)
        #expect(fixture.route.receivers.isEmpty)
        #expect(fixture.action.replacementFlags.isEmpty)
        #expect(fixture.action.field.setValues.isEmpty)
        #expect(fixture.action.field.stringValue == "before")
        #expect(fixture.synthetic.events.isEmpty)
        #expect(fixture.synthetic.pointer.events.isEmpty)
    }

    @Test(arguments: [UIInputStrategy.actionFirst, .actionOnly], [
        ActionInputError.permissionDenied,
        .targetUnavailable,
        .staleElement,
        .failed("focus probe failure"),
    ])
    func `failed fresh focus read never authorizes fallback`(
        strategy: UIInputStrategy,
        failure: ActionInputError) async throws
    {
        let fixture = try await ForegroundTypePolicyFixture(policy: UIInputPolicy(defaultStrategy: strategy))
        defer { fixture.cleanup() }
        fixture.focus.failure = failure

        await #expect(throws: failure) {
            try await fixture.service.type(
                text: "ab",
                target: "Input",
                clearExisting: true,
                typingDelay: 0,
                snapshotId: fixture.snapshotID)
        }

        #expect(fixture.focus.readCount == 1)
        #expect(fixture.route.receivers.isEmpty)
        #expect(fixture.action.replacementFlags.isEmpty)
        #expect(fixture.action.field.setValues.isEmpty)
        #expect(fixture.synthetic.events.isEmpty)
        #expect(fixture.synthetic.pointer.events.isEmpty)
    }

    @Test(arguments: [UIInputStrategy.actionFirst, .actionOnly], [
        AXError.apiDisabled,
        .cannotComplete,
        .invalidUIElement,
        .attributeUnsupported,
        .noValue,
    ])
    func `native focus read errors remain strict even when the attribute is unsupported`(
        strategy: UIInputStrategy,
        axError: AXError) async throws
    {
        let fixture = try await ForegroundTypePolicyFixture(policy: UIInputPolicy(defaultStrategy: strategy))
        defer { fixture.cleanup() }
        fixture.focus.failure = AccessibilitySystemError(axError)

        let failure = await #expect(throws: AccessibilitySystemError.self) {
            try await fixture.service.type(
                text: "ab",
                target: "Input",
                clearExisting: true,
                typingDelay: 0,
                snapshotId: fixture.snapshotID)
        }

        #expect(failure?.axError == axError)
        #expect(fixture.focus.readCount == 1)
        #expect(fixture.route.receivers.isEmpty)
        #expect(fixture.action.replacementFlags.isEmpty)
        #expect(fixture.action.field.setValues.isEmpty)
        #expect(fixture.synthetic.events.isEmpty)
        #expect(fixture.synthetic.pointer.events.isEmpty)
    }

    @Test(arguments: [UIInputStrategy.actionFirst, .actionOnly])
    func `focus read timeout scope failure never authorizes fallback`(strategy: UIInputStrategy) async throws {
        let fixture = try await ForegroundTypePolicyFixture(policy: UIInputPolicy(defaultStrategy: strategy))
        defer { fixture.cleanup() }
        let failure = AXMessagingTimeoutError.systemFailure(code: AXError.cannotComplete.rawValue)
        fixture.focus.failure = failure

        await #expect(throws: failure) {
            try await fixture.service.type(
                text: "ab",
                target: "Input",
                clearExisting: true,
                typingDelay: 0,
                snapshotId: fixture.snapshotID)
        }

        #expect(fixture.focus.readCount == 1)
        #expect(fixture.route.receivers.isEmpty)
        #expect(fixture.action.replacementFlags.isEmpty)
        #expect(fixture.action.field.setValues.isEmpty)
        #expect(fixture.synthetic.events.isEmpty)
        #expect(fixture.synthetic.pointer.events.isEmpty)
    }

    @Test
    func `action-first legacy replacement routes web receivers to keyboard before any AX attempt`() async throws {
        let fixture = try await ForegroundTypePolicyFixture(policy: UIInputPolicy(defaultStrategy: .actionFirst))
        defer { fixture.cleanup() }
        fixture.route.result = .webKeyboard

        let result = try await fixture.service.type(
            text: "ab",
            target: "Input",
            clearExisting: true,
            typingDelay: 0,
            snapshotId: fixture.snapshotID)

        #expect(result.strategy == .actionFirst)
        #expect(result.path == .synth)
        #expect(result.fallbackReason == .actionUnsupported)
        #expect(result.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        #expect(fixture.focus.readCount == 1)
        #expect(fixture.route.receivers == [ObjectIdentifier(fixture.focus.element)])
        #expect(fixture.action.replacementFlags.isEmpty)
        #expect(fixture.action.field.setValues.isEmpty)
        #expect(fixture.action.field.stringValue == "before")
        #expect(fixture.synthetic.events == Self.clearAndTypeEvents)
        #expect(fixture.synthetic.pointer.events == [.click(
            point: CGPoint(x: 120, y: 45), button: .left, count: 1)])
    }

    @Test
    func `action-only refuses legacy web receivers without AX or keyboard dispatch`() async throws {
        let fixture = try await ForegroundTypePolicyFixture(policy: UIInputPolicy(defaultStrategy: .actionOnly))
        defer { fixture.cleanup() }
        fixture.route.result = .webKeyboard

        await #expect(throws: ActionInputError.unsupported(.actionUnsupported)) {
            try await fixture.service.type(
                text: "ab",
                target: "Input",
                clearExisting: true,
                typingDelay: 0,
                snapshotId: fixture.snapshotID)
        }

        #expect(fixture.focus.readCount == 1)
        #expect(fixture.route.receivers == [ObjectIdentifier(fixture.focus.element)])
        #expect(fixture.action.replacementFlags.isEmpty)
        #expect(fixture.action.field.setValues.isEmpty)
        #expect(fixture.action.field.stringValue == "before")
        #expect(fixture.synthetic.events.isEmpty)
        #expect(fixture.synthetic.pointer.events.isEmpty)
    }

    @Test(arguments: [UIInputStrategy.actionFirst, .actionOnly])
    func `unproven legacy text input route refuses without AX or keyboard fallback`(
        strategy: UIInputStrategy) async throws
    {
        let fixture = try await ForegroundTypePolicyFixture(policy: UIInputPolicy(defaultStrategy: strategy))
        defer { fixture.cleanup() }
        fixture.route.result = .unproven

        let failure = await #expect(throws: DesktopActionFailure.self) {
            try await fixture.service.type(
                text: "ab",
                target: "Input",
                clearExisting: true,
                typingDelay: 0,
                snapshotId: fixture.snapshotID)
        }

        #expect(failure?.outcome.state == .refused)
        #expect(failure?.outcome.refusalReason == .targetUnavailable)
        #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(failure?.outcome.projection.retrySafe == true)
        #expect(failure?.outcome.projection.mutationDispatched == false)
        #expect(fixture.focus.readCount == 1)
        #expect(fixture.route.receivers == [ObjectIdentifier(fixture.focus.element)])
        #expect(fixture.action.replacementFlags.isEmpty)
        #expect(fixture.action.field.setValues.isEmpty)
        #expect(fixture.action.field.stringValue == "before")
        #expect(fixture.synthetic.events.isEmpty)
        #expect(fixture.synthetic.pointer.events.isEmpty)
    }

    @Test
    func `legacy action route rereads focus before each native write`() async throws {
        let fixture = try await ForegroundTypePolicyFixture(policy: UIInputPolicy(defaultStrategy: .actionOnly))
        defer { fixture.cleanup() }

        let first = try await fixture.service.type(
            text: "first",
            target: "Input",
            clearExisting: true,
            typingDelay: 0,
            snapshotId: fixture.snapshotID)
        #expect(first.path == .action)
        #expect(fixture.focus.readCount == 2)
        #expect(fixture.route.receivers.count == 2)

        fixture.focus.element = AXUIElementCreateApplication(getpid() + 1)
        await #expect(throws: ActionInputError.unsupported(.actionUnsupported)) {
            try await fixture.service.type(
                text: "not delivered",
                target: "Input",
                clearExisting: true,
                typingDelay: 0,
                snapshotId: fixture.snapshotID)
        }
        #expect(fixture.focus.readCount == 3)
        #expect(fixture.route.receivers.count == 2)
        #expect(fixture.action.field.stringValue == "first")

        fixture.focus.element = AXUIElementCreateApplication(getpid())
        let last = try await fixture.service.type(
            text: "last",
            target: "Input",
            clearExisting: true,
            typingDelay: 0,
            snapshotId: fixture.snapshotID)

        #expect(last.path == .action)
        #expect(fixture.focus.readCount == 5)
        #expect(fixture.route.receivers.count == 4)
        #expect(fixture.action.replacementFlags == [true, true])
        #expect(fixture.action.field.setValues == [.string("first"), .string("last")])
        #expect(fixture.action.field.stringValue == "last")
        #expect(fixture.synthetic.events.isEmpty)
        #expect(fixture.synthetic.pointer.events.isEmpty)
    }

    @Test
    func `built-in targetless legacy replacement remains synthetic`() async throws {
        let fixture = try await ForegroundTypePolicyFixture(policy: .currentBehavior)
        defer { fixture.cleanup() }

        let result = try await fixture.service.type(
            text: "ab",
            target: nil,
            clearExisting: true,
            typingDelay: 0,
            snapshotId: fixture.snapshotID)

        #expect(result.strategy == .synthFirst)
        #expect(result.path == .synth)
        #expect(result.fallbackReason == nil)
        #expect(result.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        #expect(fixture.focus.readCount == 0)
        #expect(fixture.route.receivers.isEmpty)
        #expect(fixture.action.replacementFlags.isEmpty)
        #expect(fixture.action.field.setValues.isEmpty)
        #expect(fixture.synthetic.events == Self.clearAndTypeEvents)
        #expect(fixture.synthetic.pointer.events.isEmpty)
    }

    @Test
    func `built-in foreground action arrays remain synthetic`() async throws {
        let fixture = try await ForegroundTypePolicyFixture(policy: .currentBehavior)
        defer { fixture.cleanup() }

        let summary = try await fixture.service.typeActionsTrackingSecureInput(
            [.clear, .text("ab")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: fixture.snapshotID,
            automationTarget: .foreground)

        #expect(summary.executionResult.path == .synth)
        #expect(summary.executionResult.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        #expect(summary.result.totalCharacters == 2)
        #expect(summary.result.keyPresses == 4)
        #expect(summary.result.specialKeyPresses == 2)
        #expect(fixture.focus.readCount == 0)
        #expect(fixture.route.receivers.isEmpty)
        #expect(fixture.action.replacementFlags.isEmpty)
        #expect(fixture.action.field.setValues.isEmpty)
        #expect(fixture.synthetic.events == Self.clearAndTypeEvents)
        #expect(fixture.synthetic.pointer.events.isEmpty)
    }

    @Test(arguments: [UIInputStrategy.synthFirst, .synthOnly], [0, 1])
    func `explicit synthetic strategy keeps named legacy replacement synthetic`(
        strategy: UIInputStrategy,
        typingDelay: Int) async throws
    {
        let fixture = try await ForegroundTypePolicyFixture(policy: UIInputPolicy(defaultStrategy: strategy))
        defer { fixture.cleanup() }
        fixture.route.result = .unproven

        let result = try await fixture.service.type(
            text: "ab",
            target: "Input",
            clearExisting: true,
            typingDelay: typingDelay,
            snapshotId: fixture.snapshotID)

        #expect(result.strategy == strategy)
        #expect(result.path == .synth)
        #expect(result.fallbackReason == nil)
        #expect(result.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        #expect(fixture.focus.readCount == 0)
        #expect(fixture.route.receivers.isEmpty)
        #expect(fixture.action.replacementFlags.isEmpty)
        #expect(fixture.action.field.setValues.isEmpty)
        #expect(fixture.synthetic.events == Self.clearAndTypeEvents)
        #expect(fixture.synthetic.pointer.events.contains(.click(
            point: CGPoint(x: 120, y: 45), button: .left, count: 1)))
    }

    private static let clearAndTypeEvents: [ForegroundTypeSyntheticDriver.Event] = [
        .hotkey(["cmd", "a"], 0.1),
        .key(.delete, []),
        .text("a", 0),
        .text("b", 0),
    ]
}

@MainActor
private final class ForegroundTypePolicyFixture {
    let snapshotID = SnapshotReferenceFixtures.first.rawValue
    let action = ForegroundTypeActionDriver()
    let synthetic = ForegroundTypeSyntheticDriver()
    let focus: ForegroundTypeFocusProbe
    let route: ForegroundTypeRouteProbe
    let service: TypeService
    private let coordinationRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("foreground-type-policy-\(UUID().uuidString)", isDirectory: true)

    init(policy: UIInputPolicy, cachedFocused: Bool = false) async throws {
        let focus = ForegroundTypeFocusProbe(element: AXUIElementCreateApplication(getpid()))
        self.focus = focus
        let route = ForegroundTypeRouteProbe()
        self.route = route
        let detected = DetectedElement(
            id: "T1",
            type: .textField,
            label: "Input",
            bounds: CGRect(x: 20, y: 30, width: 200, height: 30))
        let detection = ElementDetectionResult(
            snapshotId: self.snapshotID,
            screenshotPath: "/tmp/foreground-type-policy.png",
            elements: DetectedElements(textFields: [detected]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationBundleId: "com.example.ForegroundTypePolicy")))
        let manager = try await InMemorySnapshotManager.containing(detection)
        self.service = TypeService(
            snapshotManager: manager,
            inputPolicy: policy,
            actionInputDriver: self.action,
            syntheticInputDriver: self.synthetic,
            automationElementResolver: ForegroundTypeElementResolver(cachedFocused: cachedFocused),
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            focusedUIElementReader: { try focus.read() },
            legacyTextInputRouteResolver: { route.resolve($0) },
            desktopOperationExecutor: DesktopOperationExecutor(laneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: self.coordinationRoot)))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.coordinationRoot)
    }
}

@MainActor
private struct ForegroundTypeElementResolver: AutomationElementResolving {
    private let element: AutomationElement

    init(cachedFocused: Bool) {
        self.element = AutomationElement(Element(
            AXUIElementCreateApplication(getpid()),
            attributes: [
                "AXRole": .string("AXTextField"),
                "AXSubrole": .string("AXUnknown"),
                "AXFocused": .bool(cachedFocused),
            ],
            children: [],
            actions: []))
    }

    func resolve(
        detectedElement _: DetectedElement,
        windowContext _: WindowContext?,
        targetProcessIdentifier _: pid_t?) -> AutomationElement?
    {
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
private final class ForegroundTypeRouteProbe {
    var result = TextInputRoute.nativeAX
    private(set) var receivers: [ObjectIdentifier] = []

    func resolve(_ element: AXUIElement) -> TextInputRoute {
        self.receivers.append(ObjectIdentifier(element))
        return self.result
    }
}

@MainActor
private final class ForegroundTypeFocusProbe {
    var element: AXUIElement
    var failure: (any Error)?
    private(set) var readCount = 0

    init(element: AXUIElement) {
        self.element = element
    }

    func read() throws -> AXUIElement {
        self.readCount += 1
        if let failure = self.failure {
            throw failure
        }
        return self.element
    }
}

@MainActor
private final class ForegroundTypeActionDriver: ActionInputDriving {
    let field = ActionInputMockAutomationElement(role: "AXTextField", value: "before", isValueSettable: true)
    private let unexpected = RecordingActionInputDriver()
    private(set) var replacementFlags: [Bool] = []

    func trySetText(
        element _: AutomationElement,
        text: String,
        replace: Bool,
        beforeMutation: @MainActor () throws -> Void) throws -> UIInputExecutionResult.Action
    {
        try beforeMutation()
        self.replacementFlags.append(replace)
        try self.field.setAutomationValue(.string(text))
        return UIInputExecutionResult.Action(
            outcome: .confirmedChange(delivery: .init(mechanism: .accessibilityValue, mode: .background)),
            actionName: "AXSetValue",
            elementRole: "AXTextField")
    }

    func tryClick(
        element: AutomationElement,
        beforeMutation: @MainActor () throws -> Void) throws -> UIInputExecutionResult.Action
    {
        try self.unexpected.tryClick(element: element, beforeMutation: beforeMutation)
    }

    func tryRightClick(element: any AutomationElementRepresenting) async throws -> UIInputExecutionResult.Action {
        try await self.unexpected.tryRightClick(element: element)
    }

    func tryScroll(element: AutomationElement, direction: PeekabooFoundation.ScrollDirection, pages: Int) throws
        -> UIInputExecutionResult.Action
    {
        try self.unexpected.tryScroll(element: element, direction: direction, pages: pages)
    }

    func tryHotkey(application: NSRunningApplication, keys: [String]) throws -> UIInputExecutionResult.Action {
        try self.unexpected.tryHotkey(application: application, keys: keys)
    }

    func trySetValue(
        element: AutomationElement,
        value: UIElementValue,
        beforeMutation: @MainActor () throws -> Void) throws -> UIInputExecutionResult.Action
    {
        try self.unexpected.trySetValue(element: element, value: value, beforeMutation: beforeMutation)
    }

    func tryPerformAction(element: AutomationElement, actionName: String) throws -> UIInputExecutionResult.Action {
        try self.unexpected.tryPerformAction(element: element, actionName: actionName)
    }
}

@MainActor
private final class ForegroundTypeSyntheticDriver: SyntheticInputDriving {
    enum Event: Equatable {
        case text(String, TimeInterval)
        case key(SpecialKey, CGEventFlags)
        case hotkey([String], TimeInterval)
    }

    let pointer = ClickRecordingSyntheticInputDriver()
    private(set) var events: [Event] = []

    func type(_ text: String, delayPerCharacter: TimeInterval) throws {
        self.events.append(.text(text, delayPerCharacter))
    }

    func tapKey(_ key: SpecialKey, modifiers: CGEventFlags) throws {
        self.events.append(.key(key, modifiers))
    }

    func hotkey(keys: [String], holdDuration: TimeInterval) throws {
        self.events.append(.hotkey(keys, holdDuration))
    }

    func click(at point: CGPoint, button: MouseButton, count: Int) throws -> DesktopActionOutcome {
        try self.pointer.click(at: point, button: button, count: count)
    }

    func click(at point: CGPoint, button: MouseButton, count: Int, targetProcessIdentifier: pid_t) async throws
        -> DesktopActionOutcome
    {
        try await self.pointer.click(
            at: point, button: button, count: count, targetProcessIdentifier: targetProcessIdentifier)
    }

    func move(to point: CGPoint) throws {
        try self.pointer.move(to: point)
    }

    func currentLocation() -> CGPoint? {
        self.pointer.currentLocation()
    }

    func pressHold(at point: CGPoint, button: MouseButton, duration: TimeInterval) async throws {
        try await self.pointer.pressHold(at: point, button: button, duration: duration)
    }

    func scroll(deltaX: Double, deltaY: Double, at point: CGPoint?) throws {
        try self.pointer.scroll(deltaX: deltaX, deltaY: deltaY, at: point)
    }
}
