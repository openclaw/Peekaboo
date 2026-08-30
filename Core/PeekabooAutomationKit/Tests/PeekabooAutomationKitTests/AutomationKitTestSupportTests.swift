import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct AutomationKitTestSupportTests {
    @Test
    func `linked snapshot target keeps automation and detection sources coherent`() throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            snapshotID: "snapshot-linked",
            processIdentity: AutomationTestFixtures.processIdentity(
                processIdentifier: 42,
                processStartIdentity: 1001),
            windowID: 71)

        #expect(fixture.automationSnapshot.applicationProcessId == 42)
        #expect(fixture.automationSnapshot.windowMutationIdentity == fixture.desktopTarget.windowIdentity)
        #expect(fixture.automationSnapshot.windowBounds == fixture.desktopTarget.window.bounds)
        #expect(fixture.automationSnapshot.captureCoordinateContext == fixture.coordinateContext)
        #expect(fixture.detectionResult.snapshotId == fixture.snapshotID)
        let detectionContext = try #require(fixture.detectionResult.metadata.windowContext)
        #expect(
            DesktopTargetEvidenceAdapter.evidence(context: detectionContext) ==
                DesktopTargetEvidenceAdapter.evidence(context: fixture.desktopTarget.windowContext))
        #expect(fixture.detectionResult.metadata.captureCoordinateContext == fixture.coordinateContext)

        let authority = try fixture.receiptPlan.receipt.requireCoordinateAuthority()
        #expect(authority.target.identity == fixture.desktopTarget.windowIdentity)
    }

    @Test
    func `linked desktop target keeps every receipt on one process generation`() {
        let process = AutomationTestFixtures.processIdentity(
            processIdentifier: 42,
            processStartIdentity: 1001)
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: process,
            bundleIdentifier: "com.example.Linked",
            applicationName: "Linked App",
            windowID: 71,
            windowTitle: "Linked Window",
            bounds: bounds)

        #expect(fixture.application.processIdentity == process)
        #expect(fixture.application.windowCount == 1)
        #expect(fixture.application.windowIDs == [71])
        #expect(fixture.window.mutationIdentity == fixture.windowIdentity)
        #expect(fixture.windowIdentity.processIdentity == process)
        #expect(fixture.processTargetIdentity.processIdentity == process)
        #expect(fixture.windowTargetIdentity.exactWindow?.identity == fixture.windowIdentity)
        #expect(fixture.processTargetReceipt == DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 1001))
        #expect(fixture.windowTargetReceipt == DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 1001,
            windowID: 71))
        #expect(fixture.windowContext.windowMutationIdentity == fixture.windowIdentity)
        #expect(fixture.windowContext.windowBounds == bounds)
    }

    @Test
    func `window copy overrides coherent identity fields and preserves unrelated metadata`() {
        let originalBounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let originalIdentity = AutomationTestFixtures.windowIdentity(
            windowID: 71,
            processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001),
            bounds: originalBounds)
        let evidence = WindowMutationPostconditionEvidence(
            isMaximized: true,
            verifiedVisibleWorkArea: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let original = ServiceWindowInfo(
            windowID: 71,
            title: "Original",
            bounds: originalBounds,
            isMainWindow: true,
            isKeyWindow: true,
            isFrontmost: false,
            subrole: "AXStandardWindow",
            windowLevel: 3,
            alpha: 0.75,
            index: 4,
            spaceID: 5,
            spaceName: "Work",
            screenIndex: 1,
            screenName: "Studio Display",
            sharingState: .readWrite,
            isExcludedFromWindowsMenu: true,
            mutationIdentity: originalIdentity,
            mutationPostconditionEvidence: evidence)

        let renamed = AutomationTestFixtures.window(copying: original, title: "Renamed")
        #expect(renamed.mutationIdentity == originalIdentity)
        #expect(renamed.mutationPostconditionEvidence == evidence)

        let replacementProcess = AutomationTestFixtures.processIdentity(
            processIdentifier: 43,
            processStartIdentity: 1002)
        let movedBounds = originalBounds.offsetBy(dx: 10, dy: 20)
        let moved = AutomationTestFixtures.window(
            copying: original,
            bounds: movedBounds,
            processIdentity: replacementProcess,
            isMinimized: true,
            isOffScreen: true,
            isOnScreen: false)

        #expect(moved.bounds == movedBounds)
        #expect(moved.isMinimized)
        #expect(moved.isOffScreen)
        #expect(!moved.isOnScreen)
        #expect(moved.mutationIdentity == AutomationTestFixtures.windowIdentity(
            windowID: 71,
            processIdentity: replacementProcess,
            bounds: movedBounds,
            isMinimized: true))
        #expect(moved.subrole == original.subrole)
        #expect(moved.windowLevel == original.windowLevel)
        #expect(moved.alpha == original.alpha)
        #expect(moved.index == original.index)
        #expect(moved.spaceID == original.spaceID)
        #expect(moved.spaceName == original.spaceName)
        #expect(moved.screenIndex == original.screenIndex)
        #expect(moved.screenName == original.screenName)
        #expect(moved.sharingState == original.sharingState)
        #expect(moved.isExcludedFromWindowsMenu == original.isExcludedFromWindowsMenu)
        #expect(moved.mutationPostconditionEvidence == nil)
    }

    @Test
    func `script sequences outcomes and failures without sharing instance state`() async throws {
        let first = Self.outcome(evidence: .deliveryAccepted)
        let second = Self.outcome(evidence: .operationStillRunning)
        let script = UIAutomationOutcomeScript(responses: [
            .click: [.outcome(first), .outcome(second), .failure(OutcomeScriptTestError.expected)],
        ])
        let service = PlainScriptedAutomationService(outcomeScript: script)
        let independent = UIAutomationOutcomeScript()

        let firstResult = try await service.clickWithOutcome(
            target: .coordinates(.zero),
            clickType: .single,
            snapshotId: nil)
        let secondResult = try await service.clickWithOutcome(
            target: .coordinates(.zero),
            clickType: .single,
            snapshotId: nil)
        await #expect(throws: OutcomeScriptTestError.self) {
            try await service.clickWithOutcome(
                target: .coordinates(.zero),
                clickType: .single,
                snapshotId: nil)
        }

        #expect(firstResult.outcome == first)
        #expect(secondResult.outcome == second)
        #expect(service.clickCount == 2)
        #expect(script.callCount(for: .click) == 3)
        #expect(script.remainingResponseCount(for: .click) == 0)
        #expect(independent.totalCallCount == 0)
    }

    @Test
    func `exact window capability refusal never falls back or consumes an outcome`() async throws {
        let script = UIAutomationOutcomeScript(defaultResponse: .outcome(Self.outcome(evidence: .deliveryAccepted)))
        let service = PlainScriptedAutomationService(outcomeScript: script)
        let process = AutomationTestFixtures.processIdentity()
        let windowIdentity = AutomationTestFixtures.windowIdentity(processIdentity: process)
        let windowBounds = try #require(windowIdentity.capturedBounds)
        let focusedElement = FocusedElementIdentity(
            processIdentifier: process.processIdentifier,
            windowID: windowIdentity.windowID,
            role: "AXTextField",
            frame: windowBounds)
        let exactTarget = ExactWindowKeyboardTarget(
            windowIdentity: windowIdentity,
            windowBounds: windowBounds,
            focusedElement: focusedElement)

        await #expect(throws: PeekabooError.self) {
            try await service.clickWithOutcome(
                target: .coordinates(.zero),
                clickType: .single,
                snapshotId: nil,
                expectedWindowIdentity: windowIdentity,
                expectedWindowBounds: windowBounds)
        }
        await #expect(throws: PeekabooError.self) {
            try await service.hotkeyWithOutcome(
                keys: "cmd,k",
                holdDuration: 0,
                target: exactTarget)
        }

        #expect(service.clickCount == 0)
        #expect(script.totalCallCount == 0)
    }

    @Test
    func `exact click policy capability refusal precedes bounds validation and outcome consumption`() async throws {
        let script = UIAutomationOutcomeScript(defaultResponse: .outcome(Self.outcome(evidence: .deliveryAccepted)))
        let service = PlainScriptedAutomationService(outcomeScript: script)
        let provider: any UIAutomationActionOutcomeProviding = service
        let evidence = ExactWindowClickEvidence(
            identity: AutomationTestFixtures.windowIdentity(),
            bounds: .zero)

        for policy in [false, true] {
            do {
                _ = try await provider.clickWithOutcome(
                    target: .elementId("field"),
                    clickType: .single,
                    snapshotId: nil,
                    windowEvidence: evidence,
                    allowsAccessibilityValueDelivery: policy)
                Issue.record("Expected exact-window capability refusal before invalid-bounds validation")
            } catch let PeekabooError.serviceUnavailable(message) {
                #expect(message == "This automation test double does not support exact-window clicks")
            }
            #expect(service.clickCount == 0)
            #expect(script.totalCallCount == 0)
        }
    }

    @Test
    func `legacy targeted click permits value delivery but refuses explicit opt out`() async throws {
        let script = UIAutomationOutcomeScript(defaultResponse: .outcome(Self.outcome(evidence: .deliveryAccepted)))
        let service = PlainScriptedAutomationService(outcomeScript: script)
        let identity = AutomationTestFixtures.processIdentity()

        await #expect(throws: PeekabooError.self) {
            try await service.clickWithOutcome(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: nil,
                expectedProcessIdentity: identity,
                allowsAccessibilityValueDelivery: false)
        }
        #expect(service.clickCount == 0)
        #expect(script.totalCallCount == 0)

        _ = try await service.clickWithOutcome(
            target: .elementId("field"),
            clickType: .single,
            snapshotId: nil,
            expectedProcessIdentity: identity,
            allowsAccessibilityValueDelivery: true)
        #expect(service.clickCount == 1)
        #expect(script.callCount(for: .click) == 1)
    }

    @Test
    func `script default outcome is mutable and instance owned`() async throws {
        let script = UIAutomationOutcomeScript()
        let service = PlainScriptedAutomationService(outcomeScript: script)
        let expected = Self.outcome(evidence: .deliveryAccepted)

        script.setDefaultOutcome(expected)
        let result = try await service.clickWithOutcome(
            target: .coordinates(.zero),
            clickType: .single,
            snapshotId: nil)

        #expect(result.outcome == expected)
        #expect(script.callCount(for: .click) == 1)
    }

    private static func outcome(
        evidence: DesktopActionOutcome.DispatchedUnverifiedEvidence) -> DesktopActionOutcome
    {
        .dispatchedUnverified(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            evidence: evidence)
    }
}

private enum OutcomeScriptTestError: Error {
    case expected
}

@MainActor
private final class PlainScriptedAutomationService:
    UnusedUIAutomationService,
    ScriptedUIAutomationActionOutcomeProviding,
    TargetedClickServiceProtocol
{
    let uiAutomationOutcomeScript: UIAutomationOutcomeScript
    let supportsProcessGenerationPinnedClicks = true
    private(set) var clickCount = 0

    init(outcomeScript: UIAutomationOutcomeScript) {
        self.uiAutomationOutcomeScript = outcomeScript
    }

    override func click(target _: ClickTarget, clickType _: ClickType, snapshotId _: String?) async throws {
        self.clickCount += 1
    }

    func click(
        target _: ClickTarget,
        clickType _: ClickType,
        snapshotId _: String?,
        targetProcessIdentifier _: pid_t) async throws
    {
        self.clickCount += 1
    }

    func click(
        target _: ClickTarget,
        clickType _: ClickType,
        snapshotId _: String?,
        expectedProcessIdentity _: ApplicationProcessIdentity) async throws
    {
        self.clickCount += 1
    }
}
