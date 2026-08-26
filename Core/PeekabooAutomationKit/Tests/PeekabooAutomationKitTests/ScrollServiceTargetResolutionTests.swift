import AppKit
import ApplicationServices
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import struct PeekabooFoundation.DesktopActionFailure
import struct PeekabooFoundation.DesktopActionOutcome
import enum PeekabooFoundation.PeekabooError
import enum PeekabooFoundation.ScrollDirection
import PeekabooFoundationTestSupport
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
    func `foreground synthetic scroll reports exact emitted tick count`() async throws {
        let synthetic = ScrollRecordingSyntheticInputDriver()
        let service = ScrollService(syntheticInputDriver: synthetic)

        let regular = try await service.scroll(ScrollRequest(
            direction: .down,
            amount: 3,
            foreground: true))
        let smooth = try await service.scroll(ScrollRequest(
            direction: .down,
            amount: 3,
            smooth: true,
            foreground: true))
        let zero = try await service.scroll(ScrollRequest(
            direction: .down,
            amount: 0,
            foreground: true))

        #expect(regular.outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(smooth.outcome.dispatchState.unitCount?.rawValue == 30)
        #expect(zero.outcome.state == .confirmedNoChange)
        #expect(zero.outcome.dispatchState == .none)
        #expect(synthetic.events.filter {
            if case .scroll = $0 {
                true
            } else {
                false
            }
        }.count == 33)
    }

    @Test
    @MainActor
    func `background targeted scroll uses only Accessibility action`() async throws {
        let element = DetectedElement(
            id: "S1",
            type: .other,
            label: "List",
            bounds: .init(x: 20, y: 30, width: 300, height: 400))
        let detectionResult = Self.exactDetectionResult(element: element)
        let action = ScrollRecordingActionInputDriver()
        let synthetic = ScrollRecordingSyntheticInputDriver()
        let service = try await ScrollService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            actionInputDriver: action,
            syntheticInputDriver: synthetic,
            automationElementResolver: ScrollFixedAutomationElementResolver(),
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 11 })

        let result = try await service.scroll(ScrollRequest(
            direction: .down,
            amount: 3,
            target: "S1",
            snapshotId: Self.snapshotID))

        #expect(result.path == .action)
        #expect(result.strategy == .actionOnly)
        #expect(action.scrollCalls == [.init(direction: .down, pages: 3)])
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `unsupported AX group uses exact WebKit wheel route without global synthesis`() async throws {
        let laneRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-scroll-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: laneRoot) }
        let element = DetectedElement(
            id: "S1",
            type: .group,
            label: "Web content",
            bounds: CGRect(x: 20, y: 30, width: 300, height: 400),
            attributes: ["role": "AXGroup"])
        let detectionResult = Self.exactDetectionResult(element: element)
        let identity = try #require(detectionResult.metadata.windowContext?.windowMutationIdentity)
        let bounds = try #require(detectionResult.metadata.windowContext?.windowBounds)
        let point = CGPoint(x: element.bounds.midX, y: element.bounds.midY)
        var posted = 0
        let routedDriver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in .init(identity: identity, bounds: bounds, screenPoint: point) },
            routeIsCurrent: { _ in true },
            makeScrollEvent: { _, _ in
                CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .line,
                    wheelCount: 1,
                    wheel1: -1,
                    wheel2: 0,
                    wheel3: 0)
            },
            stampWindowLocation: { _, _ in true },
            postSkyLight: { _, _ in true },
            postPublic: { _, _ in posted += 1 },
            resolveTransport: { _ in .publicCGEvent },
            applicationIsVisible: { _ in true },
            windowIsVisible: { _ in true },
            sleep: { _ in })
        let action = ScrollRecordingActionInputDriver(
            scrollError: ActionInputError.unsupported(.actionUnsupported))
        let synthetic = ScrollRecordingSyntheticInputDriver()
        let service = try await ScrollService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            actionInputDriver: action,
            syntheticInputDriver: synthetic,
            automationElementResolver: ScrollFixedAutomationElementResolver(),
            windowRoutedPointerDriver: routedDriver,
            backgroundWheelCapability: { _ in true },
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 11 },
            desktopOperationExecutor: DesktopOperationExecutor(
                laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: laneRoot)))

        let result = try await service.scroll(ScrollRequest(
            direction: .down,
            amount: 2,
            target: "S1",
            snapshotId: Self.snapshotID))

        #expect(result.path == .action)
        #expect(result.actionName == "WindowRoutedWheel")
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.delivery == .init(mechanism: .windowTargetedEvents, mode: .background))
        #expect(result.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(result.outcome.retrySafety == .unsafe)
        #expect(posted == 2)
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `typed AX prefix failure never falls through to exact window wheel`() async throws {
        let element = DetectedElement(
            id: "S1",
            type: .group,
            label: "Web content",
            bounds: CGRect(x: 20, y: 30, width: 300, height: 400),
            attributes: ["role": "AXGroup"])
        let detectionResult = Self.exactDetectionResult(element: element)
        let identity = try #require(detectionResult.metadata.windowContext?.windowMutationIdentity)
        let bounds = try #require(detectionResult.metadata.windowContext?.windowBounds)
        let point = CGPoint(x: element.bounds.midX, y: element.bounds.midY)
        var posted = 0
        let routedDriver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in .init(identity: identity, bounds: bounds, screenPoint: point) },
            routeIsCurrent: { _ in true },
            makeScrollEvent: { _, _ in
                CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .line,
                    wheelCount: 1,
                    wheel1: -1,
                    wheel2: 0,
                    wheel3: 0)
            },
            stampWindowLocation: { _, _ in true },
            postSkyLight: { _, _ in true },
            postPublic: { _, _ in posted += 1 },
            resolveTransport: { _ in .publicCGEvent },
            applicationIsVisible: { _ in true },
            windowIsVisible: { _ in true },
            sleep: { _ in })
        let prefixFailure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            unitCount: .one,
            message: "One of three AX page units was accepted")
        let service = try await ScrollService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            actionInputDriver: ScrollRecordingActionInputDriver(scrollError: prefixFailure),
            automationElementResolver: ScrollFixedAutomationElementResolver(),
            windowRoutedPointerDriver: routedDriver,
            backgroundWheelCapability: { _ in true },
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 11 })

        do {
            _ = try await service.scroll(ScrollRequest(
                direction: .down,
                amount: 3,
                target: "S1",
                snapshotId: Self.snapshotID))
            Issue.record("Expected the AX prefix failure to remain authoritative")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .partial)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        #expect(posted == 0)
    }

    @Test
    @MainActor
    func `unsupported AX group refuses when application lacks WebKit capability`() async throws {
        let laneRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-scroll-refusal-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: laneRoot) }
        let element = DetectedElement(
            id: "S1",
            type: .group,
            label: "Opaque panel",
            bounds: CGRect(x: 20, y: 30, width: 300, height: 400),
            attributes: ["role": "AXGroup"])
        let action = ScrollRecordingActionInputDriver(
            scrollError: ActionInputError.unsupported(.actionUnsupported))
        let service = try await ScrollService(
            snapshotManager: InMemorySnapshotManager.containing(
                Self.exactDetectionResult(element: element)),
            actionInputDriver: action,
            automationElementResolver: ScrollFixedAutomationElementResolver(),
            backgroundWheelCapability: { _ in false },
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 11 },
            desktopOperationExecutor: DesktopOperationExecutor(
                laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: laneRoot)))

        do {
            _ = try await service.scroll(Self.backgroundRequest())
            Issue.record("Expected foreground-required refusal")
        } catch let error as PeekabooError {
            #expect(error.localizedDescription.contains("foreground"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(action.scrollCalls.count == 1)
    }

    @Test
    func `window-routed wheel requires pixel-backed container evidence`() {
        let element = DetectedElement(
            id: "S1",
            type: .group,
            label: "Web content",
            bounds: CGRect(x: 20, y: 30, width: 300, height: 400),
            attributes: ["role": "AXGroup"])

        #expect(ScrollService.supportsWindowRoutedWheelTarget(element, screenshotPath: "/tmp/shot.png"))
        #expect(!ScrollService.supportsWindowRoutedWheelTarget(element, screenshotPath: ""))
        #expect(!ScrollService.supportsWindowRoutedWheelTarget(
            DetectedElement(id: "B1", type: .button, label: "Button", bounds: element.bounds),
            screenshotPath: "/tmp/shot.png"))
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
                snapshotId: SnapshotReferenceFixtures.first.rawValue))
            Issue.record("Expected stale element error for missing action snapshot.")
        } catch let error as PeekabooError {
            #expect(error.localizedDescription.contains("snapshot"))
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
    func `foreground OCR target refuses before pointer motion or scroll dispatch`() async throws {
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
            snapshotId: Self.snapshotID,
            screenshotPath: "/tmp/calendar.png",
            elements: DetectedElements(other: [element]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 1, method: "AXorcist+OCR"))
        let synthetic = ScrollRecordingSyntheticInputDriver()
        let service = try await ScrollService(
            snapshotManager: InMemorySnapshotManager.containing(result),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthFirst),
            syntheticInputDriver: synthetic)

        do {
            try await service.scroll(ScrollRequest(
                direction: .down,
                amount: 1,
                target: "ocr_1",
                smooth: true,
                snapshotId: Self.snapshotID,
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
        let detectionResult = Self.exactDetectionResult(element: element)
        let synthetic = ScrollRecordingSyntheticInputDriver()
        let service = try await ScrollService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic,
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 11 })

        do {
            try await service.scroll(ScrollRequest(
                direction: .down,
                amount: 1,
                target: "S1",
                smooth: false,
                delay: 0,
                snapshotId: Self.snapshotID))
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
            snapshotId: Self.snapshotID)))
        #expect(ScrollService.requiresSyntheticScrollSemantics(ScrollRequest(
            direction: .down,
            amount: 3,
            target: "S1",
            smooth: true,
            delay: 0,
            snapshotId: Self.snapshotID,
            foreground: true)))
        #expect(!ScrollService.requiresSyntheticScrollSemantics(ScrollRequest(
            direction: .down,
            amount: 3,
            target: "S1",
            smooth: false,
            delay: 2,
            snapshotId: Self.snapshotID)))
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
            #expect(error.localizedDescription.contains("target"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    @MainActor
    func `background scroll refuses incomplete exact receipt before dispatch`() async throws {
        let element = DetectedElement(
            id: "S1",
            type: .other,
            label: "List",
            bounds: CGRect(x: 20, y: 30, width: 300, height: 400))
        let detectionResult = ElementDetectionResult(
            snapshotId: Self.snapshotID,
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(other: [element]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 1, method: "test"))
        let action = ScrollRecordingActionInputDriver()
        let synthetic = ScrollRecordingSyntheticInputDriver()
        let service = try await ScrollService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            actionInputDriver: action,
            syntheticInputDriver: synthetic,
            automationElementResolver: ScrollFixedAutomationElementResolver())

        await #expect(throws: PeekabooError.self) {
            _ = try await service.scroll(Self.backgroundRequest())
        }
        #expect(action.scrollCalls.isEmpty)
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `background scroll refuses conflicting capture bounds before dispatch`() async throws {
        let element = Self.scrollElement()
        let detectionResult = Self.exactDetectionResult(
            element: element,
            identityBounds: CGRect(x: 0, y: 0, width: 700, height: 600))
        let action = ScrollRecordingActionInputDriver()
        let service = try await ScrollService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            actionInputDriver: action,
            automationElementResolver: ScrollFixedAutomationElementResolver(),
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 11 })

        let error = await #expect(throws: SnapshotTargetReceiptPreDispatchError.self) {
            _ = try await service.scroll(Self.backgroundRequest())
        }
        #expect(error?.receiptError == .contradictoryWindowBounds)
        #expect(action.scrollCalls.isEmpty)
    }

    @Test
    @MainActor
    func `background scroll revalidates generation after element resolution`() async throws {
        let generation = ScrollLockedValue<UInt64>(11)
        let action = ScrollRecordingActionInputDriver()
        let service = try await ScrollService(
            snapshotManager: InMemorySnapshotManager.containing(Self.exactDetectionResult(
                element: Self.scrollElement())),
            actionInputDriver: action,
            automationElementResolver: ScrollFixedAutomationElementResolver {
                generation.value = 12
            },
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in generation.value })

        await #expect(throws: PeekabooError.self) {
            _ = try await service.scroll(Self.backgroundRequest())
        }
        #expect(action.scrollCalls.isEmpty)
    }

    @Test
    @MainActor
    func `background scroll refuses window drift after element resolution`() async throws {
        let windowIsCurrent = ScrollLockedValue(true)
        let action = ScrollRecordingActionInputDriver()
        let service = try await ScrollService(
            snapshotManager: InMemorySnapshotManager.containing(Self.exactDetectionResult(
                element: Self.scrollElement())),
            actionInputDriver: action,
            automationElementResolver: ScrollFixedAutomationElementResolver {
                windowIsCurrent.value = false
            },
            exactWindowIdentityValidator: { _, _ in windowIsCurrent.value },
            processStartIdentityProvider: { _ in 11 })

        await #expect(throws: PeekabooError.self) {
            _ = try await service.scroll(Self.backgroundRequest())
        }
        #expect(action.scrollCalls.isEmpty)
    }

    @Test
    @MainActor
    func `background scroll reports post-dispatch generation drift as retry unsafe`() async throws {
        let generation = ScrollLockedValue<UInt64>(11)
        let action = ScrollRecordingActionInputDriver {
            generation.value = 12
        }
        let service = try await ScrollService(
            snapshotManager: InMemorySnapshotManager.containing(Self.exactDetectionResult(
                element: Self.scrollElement())),
            actionInputDriver: action,
            automationElementResolver: ScrollFixedAutomationElementResolver(),
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in generation.value })

        do {
            _ = try await service.scroll(Self.backgroundRequest())
            Issue.record("Expected post-dispatch process-generation drift")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.mutationDispatched)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(action.scrollCalls == [.init(direction: .down, pages: 1)])
    }

    @Test
    @MainActor
    func `background scroll owns its exact process lane`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scroll-process-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let identity = ApplicationProcessIdentity(processIdentifier: getpid(), processStartIdentity: 11)
        let service = try await ScrollService(
            snapshotManager: InMemorySnapshotManager.containing(Self.exactDetectionResult(
                element: Self.scrollElement())),
            actionInputDriver: ScrollRecordingActionInputDriver(),
            automationElementResolver: ScrollFixedAutomationElementResolver(),
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 11 },
            desktopOperationExecutor: DesktopOperationExecutor(laneCoordinator: coordinator))

        _ = try await service.scrollWithLanePreparation(Self.backgroundRequest()) {
            await #expect(throws: DesktopOperationLaneError.self) {
                try await coordinator.run(scope: .process(identity), access: .write) { true }
            }
        }
    }

    private static let snapshotID = SnapshotReferenceFixtures.first.rawValue

    private static func backgroundRequest() -> ScrollRequest {
        ScrollRequest(direction: .down, amount: 1, target: "S1", snapshotId: self.snapshotID)
    }

    private static func scrollElement() -> DetectedElement {
        DetectedElement(
            id: "S1",
            type: .other,
            label: "List",
            bounds: CGRect(x: 20, y: 30, width: 300, height: 400))
    }

    private static func exactDetectionResult(
        element: DetectedElement,
        processIdentifier: pid_t = getpid(),
        processStartIdentity: UInt64 = 11,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
        identityBounds: CGRect? = nil) -> ElementDetectionResult
    {
        let capturedBounds = identityBounds ?? bounds
        return ElementDetectionResult(
            snapshotId: Self.snapshotID,
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(other: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(
                    applicationBundleId: "com.example.ScrollTarget",
                    applicationProcessId: processIdentifier,
                    windowID: 42,
                    windowBounds: bounds,
                    windowMutationIdentity: WindowMutationIdentity(
                        windowID: 42,
                        ownerProcessIdentifier: processIdentifier,
                        ownerProcessStartIdentity: processStartIdentity,
                        capturedBounds: capturedBounds))))
    }
}

@MainActor
private final class ScrollFixedAutomationElementResolver: AutomationElementResolving {
    private let element = AutomationElement(Element(AXUIElementCreateApplication(getpid())))
    private let afterResolve: @MainActor () -> Void

    init(afterResolve: @escaping @MainActor () -> Void = {}) {
        self.afterResolve = afterResolve
    }

    func resolve(detectedElement _: DetectedElement, windowContext _: WindowContext?) -> AutomationElement? {
        self.afterResolve()
        return self.element
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
    private let afterScroll: @MainActor () -> Void
    private let scrollError: (any Error)?

    init(
        afterScroll: @escaping @MainActor () -> Void = {},
        scrollError: (any Error)? = nil)
    {
        self.afterScroll = afterScroll
        self.scrollError = scrollError
    }

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
        self.afterScroll()
        if let scrollError {
            throw scrollError
        }
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

private final class ScrollLockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        self.storedValue = value
    }

    var value: Value {
        get { self.lock.withLock { self.storedValue } }
        set { self.lock.withLock { self.storedValue = newValue } }
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
