import AppKit
import struct AXorcist.Element
import enum AXorcist.MouseButton
import enum AXorcist.SpecialKey
import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import struct PeekabooFoundation.DesktopActionFailure
import struct PeekabooFoundation.DesktopActionOutcome
import enum PeekabooFoundation.ScrollDirection
import enum PeekabooFoundation.TypeAction
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct UIAutomationActionOutcomeProvidingTests {
    @Test
    func `carrier preserves every canonical outcome and the legacy missing-outcome case`() {
        let outcomes = DesktopActionOutcomeFixtures.canonicalOutcomes

        #expect(outcomes.map(\.state) == [
            .confirmedChange,
            .confirmedNoChange,
            .partial,
            .dispatchedUnverified,
            .suspectedNoop,
            .refused,
            .indeterminate,
        ])
        for (index, outcome) in outcomes.enumerated() {
            let result = UIAutomationActionResult(payload: index, outcome: outcome)
            #expect(result.payload == index)
            #expect(result.outcome == outcome)
        }

        let legacy = UIAutomationActionResult(payload: "legacy", outcome: nil)
        #expect(legacy.payload == "legacy")
        #expect(legacy.outcome == nil)
    }

    @Test
    func `indeterminate delivery error owns canonical failure reconstruction`() {
        let error = InputDeliveryIndeterminateError(
            operation: .type,
            emittedUnitCount: 2,
            causeDescription: "destination changed")
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .processTargetedEvents,
            mode: .background)

        let failure: DesktopActionFailure = error.desktopActionFailure(delivery: delivery)

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.delivery == delivery)
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.outcome.escalation == .observeBeforeRetry)
        #expect(failure.message == error.localizedDescription)
    }

    @Test
    func `click result returns the exact driver outcome and legacy adapter repeats the same dispatch`() async throws {
        let expected = Self.outcome(mechanism: .globalEvents, mode: .foreground)
        let synthetic = OutcomeSyntheticInputDriver(clickOutcome: expected)
        let service = self.makeSynthesisService(synthetic: synthetic)

        let result = try await service.clickWithOutcome(
            target: .coordinates(CGPoint(x: 20, y: 30)),
            clickType: .single,
            snapshotId: nil)
        try await service.click(
            target: .coordinates(CGPoint(x: 20, y: 30)),
            clickType: .single,
            snapshotId: nil)

        #expect(result.outcome == expected)
        #expect(synthetic.clickCount == 2)
    }

    @Test
    func `type result returns the executor outcome and legacy adapter preserves execution`() async throws {
        let synthetic = OutcomeSyntheticInputDriver(clickOutcome: Self.foregroundOutcome)
        let service = self.makeSynthesisService(synthetic: synthetic)

        let result = try await service.typeWithOutcome(
            text: "a",
            target: nil,
            clearExisting: false,
            typingDelay: 0,
            snapshotId: nil)
        try await service.type(
            text: "a",
            target: nil,
            clearExisting: false,
            typingDelay: 0,
            snapshotId: nil)

        #expect(result.outcome == Self.foregroundOutcome)
        #expect(synthetic.typedTexts == ["a", "a"])
    }

    @Test
    func `type actions retain the outer executor result and legacy payload parity`() async throws {
        let actions: [TypeAction] = [.text("bc"), .key(.return)]
        let synthetic = OutcomeSyntheticInputDriver(clickOutcome: Self.foregroundOutcome)
        let service = self.makeSynthesisService(synthetic: synthetic)

        let result = try await service.typeActionsWithOutcome(
            actions,
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil)
        let legacy = try await service.typeActions(
            actions,
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil)

        #expect(result.outcome == Self.foregroundOutcome)
        #expect(result.payload.totalCharacters == 2)
        #expect(result.payload.keyPresses == 3)
        #expect(legacy.totalCharacters == result.payload.totalCharacters)
        #expect(legacy.keyPresses == result.payload.keyPresses)

        let typeService = TypeService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            randomSource: SystemTypingCadenceRandomSource())
        var completionOutcome: DesktopActionOutcome?
        let summary = try await typeService.typeActionsTrackingSecureInput(
            [],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            targetProcessIdentifier: nil,
            laneCompletion: { completionOutcome = $0.executionResult.outcome })

        #expect(summary.executionResult.outcome == Self.foregroundOutcome)
        #expect(completionOutcome == summary.executionResult.outcome)
    }

    @Test
    func `scroll result returns the executor outcome and legacy adapter repeats the same input`() async throws {
        let synthetic = OutcomeSyntheticInputDriver(clickOutcome: Self.foregroundOutcome)
        let service = self.makeSynthesisService(synthetic: synthetic)
        let request = ScrollRequest(
            direction: .down,
            amount: 1,
            smooth: false,
            delay: 0,
            foreground: true)

        let result = try await service.scrollWithOutcome(request)
        try await service.scroll(request)

        let expected = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        #expect(result.outcome == expected)
        #expect(synthetic.scrollCount == 2)
    }

    @Test
    func `hotkey result returns the exact action outcome and legacy adapter repeats the same chord`() async throws {
        let expected = Self.outcome(mechanism: .globalEvents, mode: .foreground)
        let actionDriver = OutcomeActionInputDriver(outcome: expected)
        let service = self.makeHotkeyService(actionDriver: actionDriver)

        let result = try await service.hotkeyWithOutcome(keys: "cmd,k", holdDuration: 0)
        try await service.hotkey(keys: "cmd,k", holdDuration: 0)

        #expect(result.outcome == expected)
        #expect(actionDriver.hotkeyCount == 2)
    }

    @Test
    func `set value result preserves payload and exact outcome with legacy payload parity`() async throws {
        let expected = Self.outcome(mechanism: .accessibilityValue, mode: .background)
        let resultDriver = OutcomeActionInputDriver(outcome: expected, storedValue: "old")
        let legacyDriver = OutcomeActionInputDriver(outcome: expected, storedValue: "old")
        let resultService = self.makeElementActionService(actionDriver: resultDriver)
        let legacyService = self.makeElementActionService(actionDriver: legacyDriver)

        let result = try await resultService.setValueWithOutcome(
            target: "E1",
            value: .string("new"),
            snapshotId: "snapshot")
        let legacy = try await legacyService.setValue(
            target: "E1",
            value: .string("new"),
            snapshotId: "snapshot")

        #expect(result.outcome == expected)
        #expect(result.payload == legacy)
        #expect(result.payload.oldValue == "old")
        #expect(result.payload.newValue == "new")
        #expect(result.targetIdentity?.exactWindow != nil)
        #expect(resultDriver.setValueCount == 1)
        #expect(legacyDriver.setValueCount == 1)
    }

    @Test
    func `perform action result preserves payload and exact outcome with legacy payload parity`() async throws {
        let expected = Self.outcome(mechanism: .accessibilityAction, mode: .background)
        let resultDriver = OutcomeActionInputDriver(outcome: expected)
        let legacyDriver = OutcomeActionInputDriver(outcome: expected)
        let resultService = self.makeElementActionService(actionDriver: resultDriver)
        let legacyService = self.makeElementActionService(actionDriver: legacyDriver)

        let result = try await resultService.performActionWithOutcome(
            target: "E1",
            actionName: "AXPress",
            snapshotId: "snapshot")
        let legacy = try await legacyService.performAction(
            target: "E1",
            actionName: "AXPress",
            snapshotId: "snapshot")

        #expect(result.outcome == expected)
        #expect(result.payload == legacy)
        #expect(result.payload.target == "E1")
        #expect(result.payload.actionName == "AXPress")
        #expect(result.payload.oldValue == nil)
        #expect(result.payload.newValue == nil)
        #expect(result.targetIdentity?.exactWindow != nil)
        #expect(resultDriver.performActionCount == 1)
        #expect(legacyDriver.performActionCount == 1)
    }

    @Test
    func `targeted result overloads return exact background executor outcomes`() async throws {
        let generation: UInt64 = 71
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: getpid(),
            processStartIdentity: generation)
        let bounds = CGRect(x: 100, y: 100, width: 500, height: 400)
        let windowIdentity = WindowMutationIdentity(
            windowID: 307,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: generation,
            capturedBounds: bounds)
        let focused = FocusedElementIdentity(
            processIdentifier: getpid(),
            windowID: windowIdentity.windowID,
            role: "AXTextField",
            title: "Editor",
            identifier: "editor",
            frame: CGRect(x: 150, y: 150, width: 200, height: 30))
        let exactTarget = ExactWindowKeyboardTarget(
            windowIdentity: windowIdentity,
            windowBounds: bounds,
            focusedElement: focused)
        let expectedClick = Self.outcome(mechanism: .windowTargetedEvents, mode: .background)
        let synthetic = OutcomeSyntheticInputDriver(clickOutcome: expectedClick)
        let service = self.makeTargetedService(
            synthetic: synthetic,
            generation: generation,
            windowIdentity: windowIdentity,
            focused: focused)
        let clickTarget = ClickTarget.elementId("B1")

        let clickResults = try await WindowMovementTrackingProviderScope.withProvider(
            TargetedWindowTracker(
                windowID: CGWindowID(windowIdentity.windowID),
                bounds: bounds,
                processIdentifier: getpid()))
        {
            let pidClick = try await service.clickWithOutcome(
                target: clickTarget,
                clickType: .single,
                snapshotId: "targeted",
                targetProcessIdentifier: getpid())
            let processClick = try await service.clickWithOutcome(
                target: clickTarget,
                clickType: .single,
                snapshotId: "targeted",
                expectedProcessIdentity: processIdentity)
            let windowClick = try await service.clickWithOutcome(
                target: clickTarget,
                clickType: .single,
                snapshotId: "targeted",
                expectedWindowIdentity: windowIdentity,
                expectedWindowBounds: bounds)
            return [pidClick, processClick, windowClick]
        }

        for result in clickResults {
            #expect(result.outcome == expectedClick)
        }
        #expect(clickResults[0].targetIdentity == nil)
        #expect(clickResults[1].targetIdentity?.processIdentity == processIdentity)
        #expect(clickResults[1].targetIdentity?.exactWindow == nil)
        #expect(clickResults[2].targetIdentity?.exactWindow?.identity == windowIdentity)
        #expect(clickResults[2].targetIdentity?.exactWindow?.bounds == bounds)

        let pidType = try await service.typeActionsWithOutcome(
            [],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            targetProcessIdentifier: getpid())
        let processType = try await service.typeActionsWithOutcome(
            [],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            expectedProcessIdentity: processIdentity)
        let windowType = try await service.typeActionsWithOutcome(
            [],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            expectedWindowIdentity: windowIdentity,
            expectedWindowBounds: bounds)
        let focusedType = try await service.typeActionsWithOutcome(
            [],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            target: exactTarget)

        for result in [pidType, processType] {
            #expect(result.outcome == Self.backgroundOutcome)
            #expect(result.payload.totalCharacters == 0)
            #expect(result.payload.keyPresses == 0)
        }
        for result in [windowType, focusedType] {
            #expect(result.outcome == Self.windowBackgroundOutcome)
            #expect(result.payload.totalCharacters == 0)
            #expect(result.payload.keyPresses == 0)
        }
        #expect(pidType.targetIdentity == nil)
        #expect(processType.targetIdentity?.processIdentity == processIdentity)
        #expect(processType.targetIdentity?.exactWindow == nil)
        #expect(windowType.targetIdentity?.exactWindow?.identity == windowIdentity)
        #expect(windowType.targetIdentity?.exactWindow?.bounds == bounds)
        #expect(windowType.targetIdentity?.exactWindow?.focusedElement == nil)
        #expect(focusedType.targetIdentity?.exactWindow?.identity == windowIdentity)
        #expect(focusedType.targetIdentity?.exactWindow?.bounds == bounds)
        #expect(focusedType.targetIdentity?.exactWindow?.focusedElement == focused)

        let pidHotkey = try await service.hotkeyWithOutcome(
            keys: "cmd,shift,l",
            holdDuration: 0,
            targetProcessIdentifier: getpid())
        let processHotkey = try await service.hotkeyWithOutcome(
            keys: "cmd,shift,l",
            holdDuration: 0,
            expectedProcessIdentity: processIdentity)
        let windowHotkey = try await service.hotkeyWithOutcome(
            keys: "cmd,shift,l",
            holdDuration: 0,
            expectedWindowIdentity: windowIdentity,
            expectedWindowBounds: bounds)
        let focusedHotkey = try await service.hotkeyWithOutcome(
            keys: "cmd,shift,l",
            holdDuration: 0,
            target: exactTarget)

        for result in [pidHotkey, processHotkey] {
            #expect(result.outcome == Self.backgroundOutcome)
        }
        for result in [windowHotkey, focusedHotkey] {
            #expect(result.outcome == Self.windowBackgroundOutcome)
        }
    }

    private func makeSynthesisService(synthetic: OutcomeSyntheticInputDriver) -> UIAutomationService {
        UIAutomationService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            actionInputDriver: OutcomeActionInputDriver(outcome: Self.foregroundOutcome),
            syntheticInputDriver: synthetic,
            automationElementResolver: FixedOutcomeAutomationElementResolver())
    }

    private func makeHotkeyService(actionDriver: OutcomeActionInputDriver) -> UIAutomationService {
        UIAutomationService(
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: actionDriver,
            automationElementResolver: FixedOutcomeAutomationElementResolver(),
            hotkeyServiceFactory: { context in
                HotkeyService(
                    inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
                    actionInputDriver: actionDriver,
                    frontmostApplicationResolver: {
                        NSRunningApplication(processIdentifier: getpid())
                    },
                    processStartIdentityProvider: context.processStartIdentityProvider,
                    desktopOperationExecutor: context.desktopOperationExecutor,
                    operationFinalizer: context.operationFinalizer)
            })
    }

    private func makeElementActionService(actionDriver: OutcomeActionInputDriver) -> UIAutomationService {
        let detected = AutomationTestFixtures.detectedElement(
            id: "E1",
            type: .textField,
            label: "Value")
        let processIdentity = AutomationTestFixtures.processIdentity(processIdentifier: getpid())
        let window = AutomationTestFixtures.window(processIdentity: processIdentity)
        let detection = AutomationTestFixtures.detectionResult(
            snapshotID: "snapshot",
            elements: DetectedElements(textFields: [detected]),
            windowContext: WindowContext(
                applicationProcessId: getpid(),
                windowID: window.windowID,
                windowBounds: window.bounds,
                windowMutationIdentity: window.mutationIdentity))
        return UIAutomationService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detection),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: actionDriver,
            automationElementResolver: FixedOutcomeAutomationElementResolver(),
            elementMutationValueReader: { _ in actionDriver.storedValue },
            exactWindowIdentityValidator: { identity, bounds in
                identity == window.mutationIdentity && bounds == window.bounds
            },
            processStartIdentityProvider: { _ in processIdentity.processStartIdentity })
    }

    private func makeTargetedService(
        synthetic: OutcomeSyntheticInputDriver,
        generation: UInt64,
        windowIdentity: WindowMutationIdentity,
        focused: FocusedElementIdentity) -> UIAutomationService
    {
        let detected = AutomationTestFixtures.detectedElement(
            id: "B1",
            type: .button,
            label: "Button",
            bounds: focused.frame)
        let context = WindowContext(
            applicationName: "Test App",
            applicationBundleId: "com.example.TestApp",
            applicationProcessId: windowIdentity.ownerProcessIdentifier,
            windowTitle: "Test Window",
            windowID: windowIdentity.windowID,
            windowBounds: windowIdentity.capturedBounds,
            windowMutationIdentity: windowIdentity)
        let detection = AutomationTestFixtures.detectionResult(
            snapshotID: "targeted",
            elements: DetectedElements(buttons: [detected]),
            windowContext: context)
        return UIAutomationService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detection),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            actionInputDriver: OutcomeActionInputDriver(outcome: Self.backgroundOutcome),
            syntheticInputDriver: synthetic,
            automationElementResolver: FixedOutcomeAutomationElementResolver(),
            hotkeyServiceFactory: { context in
                HotkeyService(
                    inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                    postEventAccessEvaluator: { true },
                    eventPoster: { _, _ in },
                    runningApplicationResolver: {
                        NSRunningApplication(processIdentifier: $0)
                    },
                    processStartIdentityProvider: context.processStartIdentityProvider,
                    desktopOperationExecutor: context.desktopOperationExecutor,
                    operationFinalizer: context.operationFinalizer)
            },
            exactWindowFocusReader: { _ in
                ExactWindowFocusSnapshot(
                    processIdentifier: focused.processIdentifier,
                    windowID: focused.windowID,
                    frame: focused.frame,
                    role: focused.role,
                    title: focused.title,
                    identifier: focused.identifier)
            },
            exactFocusedElementReader: { _ in
                .success(ExactWindowFocusSnapshot(
                    processIdentifier: focused.processIdentifier,
                    windowID: focused.windowID,
                    frame: focused.frame,
                    role: focused.role,
                    title: focused.title,
                    identifier: focused.identifier))
            },
            exactWindowIdentityValidator: { identity, bounds in
                identity == windowIdentity && bounds == windowIdentity.capturedBounds
            },
            processStartIdentityProvider: { _ in generation })
    }

    private static var foregroundOutcome: DesktopActionOutcome {
        .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
    }

    private static var backgroundOutcome: DesktopActionOutcome {
        .dispatchedUnverified(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            evidence: .deliveryAccepted)
    }

    private static var windowBackgroundOutcome: DesktopActionOutcome {
        .dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted)
    }

    private static func outcome(
        mechanism: DesktopActionOutcome.Delivery.Mechanism,
        mode: DesktopActionOutcome.Delivery.Mode) -> DesktopActionOutcome
    {
        .confirmedChange(
            delivery: .init(mechanism: mechanism, mode: mode),
            unitCount: DesktopActionOutcome.DispatchUnitCount(1))
    }
}

