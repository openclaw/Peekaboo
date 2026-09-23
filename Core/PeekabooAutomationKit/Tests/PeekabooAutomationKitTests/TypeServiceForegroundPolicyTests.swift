import AppKit
import ApplicationServices
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
    @Test
    func `built-in named legacy replacement uses AX without synthetic input`() async throws {
        let fixture = try await ForegroundTypePolicyFixture(policy: .currentBehavior)
        defer { fixture.cleanup() }

        let result = try await fixture.service.type(
            text: "after",
            target: "Input",
            clearExisting: true,
            typingDelay: 0,
            snapshotId: fixture.snapshotID)

        #expect(result.strategy == .actionFirst)
        #expect(result.path == .action)
        #expect(result.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
        #expect(fixture.action.replacementFlags == [true])
        #expect(fixture.action.field.setValues == [.string("after")])
        #expect(fixture.action.field.stringValue == "after")
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

        #expect(result.strategy == .actionFirst)
        #expect(result.path == .synth)
        #expect(result.fallbackReason == .missingElement)
        #expect(result.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
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
        #expect(fixture.action.replacementFlags.isEmpty)
        #expect(fixture.action.field.setValues.isEmpty)
        #expect(fixture.synthetic.events == Self.clearAndTypeEvents)
        #expect(fixture.synthetic.pointer.events.isEmpty)
    }

    @Test(arguments: [UIInputStrategy.synthFirst, .synthOnly])
    func `explicit synthetic strategy keeps named legacy replacement synthetic`(
        strategy: UIInputStrategy) async throws
    {
        let fixture = try await ForegroundTypePolicyFixture(policy: UIInputPolicy(defaultStrategy: strategy))
        defer { fixture.cleanup() }

        let result = try await fixture.service.type(
            text: "ab",
            target: "Input",
            clearExisting: true,
            typingDelay: 0,
            snapshotId: fixture.snapshotID)

        #expect(result.strategy == strategy)
        #expect(result.path == .synth)
        #expect(result.fallbackReason == nil)
        #expect(result.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
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
    let service: TypeService
    private let coordinationRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("foreground-type-policy-\(UUID().uuidString)", isDirectory: true)

    init(policy: UIInputPolicy) async throws {
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
            automationElementResolver: ForegroundTypeElementResolver(),
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            desktopOperationExecutor: DesktopOperationExecutor(laneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: self.coordinationRoot)))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.coordinationRoot)
    }
}

@MainActor
private struct ForegroundTypeElementResolver: AutomationElementResolving {
    /// Cached role metadata keeps secure-field classification entirely in memory.
    private let element = AutomationElement(Element(
        AXUIElementCreateApplication(getpid()),
        attributes: ["AXRole": .string("AXTextField"), "AXSubrole": .string("AXUnknown")],
        children: [],
        actions: []))

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
private final class ForegroundTypeActionDriver: ActionInputDriving {
    let field = ActionInputMockAutomationElement(role: "AXTextField", value: "before", isValueSettable: true)
    private let unexpected = RecordingActionInputDriver()
    private(set) var replacementFlags: [Bool] = []

    func trySetText(element _: AutomationElement, text: String, replace: Bool) throws -> UIInputExecutionResult.Action {
        self.replacementFlags.append(replace)
        try self.field.setAutomationValue(.string(text))
        return UIInputExecutionResult.Action(
            outcome: .confirmedChange(delivery: .init(mechanism: .accessibilityValue, mode: .background)),
            actionName: "AXSetValue",
            elementRole: "AXTextField")
    }

    func tryClick(element: AutomationElement) throws -> UIInputExecutionResult.Action {
        try self.unexpected.tryClick(element: element)
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

    func trySetValue(element: AutomationElement, value: UIElementValue) throws -> UIInputExecutionResult.Action {
        try self.unexpected.trySetValue(element: element, value: value)
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
