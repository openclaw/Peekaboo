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
    func `target projection preserves foreground process and exact window delivery`() throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001),
            windowID: 71,
            bounds: Self.windowBounds)

        #expect(try UIAutomationActionResultSemantics.targetIdentity(for: .foreground) == nil)
        #expect(try UIAutomationActionResultSemantics.actionTargetReceipt(for: .foreground) == nil)
        #expect(UIAutomationActionResultSemantics.keyboardDelivery(for: .foreground) == .init(
            mechanism: .globalEvents,
            mode: .foreground))

        let process = fixture.processTargetIdentity.target
        #expect(try UIAutomationActionResultSemantics.targetIdentity(for: process) == fixture.processTargetIdentity)
        #expect(try UIAutomationActionResultSemantics.actionTargetReceipt(for: process) == fixture.processTargetReceipt)
        #expect(UIAutomationActionResultSemantics.keyboardDelivery(for: process) == .init(
            mechanism: .processTargetedEvents,
            mode: .background))

        let window = fixture.windowTargetIdentity.target
        #expect(try UIAutomationActionResultSemantics.targetIdentity(for: window) == fixture.windowTargetIdentity)
        #expect(try UIAutomationActionResultSemantics.actionTargetReceipt(for: window) == fixture.windowTargetReceipt)
        #expect(UIAutomationActionResultSemantics.keyboardDelivery(for: window) == .init(
            mechanism: .windowTargetedEvents,
            mode: .background))
    }

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
    func `compatible target validation retains exact provider evidence`() throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001),
            windowID: 71,
            bounds: Self.windowBounds)
        let outcome = DesktopActionOutcome.confirmedChange(delivery: self.backgroundDelivery)

        let resolved = try UIAutomationActionResultSemantics.validateTarget(
            fixture.windowTargetIdentity,
            outcome: outcome,
            requirement: .compatible(fixture.processTargetIdentity),
            operation: "Fixture action")

        #expect(resolved == fixture.windowTargetIdentity)
        #expect(resolved?.actionTargetReceipt == fixture.windowTargetReceipt)
    }

    @Test
    func `compatible target contradiction remains unattributed`() throws {
        let expected = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001),
            windowID: 71,
            bounds: Self.windowBounds)
        let contradictory = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 43, processStartIdentity: 1002),
            windowID: 72,
            bounds: Self.windowBounds)

        do {
            _ = try UIAutomationActionResultSemantics.validateTarget(
                contradictory.windowTargetIdentity,
                outcome: .confirmedChange(delivery: self.backgroundDelivery),
                requirement: .compatible(expected.processTargetIdentity),
                operation: "Fixture action")
            Issue.record("Expected contradictory compatible targets to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.targetReceipt == nil)
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

    @Test
    func `outcome-only validation preserves failure context for consumers`() throws {
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 1001,
            windowID: 71)
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .windowTargetedEvents,
            mode: .background)

        do {
            _ = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
                nil,
                policy: .confirmedOrDispatched,
                operation: "Fixture action",
                targetReceipt: receipt,
                missingOutcomeRoute: .bridge,
                missingOutcomeDelivery: delivery,
                missingOutcomeUnitCount: .one)
            Issue.record("Expected missing outcome validation to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.delivery == delivery)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.message == "Fixture action returned without a canonical outcome.")
            #expect(failure.targetReceipt == receipt)
        }

        let refusal = DesktopActionOutcome.refused(
            route: .bridge,
            reason: .permissionDenied)
        do {
            _ = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
                refusal,
                policy: .confirmedOrDispatched,
                operation: "Fixture action",
                targetReceipt: receipt,
                rejectedOutcomeMessage: "Fixture action did not return a successful outcome.")
            Issue.record("Expected rejected outcome validation to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == refusal)
            #expect(failure.message == "Fixture action did not return a successful outcome.")
            #expect(failure.targetReceipt == receipt)
        }
    }
}