@MainActor
private final class OutcomeSyntheticInputDriver: SyntheticInputDriving {
    private let clickOutcome: DesktopActionOutcome
    private(set) var clickCount = 0
    private(set) var scrollCount = 0
    private(set) var typedTexts: [String] = []

    init(clickOutcome: DesktopActionOutcome) {
        self.clickOutcome = clickOutcome
    }

    func click(at _: CGPoint, button _: MouseButton, count _: Int) throws -> DesktopActionOutcome {
        self.clickCount += 1
        return self.clickOutcome
    }

    func click(
        at _: CGPoint,
        button _: MouseButton,
        count _: Int,
        targetProcessIdentifier _: pid_t) async throws -> DesktopActionOutcome
    {
        self.clickCount += 1
        return self.clickOutcome
    }

    func click(
        at _: CGPoint,
        button _: MouseButton,
        count _: Int,
        targetProcessIdentifier _: pid_t,
        targetWindowID _: CGWindowID?) async throws -> DesktopActionOutcome
    {
        self.clickCount += 1
        return self.clickOutcome
    }

    func move(to _: CGPoint) throws {}

    func currentLocation() -> CGPoint? {
        CGPoint(x: 10, y: 10)
    }

    func pressHold(at _: CGPoint, button _: MouseButton, duration _: TimeInterval) async throws {}

