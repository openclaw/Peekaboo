import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct AutomationKitTestSupportTests {
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
    ScriptedUIAutomationActionOutcomeProviding
{
    let uiAutomationOutcomeScript: UIAutomationOutcomeScript
    private(set) var clickCount = 0

    init(outcomeScript: UIAutomationOutcomeScript) {
        self.uiAutomationOutcomeScript = outcomeScript
    }

    override func click(target _: ClickTarget, clickType _: ClickType, snapshotId _: String?) async throws {
        self.clickCount += 1
    }
}
