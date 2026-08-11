import AppKit
import ApplicationServices
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import struct PeekabooFoundation.DesktopActionOutcome
import enum PeekabooFoundation.PeekabooError
import enum PeekabooFoundation.ScrollDirection
import Testing
@testable import PeekabooAutomationKit

struct ScrollServiceTargetResolutionTests {
    @Test
    func `legacy scroll payload decodes as background with zero delay`() throws {
        let data = Data(#"{"direction":"down","amount":3,"target":"S1","smooth":false}"#.utf8)

        let request = try JSONDecoder().decode(ScrollRequest.self, from: data)

        #expect(!request.foreground)
        #expect(request.delay == 0)
    }

    @Test
    @MainActor
    func `background targeted scroll uses only Accessibility action`() async throws {
        let element = DetectedElement(
            id: "S1",
            type: .other,
            label: "List",
            bounds: .init(x: 20, y: 30, width: 300, height: 400))
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(other: [element]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "test"))
        let action = ScrollRecordingActionInputDriver()
        let synthetic = ScrollRecordingSyntheticInputDriver()
        let service = ScrollService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            actionInputDriver: action,
            syntheticInputDriver: synthetic,
            automationElementResolver: ScrollFixedAutomationElementResolver())

        let result = try await service.scroll(ScrollRequest(
            direction: .down,
            amount: 3,
            target: "S1",
            snapshotId: "snapshot"))

