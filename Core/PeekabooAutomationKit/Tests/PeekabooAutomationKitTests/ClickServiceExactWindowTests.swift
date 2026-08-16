import AXorcist
import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import enum PeekabooFoundation.ClickType
import struct PeekabooFoundation.DesktopActionFailure
import struct PeekabooFoundation.DesktopActionOutcome
import enum PeekabooFoundation.PeekabooError
import Testing
@testable import PeekabooAutomationKit

struct ClickServiceExactWindowTests {
    @Test
    @MainActor
    func `Middle and triple clicks use only the exact-window routed synthesis owner`() async throws {
        let identity = try WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: #require(SystemIdentityResolver.processStartIdentity(getpid())),
            capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let cases: [(ClickType, MouseButton, Int, Int)] = [
            (.middle, .middle, 1, 3),
            (.triple, .left, 3, 7),
        ]

        for (clickType, button, count, units) in cases {
            let outcome = DesktopActionOutcome.dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(units))
            let synthetic = ClickRecordingSyntheticInputDriver(targetedClickOutcome: outcome)
            let service = ClickService(
                snapshotManager: InMemorySnapshotManager(),
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                syntheticInputDriver: synthetic,
                exactWindowIdentityValidator: { candidate, bounds in
                    candidate == identity && bounds == identity.capturedBounds
                })

            let result = try await service.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: clickType,
                snapshotId: nil,
                automationTarget: .exactWindow(.init(
                    identity: identity,
                    bounds: #require(identity.capturedBounds))),
                validatesProcessIdentity: true)

            #expect(result.path == .synth)
            #expect(result.outcome == outcome)
            #expect(result.outcome.dispatchState.unitCount?.rawValue == units)
            #expect(synthetic.events == [
                .targetedClick(
                    point: CGPoint(x: 10, y: 20),
                    button: button,
                    count: count,
                    targetProcessIdentifier: identity.ownerProcessIdentifier,
                    targetWindowID: CGWindowID(identity.windowID)),
            ])
        }
    }

    @Test
    @MainActor
    func `Middle and triple process-only requests refuse before synthesis`() async {
        for clickType in [ClickType.middle, .triple] {
            let synthetic = ClickRecordingSyntheticInputDriver()
            let service = ClickService(
                snapshotManager: InMemorySnapshotManager(),
                inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                syntheticInputDriver: synthetic)

            await #expect(throws: PeekabooError.self) {
                _ = try await service.click(
                    target: .elementId("B1"),
                    clickType: clickType,
                    snapshotId: nil,
                    targetProcessIdentifier: 12345)
            }
            #expect(synthetic.events.isEmpty)
        }
    }

    @Test
    @MainActor
    func `Snapshot refinement cannot replace the caller process generation`() async throws {
        let pinnedProcess = AutomationTestFixtures.processIdentity(
            processIdentifier: getpid(),
            processStartIdentity: 71)
        let replacementProcess = AutomationTestFixtures.processIdentity(
            processIdentifier: getpid(),
            processStartIdentity: 72)
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let detection = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [DetectedElement(
                id: "B1",
                type: .button,
                label: "Button",
                bounds: CGRect(x: 20, y: 30, width: 100, height: 40))]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(
                    applicationProcessId: replacementProcess.processIdentifier,
                    windowID: 42,
                    windowBounds: bounds,
                    windowMutationIdentity: AutomationTestFixtures.windowIdentity(
                        windowID: 42,
                        processIdentity: replacementProcess,
                        bounds: bounds))))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detection),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in replacementProcess.processStartIdentity })

        await #expect(throws: PeekabooError.self) {
            _ = try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: pinnedProcess.processIdentifier,
                expectedProcessIdentity: pinnedProcess)
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `Snapshot refinement reports incomplete immutable bounds before delivery`() async throws {
        let process = AutomationTestFixtures.processIdentity(
            processIdentifier: getpid(),
            processStartIdentity: 71)
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let identity = AutomationTestFixtures.windowIdentity(
            windowID: 42,
            processIdentity: process,
            bounds: nil)
        let detection = AutomationTestFixtures.detectionResult(
            snapshotID: "incomplete",
            elements: DetectedElements(buttons: [AutomationTestFixtures.detectedElement(
                id: "B1",
                type: .button,
                label: "Button")]),
            windowContext: WindowContext(
                applicationProcessId: process.processIdentifier,
                windowID: identity.windowID,
                windowBounds: bounds,
                windowMutationIdentity: identity))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detection),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            exactWindowIdentityValidator: { _, _ in
                Issue.record("Incomplete click receipt reached live window validation")
                return false
            },
            processStartIdentityProvider: { _ in process.processStartIdentity })

        let error = await #expect(throws: SnapshotTargetReceiptPreDispatchError.self) {
            _ = try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: detection.snapshotId,
                targetProcessIdentifier: process.processIdentifier,
                expectedProcessIdentity: process)
        }

        #expect(error?.receiptError == .incompleteExactWindow)
        #expect(error?.localizedDescription.contains("immutable captured bounds") == true)
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `Background coordinate click preserves exact target window`() async throws {
        let synthetic = ClickRecordingSyntheticInputDriver()
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 12345,
            ownerProcessStartIdentity: 1)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            exactWindowIdentityValidator: { _, _ in true })

        _ = try await service.click(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .single,
            snapshotId: nil,
            targetProcessIdentifier: 12345,
            targetWindowID: 42,
            expectedWindowIdentity: identity,
            expectedWindowBounds: bounds)

        #expect(synthetic.events == [
            .targetedClick(
                point: CGPoint(x: 10, y: 20),
                button: .left,
                count: 1,
                targetProcessIdentifier: 12345,
                targetWindowID: 42),
        ])
    }

    @Test
    @MainActor
    func `Exact click drift after dispatch is indeterminate`() async {
        let synthetic = ClickRecordingSyntheticInputDriver()
        let validations = ExactClickValidationSequence([true, false])
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 12345,
            ownerProcessStartIdentity: 1)
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            exactWindowIdentityValidator: { _, _ in validations.next() })

        do {
            _ = try await service.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: 12345,
                targetWindowID: 42,
                expectedWindowIdentity: identity,
                expectedWindowBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
            Issue.record("Expected indeterminate click completion")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.escalation == .observeBeforeRetry)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(synthetic.events.count == 1)
    }

    @Test
    @MainActor
    func `Exact click rejects mismatched process generation before delivery`() async {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: 72,
            capturedBounds: bounds)
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 71 })

        do {
            _ = try await service.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: getpid(),
                expectedProcessIdentity: ApplicationProcessIdentity(
                    processIdentifier: getpid(),
                    processStartIdentity: 71),
                targetWindowID: 42,
                expectedWindowIdentity: identity,
                expectedWindowBounds: bounds)
            Issue.record("Expected mismatched process-generation receipts to fail")
        } catch let PeekabooError.snapshotStale(reason) {
            #expect(reason.contains("different process generations"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `Exact click rejects mismatched window identifier before delivery`() async {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let identity = WindowMutationIdentity(
            windowID: 41,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: 71,
            capturedBounds: bounds)
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic)

        do {
            _ = try await service.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: getpid(),
                targetWindowID: 42,
                expectedWindowIdentity: identity,
                expectedWindowBounds: bounds)
            Issue.record("Expected the window identifier mismatch to fail")
        } catch let PeekabooError.snapshotStale(reason) {
            #expect(reason.contains("capture-time process-generation receipt"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `Exact click rejects mismatched captured bounds before delivery`() async {
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: 71,
            capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic)

        do {
            _ = try await service.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: getpid(),
                targetWindowID: 42,
                expectedWindowIdentity: identity,
                expectedWindowBounds: CGRect(x: 0, y: 0, width: 101, height: 100))
            Issue.record("Expected the captured bounds mismatch to fail")
        } catch let PeekabooError.snapshotStale(reason) {
            #expect(reason.contains("bounds do not match"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `Exact window identifier must fit CGWindowID`() async {
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic)

        await #expect(throws: PeekabooError.self) {
            try await service.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: getpid(),
                targetWindowID: Int(UInt32.max) + 1)
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `Snapshotless exact query is rejected before delivery`() async {
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic)

        await #expect(throws: PeekabooError.self) {
            try await service.click(
                target: .query("Save"),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: getpid(),
                targetWindowID: 42)
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `Missing targeted snapshot reports stale snapshot`() async {
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = UIAutomationService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            actionInputDriver: ActionInputDriver(),
            syntheticInputDriver: synthetic,
            automationElementResolver: AutomationElementResolver(),
            exactWindowIdentityValidator: { _, _ in true })

        do {
            _ = try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "expired-snapshot",
                expectedWindowIdentity: WindowMutationIdentity(
                    windowID: 42,
                    ownerProcessIdentifier: getpid(),
                    ownerProcessStartIdentity: 1),
                expectedWindowBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
            Issue.record("Expected stale snapshot error")
        } catch let PeekabooError.snapshotStale(reason) {
            #expect(reason.contains("no longer available"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `Application menu target cannot use a document window`() async {
        let pid = getpid()
        let menuItem = DetectedElement(
            id: "M1",
            type: .menuItem,
            label: "Save",
            bounds: CGRect(x: 10, y: 10, width: 40, height: 20),
            attributes: [
                "role": "AXMenuItem",
                DetectedElementRootPolicy.sourceAttribute: DetectedElementRootPolicy.applicationMenuBarSource,
            ])
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(menus: [menuItem]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(applicationProcessId: pid, windowID: 42)))
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic)

        await #expect(throws: PeekabooError.self) {
            try await service.click(
                target: .elementId("M1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: pid,
                targetWindowID: 42)
        }
        #expect(synthetic.events.isEmpty)
    }

    @Test
    @MainActor
    func `Window-owned context menu targets remain pinnable`() async throws {
        let pid = getpid()
        let tracker = ExactWindowTracker()
        try await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let targets = [
                DetectedElement(
                    id: "context-menu",
                    type: .menu,
                    label: "Context Menu",
                    bounds: CGRect(x: 10, y: 10, width: 40, height: 20),
                    attributes: ["role": "AXMenu"]),
                DetectedElement(
                    id: "context-menu-item",
                    type: .menuItem,
                    label: "Open",
                    bounds: CGRect(x: 20, y: 30, width: 60, height: 20),
                    attributes: ["role": "AXMenuItem"]),
            ]

            for target in targets {
                let detectionResult = ElementDetectionResult(
                    snapshotId: "snapshot",
                    screenshotPath: "/tmp/shot.png",
                    elements: DetectedElements(menus: [target]),
                    metadata: DetectionMetadata(
                        detectionTime: 0.01,
                        elementCount: 1,
                        method: "test",
                        windowContext: WindowContext(
                            applicationProcessId: pid,
                            windowID: 42,
                            windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                            windowMutationIdentity: WindowMutationIdentity(
                                windowID: 42,
                                ownerProcessIdentifier: pid,
                                ownerProcessStartIdentity: 1))))
                let synthetic = ClickRecordingSyntheticInputDriver()
                let service = ClickService(
                    snapshotManager: InMemorySnapshotManager(detectionResult: detectionResult),
                    inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                    syntheticInputDriver: synthetic,
                    exactWindowIdentityValidator: { _, _ in true })

                let result = try await service.click(
                    target: .elementId(target.id),
                    clickType: .single,
                    snapshotId: "snapshot",
                    targetProcessIdentifier: pid,
                    targetWindowID: 42,
                    expectedWindowIdentity: WindowMutationIdentity(
                        windowID: 42,
                        ownerProcessIdentifier: pid,
                        ownerProcessStartIdentity: 1),
                    expectedWindowBounds: CGRect(x: 0, y: 0, width: 100, height: 100))

                #expect(result.path == .synth)
                #expect(synthetic.events == [
                    .targetedClick(
                        point: CGPoint(x: target.bounds.midX, y: target.bounds.midY),
                        button: .left,
                        count: 1,
                        targetProcessIdentifier: pid,
                        targetWindowID: 42),
                ])
            }
        }
    }

    @Test
    func `Legacy disk-backed menu bar IDs retain application-root scope`() {
        let menuItem = DetectedElement(
            id: "menuitem_7",
            type: .other,
            label: "Save",
            bounds: .zero)

        #expect(DetectedElementRootPolicy.requiresApplicationRoot(menuItem))
    }
}

private final class ExactClickValidationSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]

    init(_ values: [Bool]) {
        self.values = values
    }

    func next() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.isEmpty ? false : self.values.removeFirst()
    }
}

private final class ExactWindowTracker: WindowTrackingProviding, @unchecked Sendable {
    @MainActor
    func windowBounds(for _: CGWindowID) -> CGRect? {
        CGRect(x: 0, y: 0, width: 100, height: 100)
    }
}