    func scroll(deltaX _: Double, deltaY _: Double, at _: CGPoint?) throws {
        self.scrollCount += 1
    }

    func type(_ text: String, delayPerCharacter _: TimeInterval) throws {
        self.typedTexts.append(text)
    }

    func tapKey(_: SpecialKey, modifiers _: CGEventFlags) throws {}

    func hotkey(keys _: [String], holdDuration _: TimeInterval) throws {}
}

@MainActor
private final class OutcomeActionInputDriver: ActionInputDriving {
    private let outcome: DesktopActionOutcome
    private(set) var hotkeyCount = 0
    private(set) var setValueCount = 0
    private(set) var performActionCount = 0
    private(set) var storedValue: String?

    init(outcome: DesktopActionOutcome, storedValue: String? = nil) {
        self.outcome = outcome
        self.storedValue = storedValue
    }

    func tryClick(element _: AutomationElement) throws -> UIInputExecutionResult.Action {
        UIInputExecutionResult.Action(outcome: self.outcome)
    }

    func tryRightClick(element _: any AutomationElementRepresenting) async throws
        -> UIInputExecutionResult.Action
    {
        UIInputExecutionResult.Action(outcome: self.outcome)
    }

    func tryScroll(
        element _: AutomationElement,
        direction _: ScrollDirection,
        pages _: Int) throws -> UIInputExecutionResult.Action
    {
        UIInputExecutionResult.Action(outcome: self.outcome)
    }