        #expect(result.path == .action)
        #expect(result.strategy == .actionOnly)
        #expect(action.scrollCalls == [.init(direction: .down, pages: 3)])
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `action-first missing snapshot fails as stale instead of falling back`() async {
        let service = ScrollService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst))

        do {
            try await service.scroll(ScrollRequest(
                direction: .down,
                amount: 1,
                target: "S1",
                smooth: false,
                delay: 0,
                snapshotId: "missing"))
            Issue.record("Expected stale element error for missing action snapshot.")
        } catch let error as ActionInputError {
            #expect(error == .staleElement)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    @MainActor
    func `synthetic scroll treats explicit missing snapshot as authoritative`() async {
        let synthetic = ScrollRecordingSyntheticInputDriver()
        let service = ScrollService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthFirst),
            syntheticInputDriver: synthetic)

        do {
            try await service.scroll(ScrollRequest(
                direction: .down,
                amount: 1,
                target: "missing-\(UUID().uuidString)",
                smooth: false,
                delay: 2,
                snapshotId: "missing",
                foreground: true))
            Issue.record("Expected stale element error for missing synthetic snapshot.")
        } catch let error as ActionInputError {
            #expect(error == .staleElement)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `foreground OCR target refuses before pointer motion or scroll dispatch`() async {
        let element = DetectedElement(
            id: "ocr_1",
            type: .staticText,
            label: "August",
            bounds: CGRect(x: 10, y: 20, width: 100, height: 20),
            attributes: [
                "description": "ocr",
                "confidence": "0.93",
            ])
        let result = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/calendar.png",
            elements: DetectedElements(other: [element]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 1, method: "AXorcist+OCR"))
        let synthetic = ScrollRecordingSyntheticInputDriver()
        let service = ScrollService(
            snapshotManager: InMemorySnapshotManager(detectionResult: result),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthFirst),
            syntheticInputDriver: synthetic)

        do {
            try await service.scroll(ScrollRequest(
                direction: .down,
                amount: 1,
                target: "ocr_1",
                smooth: true,
                snapshotId: "snapshot",
                foreground: true))
            Issue.record("Expected OCR semantic evidence refusal")
        } catch let PeekabooError.invalidInput(message) {
            #expect(message.contains("semantic evidence"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `background unresolved snapshot target requires foreground without synthetic fallback`() async throws {
        let element = DetectedElement(
            id: "S1",
            type: .other,
            label: "peekaboo-unresolved-scroll-target-\(UUID().uuidString)",
            value: nil,
            bounds: .init(x: 200, y: 240, width: 60, height: 40),
            isEnabled: true,
            isSelected: nil,
            attributes: [:])
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(other: [element]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "test"))
        let synthetic = ScrollRecordingSyntheticInputDriver()
        let service = ScrollService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic)

        do {
            try await service.scroll(ScrollRequest(
                direction: .down,
                amount: 1,
                target: "S1",
                smooth: false,
                delay: 0,
                snapshotId: "snapshot"))
            Issue.record("Expected an explicit foreground-required error")
        } catch let error as PeekabooError {
            #expect(error.localizedDescription.contains("foreground"))
        }

        #expect(synthetic.events.isEmpty)
    }

    @Test
    func `action-first scroll preserves explicit page count`() {
        #expect(ScrollService.actionScrollPages(amount: 3, strategy: .actionFirst) == 3)
        #expect(ScrollService.actionScrollPages(amount: -3, strategy: .actionFirst) == 3)
        #expect(ScrollService.actionScrollPages(amount: 0, strategy: .actionFirst) == 1)
    }

    @Test
    func `only explicit foreground enables synthetic scroll semantics`() {
        #expect(!ScrollService.requiresSyntheticScrollSemantics(ScrollRequest(
            direction: .down,
            amount: 3,
            target: "S1",
            smooth: false,
            delay: 0,
            snapshotId: "snapshot")))
        #expect(ScrollService.requiresSyntheticScrollSemantics(ScrollRequest(
            direction: .down,
            amount: 3,
            target: "S1",
            smooth: true,
            delay: 0,
            snapshotId: "snapshot",
            foreground: true)))
        #expect(!ScrollService.requiresSyntheticScrollSemantics(ScrollRequest(
            direction: .down,
            amount: 3,
            target: "S1",
            smooth: false,
            delay: 2,
            snapshotId: "snapshot")))
    }

    @Test
    func `action-only scroll preserves explicit page count`() {
        #expect(ScrollService.actionScrollPages(amount: 3, strategy: .actionOnly) == 3)
        #expect(ScrollService.actionScrollPages(amount: -3, strategy: .actionOnly) == 3)
        #expect(ScrollService.actionScrollPages(amount: 0, strategy: .actionOnly) == 1)
    }

    @Test
    @MainActor
    func `action-only scroll without target reports unsupported action`() async {
        let service = ScrollService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly))

        do {
            try await service.scroll(ScrollRequest(
                direction: .down,
                amount: 1,
                target: "   ",
                smooth: false,
                delay: 0,
                snapshotId: nil))
            Issue.record("Expected unsupported action error for targetless action-only scroll.")
        } catch let error as PeekabooError {
            #expect(error.localizedDescription.contains("foreground"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@MainActor
private final class ScrollFixedAutomationElementResolver: AutomationElementResolving {
    private let element = AutomationElement(Element(AXUIElementCreateApplication(getpid())))

    func resolve(detectedElement _: DetectedElement, windowContext _: WindowContext?) -> AutomationElement? {
        self.element
    }

    func resolve(query _: String, windowContext _: WindowContext?, requireTextInput _: Bool) -> AutomationElement? {
        self.element
    }
}

@MainActor
private final class ScrollRecordingActionInputDriver: ActionInputDriving {
    struct ScrollCall: Equatable {
        let direction: PeekabooFoundation.ScrollDirection
        let pages: Int
    }

    private(set) var scrollCalls: [ScrollCall] = []

    func tryClick(element _: AutomationElement) throws -> UIInputExecutionResult.Action {
        AutomationTestFixtures.uiActionReceipt()
    }

    func tryRightClick(element _: any AutomationElementRepresenting) async throws
        -> UIInputExecutionResult.Action
    {
        AutomationTestFixtures.uiActionReceipt()
    }

    func tryScroll(
        element _: AutomationElement,
        direction: PeekabooFoundation.ScrollDirection,
        pages: Int) throws -> UIInputExecutionResult.Action
    {
        self.scrollCalls.append(.init(direction: direction, pages: pages))
        return AutomationTestFixtures.uiActionReceipt(actionName: "AXScroll", elementRole: "AXScrollArea")
    }

    func trySetText(element _: AutomationElement, text _: String, replace _: Bool) throws
        -> UIInputExecutionResult.Action
    {
        AutomationTestFixtures.uiActionReceipt()
    }

    func tryHotkey(application _: NSRunningApplication, keys _: [String]) throws
        -> UIInputExecutionResult.Action
    {
        AutomationTestFixtures.uiActionReceipt()
    }

    func trySetValue(element _: AutomationElement, value _: UIElementValue) throws
        -> UIInputExecutionResult.Action
    {
        AutomationTestFixtures.uiActionReceipt()
    }

    func tryPerformAction(element _: AutomationElement, actionName _: String) throws
        -> UIInputExecutionResult.Action
    {
        AutomationTestFixtures.uiActionReceipt()
    }
}

@MainActor
private final class ScrollRecordingSyntheticInputDriver: SyntheticInputDriving {
    enum Event: Equatable {
        case click(point: CGPoint, button: MouseButton, count: Int)
        case move(CGPoint)
        case currentLocation
        case scroll(deltaX: Double, deltaY: Double, at: CGPoint?)
    }

    private(set) var events: [Event] = []

    func click(at point: CGPoint, button: MouseButton, count: Int) throws -> DesktopActionOutcome {
        self.events.append(.click(point: point, button: button, count: count))
        return AutomationTestFixtures.uiActionReceipt().outcome
    }

    func click(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        targetProcessIdentifier _: pid_t) async throws -> DesktopActionOutcome
    {
        self.events.append(.click(point: point, button: button, count: count))
        return AutomationTestFixtures.uiActionReceipt().outcome
    }

    func move(to point: CGPoint) throws {
        self.events.append(.move(point))
    }

    func currentLocation() -> CGPoint? {
        self.events.append(.currentLocation)
        return nil
    }

    func pressHold(at _: CGPoint, button _: MouseButton, duration _: TimeInterval) async throws {}

    func scroll(deltaX: Double, deltaY: Double, at point: CGPoint?) throws {
        self.events.append(.scroll(deltaX: deltaX, deltaY: deltaY, at: point))
    }

    func type(_: String, delayPerCharacter _: TimeInterval) throws {}

    func tapKey(_: SpecialKey, modifiers _: CGEventFlags) throws {}

    func hotkey(keys _: [String], holdDuration _: TimeInterval) throws {}
}
