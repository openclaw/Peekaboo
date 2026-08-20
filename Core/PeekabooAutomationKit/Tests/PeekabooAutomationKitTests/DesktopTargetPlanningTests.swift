import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct DesktopTargetPlanningTests {
    @Test
    func `process and exact-window evidence coalesce into the more specific stable target`() throws {
        let process = AutomationTestFixtures.processIdentity()
        let window = AutomationTestFixtures.windowIdentity(processIdentity: process)

        let resolved = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
            .init(processIdentifier: process.processIdentifier, processIdentity: process),
            .init(
                windowID: window.windowID,
                windowIdentity: window,
                windowBounds: window.capturedBounds),
        ])
        let identity = try #require(resolved)

        #expect(identity.processIdentity == process)
        #expect(identity.exactWindow?.identity.hasSameStableReceipt(as: window) == true)
    }

    @Test
    func `exact-window evidence requires immutable captured bounds`() {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let missingCapturedBounds = AutomationTestFixtures.windowIdentity(bounds: nil)

        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
                .init(
                    windowID: missingCapturedBounds.windowID,
                    windowIdentity: missingCapturedBounds,
                    windowBounds: bounds),
            ])
        }
    }

    @Test
    func `exact-window evidence requires external bounds to equal immutable captured bounds`() {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let window = AutomationTestFixtures.windowIdentity(bounds: bounds)

        #expect(throws: DesktopTargetIdentityError.contradictoryWindowBounds) {
            _ = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
                .init(
                    windowID: window.windowID,
                    windowIdentity: window,
                    windowBounds: bounds.offsetBy(dx: 1, dy: 0)),
            ])
        }
    }

    @Test(arguments: [0, -1, Int(UInt32.max) + 1])
    func `exact-window evidence rejects invalid window identifiers`(_ windowID: Int) {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let window = AutomationTestFixtures.windowIdentity(windowID: windowID, bounds: bounds)

        #expect(throws: DesktopTargetIdentityError.invalidWindowIdentifier) {
            _ = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
                .init(windowID: windowID, windowIdentity: window, windowBounds: bounds),
            ])
        }
    }

    @Test
    func `service-window adapter accepts only a complete valid exact-window receipt`() throws {
        let window = AutomationTestFixtures.window()

        let exactWindow = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.exactWindow(from: window)

        #expect(exactWindow.identity == window.mutationIdentity)
        #expect(exactWindow.bounds == window.bounds)
    }

    @Test
    func `stable window coalescing ignores minimized state`() throws {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let visible = AutomationTestFixtures.windowIdentity(bounds: bounds, isMinimized: false)
        let minimized = visible.withMinimizedState(true)

        let resolved = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
            .init(windowIdentity: visible, windowBounds: bounds),
            .init(windowIdentity: minimized, windowBounds: bounds),
        ])
        let identity = try #require(resolved)

        #expect(identity.exactWindow?.identity.hasSameStableReceipt(as: minimized) == true)
    }

    @Test
    func `coalescer refuses every stable identity contradiction`() {
        let process = AutomationTestFixtures.processIdentity()
        let otherGeneration = AutomationTestFixtures.processIdentity(processStartIdentity: 1002)
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let window = AutomationTestFixtures.windowIdentity(processIdentity: process, bounds: bounds)

        #expect(throws: DesktopTargetIdentityError.contradictoryProcessGeneration) {
            _ = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
                .init(processIdentity: process),
                .init(processIdentity: otherGeneration),
            ])
        }
        #expect(throws: DesktopTargetIdentityError.contradictoryWindowIdentifier) {
            _ = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
                .init(windowID: window.windowID, windowIdentity: window, windowBounds: bounds),
                .init(windowID: window.windowID + 1),
            ])
        }
        #expect(throws: DesktopTargetIdentityError.contradictoryWindowBounds) {
            _ = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
                .init(windowIdentity: window, windowBounds: bounds),
                .init(windowBounds: bounds.offsetBy(dx: 1, dy: 0)),
            ])
        }
    }

    @Test
    func `two supplied focused-element receipts must agree`() throws {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let window = AutomationTestFixtures.windowIdentity(bounds: bounds)
        let focused = AutomationTestFixtures.focusedElement()
        let changedFocus = AutomationTestFixtures.focusedElement(identifier: "other")

        let resolved = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
            .init(windowIdentity: window, windowBounds: bounds, focusedElement: focused),
            .init(windowIdentity: window, windowBounds: bounds, focusedElement: focused),
        ])
        let identity = try #require(resolved)
        #expect(identity.exactWindow?.focusedElement == focused)

        #expect(throws: DesktopTargetIdentityError.contradictoryFocusedElement) {
            _ = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
                .init(windowIdentity: window, windowBounds: bounds, focusedElement: focused),
                .init(windowIdentity: window, windowBounds: bounds, focusedElement: changedFocus),
            ])
        }
    }

    @Test
    func `missing generation and incomplete exact-window evidence remain distinct`() throws {
        #expect(throws: DesktopTargetIdentityError.missingProcessGeneration) {
            _ = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
                .init(processIdentifier: 101),
            ])
        }
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
                .init(
                    processIdentity: AutomationTestFixtures.processIdentity(),
                    windowID: 201),
            ])
        }
        #expect(try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([]) == nil)
    }

    @Test(arguments: [Int32.zero, -1])
    func `process fragments reject invalid identifiers before missing generation`(_ processIdentifier: Int32) {
        #expect(throws: DesktopTargetIdentityError.invalidProcessIdentifier) {
            _ = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
                .init(processIdentifier: processIdentifier),
            ])
        }
    }

    @Test
    func `zero process generation is rejected`() {
        #expect(throws: DesktopTargetIdentityError.missingProcessGeneration) {
            _ = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
                .init(processIdentity: .init(processIdentifier: 42, processStartIdentity: 0)),
            ])
        }
    }

    @Test
    func `empty exact window bounds are rejected`() {
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9,
            capturedBounds: .zero)
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
                .init(
                    processIdentity: identity.processIdentity,
                    windowID: identity.windowID,
                    windowIdentity: identity,
                    windowBounds: .zero),
            ])
        }
    }

    @Test
    func `malformed focused-element evidence is a typed target attribution error`() {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let window = AutomationTestFixtures.windowIdentity(bounds: bounds)
        let focused = AutomationTestFixtures.focusedElement(
            role: " ",
            frame: CGRect(x: 30, y: 40, width: 200, height: 30))

        #expect(throws: DesktopTargetIdentityError.invalidFocusedElement) {
            _ = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
                .init(windowIdentity: window, windowBounds: bounds, focusedElement: focused),
            ])
        }
    }

    @Test
    func `snapshot receipt preserves sticky invalidation instead of treating it as missing`() throws {
        let receipt = try SnapshotTargetReceipt(
            snapshotID: "snapshot-1",
            evidence: [.init(processIdentity: AutomationTestFixtures.processIdentity())],
            targetReceiptInvalidated: true)

        #expect(receipt.targetEvidence == .invalidated)
        #expect(throws: DesktopTargetIdentityError.invalidatedSnapshotReceipt) {
            _ = try receipt.requireIdentity()
        }
    }

    @Test
    func `coordinate authority requires snapshot window and source-bounds agreement`() throws {
        let snapshotID = "snapshot-1"
        let window = AutomationTestFixtures.window()
        let identity = try #require(window.mutationIdentity)
        let receipt = try SnapshotTargetReceipt(
            snapshotID: snapshotID,
            evidence: [.init(
                processIdentifier: identity.ownerProcessIdentifier,
                windowID: window.windowID,
                windowIdentity: identity,
                windowBounds: window.bounds)],
            coordinateContext: AutomationTestFixtures.captureCoordinateContext(
                snapshotID: snapshotID,
                window: window))

        let authority = try receipt.requireCoordinateAuthority()
        #expect(authority.snapshotID == snapshotID)
        #expect(authority.target.identity.hasSameStableReceipt(as: identity))
        #expect(authority.sourceBounds == window.bounds)

        let wrongReference = try SnapshotTargetReceipt(
            snapshotID: snapshotID,
            evidence: [.init(windowIdentity: identity, windowBounds: window.bounds)],
            coordinateContext: AutomationTestFixtures.captureCoordinateContext(
                snapshotID: "other-snapshot",
                window: window))
        #expect(throws: DesktopTargetIdentityError.coordinateReferenceMismatch) {
            _ = try wrongReference.requireCoordinateAuthority()
        }

        let wrongWindow = AutomationTestFixtures.window(windowID: window.windowID + 1)
        let wrongWindowContext = try SnapshotTargetReceipt(
            snapshotID: snapshotID,
            evidence: [.init(windowIdentity: identity, windowBounds: window.bounds)],
            coordinateContext: AutomationTestFixtures.captureCoordinateContext(
                snapshotID: snapshotID,
                window: wrongWindow))
        #expect(throws: DesktopTargetIdentityError.coordinateWindowMismatch) {
            _ = try wrongWindowContext.requireCoordinateAuthority()
        }
    }

    @Test
    func `ROI coordinate authority uses full source bounds rather than cropped logical bounds`() throws {
        let snapshotID = "snapshot-roi"
        let window = AutomationTestFixtures.window()
        let identity = try #require(window.mutationIdentity)
        let roi = CGRect(x: 110, y: 120, width: 200, height: 100)
        let viewport = CaptureViewport(
            sourceLogicalBounds: window.bounds,
            requestedWindowRelativeBounds: CGRect(x: 100, y: 100, width: 200, height: 100),
            deliveredWindowRelativeBounds: CGRect(x: 100, y: 100, width: 200, height: 100),
            logicalBounds: roi,
            sourceImageSize: window.bounds.size)
        let receipt = try SnapshotTargetReceipt(
            snapshotID: snapshotID,
            evidence: [.init(windowIdentity: identity, windowBounds: window.bounds)],
            coordinateContext: AutomationTestFixtures.captureCoordinateContext(
                snapshotID: snapshotID,
                window: window,
                deliveredImageSize: roi.size,
                viewport: viewport))

        #expect(try receipt.requireCoordinateAuthority().sourceBounds == window.bounds)
    }

    @MainActor
    @Test
    func `background keyboard planner preserves a snapshot-only exact target`() async throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            applicationName: "Editor",
            windowID: 42)
        let planner = self.backgroundKeyboardPlanner(
            application: fixture.application,
            windowInventory: .complete([]))

        let plan = try await planner.plan(
            selector: InteractionTargetSelector(),
            snapshotExactWindow: fixture.windowTargetIdentity.exactWindow)

        #expect(plan.target == fixture.windowTargetIdentity.target)
        #expect(plan.application.processIdentity == fixture.processIdentity)
        #expect(plan.window == nil)
    }

    @MainActor
    @Test
    func `background keyboard planner selects one exact window only from a complete catalog`() async throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            applicationName: "Editor",
            windowID: 42)
        let planner = self.backgroundKeyboardPlanner(
            application: fixture.application,
            windowInventory: .complete([fixture.window]))

        let plan = try await planner.plan(
            selector: InteractionTargetSelector(applicationIdentifier: "Editor"))

        #expect(plan.target == fixture.windowTargetIdentity.target)
        #expect(plan.window == nil)
    }

    @MainActor
    @Test
    func `background keyboard planner refuses one implicit match from a partial catalog`() async throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            applicationName: "Editor",
            windowID: 42)
        let planner = self.backgroundKeyboardPlanner(
            application: fixture.application,
            windowInventory: .partial([fixture.window], warnings: ["AX enumeration timed out"]))

        await #expect(throws: DesktopTargetPlanningError.incompleteWindowInventory(
            selector: "the application's eligible keyboard windows",
            warnings: ["AX enumeration timed out"]))
        {
            _ = try await planner.plan(
                selector: InteractionTargetSelector(applicationIdentifier: "Editor"))
        }
    }

    @MainActor
    private func backgroundKeyboardPlanner(
        application: ServiceApplicationInfo,
        windowInventory: DesktopTargetPlanning.Inventory<ServiceWindowInfo>)
        -> DesktopTargetPlanning.BackgroundKeyboardTargetPlanner
    {
        let applicationPlanner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .complete([application]) },
            exactIdentifierProvider: { _ in application })
        let windowProvider: DesktopTargetPlanning.WindowMutationPlanner.WindowInventoryProvider = { _ in
            windowInventory
        }
        return DesktopTargetPlanning.BackgroundKeyboardTargetPlanner(
            applicationPlanner: applicationPlanner,
            windowPlanner: DesktopTargetPlanning.WindowMutationPlanner(
                applicationPlanner: applicationPlanner,
                windowInventoryProvider: windowProvider),
            windowInventoryProvider: windowProvider)
    }
}