    func trySetText(element _: AutomationElement, text _: String, replace _: Bool) throws
        -> UIInputExecutionResult.Action
    {
        UIInputExecutionResult.Action(outcome: self.outcome)
    }

    func tryHotkey(application _: NSRunningApplication, keys _: [String]) throws
        -> UIInputExecutionResult.Action
    {
        self.hotkeyCount += 1
        return UIInputExecutionResult.Action(outcome: self.outcome)
    }

    func trySetValue(element _: AutomationElement, value: UIElementValue) throws
        -> UIInputExecutionResult.Action
    {
        self.setValueCount += 1
        self.storedValue = value.displayString
        return UIInputExecutionResult.Action(
            outcome: self.outcome,
            actionName: "AXSetValue")
    }

    func tryPerformAction(element _: AutomationElement, actionName: String) throws
        -> UIInputExecutionResult.Action
    {
        self.performActionCount += 1
        return UIInputExecutionResult.Action(
            outcome: self.outcome,
            actionName: actionName)
    }
}

@MainActor
private struct FixedOutcomeAutomationElementResolver: AutomationElementResolving {
    private let element = AutomationElement(Element(AXUIElementCreateApplication(getpid())))

    func resolve(detectedElement _: DetectedElement, windowContext _: WindowContext?) -> AutomationElement? {
        self.element
    }

    func resolve(query _: String, windowContext _: WindowContext?, requireTextInput _: Bool) -> AutomationElement? {
        self.element
    }
}

private final class TargetedWindowTracker: WindowTrackingProviding, @unchecked Sendable {
    private let windowID: CGWindowID
    private let bounds: CGRect
    private let processIdentifier: pid_t

    init(windowID: CGWindowID, bounds: CGRect, processIdentifier: pid_t) {
        self.windowID = windowID
        self.bounds = bounds
        self.processIdentifier = processIdentifier
    }

    @MainActor
    func windowBounds(for windowID: CGWindowID) -> CGRect? {
        windowID == self.windowID ? self.bounds : nil
    }

    @MainActor
    func windowOwnerProcessIdentifier(for windowID: CGWindowID) -> pid_t? {
        windowID == self.windowID ? self.processIdentifier : nil
    }

    @MainActor
    func refreshWindow(for _: CGWindowID) {}
}
