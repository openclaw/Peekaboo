import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct UIAutomationActionResultSemanticsTests {
    private static let windowBounds = CGRect(x: 10, y: 20, width: 300, height: 200)

    private let backgroundDelivery = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .background)

    @Test
    func `receipt projection preserves process and exact window generations`() {
        let process = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 1001)
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: process,
            windowID: 71,
            bounds: Self.windowBounds)
        let processTarget = fixture.processTargetIdentity
        #expect(processTarget.actionTargetReceipt == DesktopActionTargetReceipt(
            processIdentifier: process.processIdentifier,
            processStartIdentity: process.processStartIdentity))

        let window = fixture.windowTargetIdentity
        #expect(window.actionTargetReceipt == DesktopActionTargetReceipt(
            processIdentifier: process.processIdentifier,
            processStartIdentity: process.processStartIdentity,
            windowID: 71))
    }

    @Test
    func `shared validator accepts configured success and target policy`() throws {
        let target = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001))
            .processTargetIdentity
        let result = UIAutomationActionResult(
            payload: (),
            outcome: DesktopActionOutcome.dispatchedUnverified(
                delivery: self.backgroundDelivery,
                evidence: .deliveryAccepted,
                unitCount: .one),
            targetIdentity: target)

        let outcome = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
            result,
            policy: .confirmedOrDispatched(requiring: .background),
            targetRequirement: .required,
            operation: "Fixture action")
        #expect(outcome == result.outcome)
        #expect(result.actionTargetReceipt == target.actionTargetReceipt)
    }

    @Test
    func `shared validator rejects delivery drift and attributes the target`() throws {
        let target = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001))
            .processTargetIdentity
        let result = UIAutomationActionResult(
            payload: (),
            outcome: DesktopActionOutcome.confirmedChange(delivery: .init(
                mechanism: .globalEvents,
                mode: .foreground)),
            targetIdentity: target)

        do {
            _ = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
                result,
                policy: .confirmedOrDispatched(requiring: .background),
                targetRequirement: .required,
                operation: "Fixture action")
            Issue.record("Expected delivery drift to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == result.outcome?.delivery)
            #expect(failure.targetReceipt == target.actionTargetReceipt)
        }
    }

    @Test
    func `shared validator rejects missing or contradictory targets after dispatch`() throws {
        let process = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 1001)
        let expected = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: process,
            windowID: 71,
            bounds: Self.windowBounds).windowTargetIdentity
        let other = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: process,
            windowID: 72,
            bounds: Self.windowBounds).windowTargetIdentity
        let outcome = DesktopActionOutcome.confirmedChange(delivery: self.backgroundDelivery)

        for actual in [DesktopTargetIdentity?.none, other] {
            let result = UIAutomationActionResult(payload: (), outcome: outcome, targetIdentity: actual)
            do {
                _ = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
                    result,
                    policy: .confirmed,
                    targetRequirement: .exact(expected),
                    operation: "Fixture action")
                Issue.record("Expected exact target validation to fail")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .indeterminate)
                #expect(failure.targetReceipt == expected.actionTargetReceipt)
            }
        }
    }

    @Test
    func `pre-dispatch refusal does not invent a missing target`() throws {
        let result = UIAutomationActionResult<Void>(
            payload: (),
            outcome: .refused(reason: .targetUnavailable),
            targetIdentity: nil)

        do {
            _ = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
                result,
                policy: .confirmedOrDispatched,
                targetRequirement: .required,
                operation: "Fixture action")
            Issue.record("Expected refusal to remain a failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == result.outcome)
            #expect(failure.targetReceipt == nil)
        }
    }
}
