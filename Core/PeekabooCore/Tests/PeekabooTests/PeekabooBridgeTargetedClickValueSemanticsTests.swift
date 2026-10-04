import Foundation
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

@Suite("Bridge targeted-click value semantics")
struct PeekabooBridgeTargetedClickValueSemanticsTests {
    @Test(arguments: [false, true], [1, 2, 3, 4])
    func `single-left native receipt requires an exact window and three routed units`(
        exactWindow: Bool,
        units: Int)
    {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 9001,
            ownerProcessStartIdentity: 7,
            capturedBounds: bounds)
        let request = PeekabooBridgeRequest.targetedClick(.init(
            target: .coordinates(CGPoint(x: 30, y: 40)),
            clickType: .single,
            snapshotId: SnapshotReferenceFixtures.first.rawValue,
            targetProcessIdentifier: identity.ownerProcessIdentifier,
            targetWindowID: exactWindow ? identity.windowID : nil,
            expectedWindowIdentity: exactWindow ? identity : nil,
            expectedWindowBounds: exactWindow ? bounds : nil,
            allowsAccessibilityValueDelivery: false))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .init(units))

        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            outcome,
            response: .ok,
            request: request) == (exactWindow && units == 3))
    }

    @Test(arguments: [false, true])
    func `only owner-typed unsupported click failures retain zero-dispatch evidence`(typed: Bool) {
        let request = PeekabooBridgeRequest.targetedClick(.init(
            target: .coordinates(CGPoint(x: 30, y: 40)),
            clickType: .single,
            snapshotId: SnapshotReferenceFixtures.first.rawValue,
            targetProcessIdentifier: 9001,
            targetWindowID: 42))
        let refusal = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .operationUnsupported,
            message: "The positional click route is unavailable before dispatch.")
        let envelope = typed
            ? PeekabooBridgeErrorEnvelope(code: .operationNotSupported, actionFailure: refusal)
            : PeekabooBridgeErrorEnvelope(code: .operationNotSupported, message: refusal.message)
        let failure = PeekabooBridgeOperationResultSemantics.canonicalFailure(
            envelope,
            request: request,
            stage: .executionMayHaveStarted)

        #expect(failure.actionOutcome?.outcome.state == (typed ? .refused : .indeterminate))
        let expectedDispatch: DesktopActionOutcome.DispatchState = typed ? .none : .mayHaveDispatched(unitCount: nil)
        #expect(failure.actionOutcome?.outcome.dispatchState == expectedDispatch)
        #expect(failure.actionOutcome?.outcome.retrySafety == (typed ? .safe : .unsafe))
    }

    @Test
    func `coordinate single click retains conditional unverified value delivery`() {
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 9001,
            ownerProcessStartIdentity: 7,
            capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)

        for policy: Bool? in [nil, true, false] {
            for kind in [ClickType.single, .right, .double, .middle, .triple, .longPress] {
                let request = PeekabooBridgeRequest.targetedClick(.init(
                    target: .coordinates(CGPoint(x: 30, y: 40)),
                    clickType: kind,
                    snapshotId: SnapshotReferenceFixtures.first.rawValue,
                    targetProcessIdentifier: identity.ownerProcessIdentifier,
                    targetWindowID: identity.windowID,
                    expectedWindowIdentity: identity,
                    expectedWindowBounds: identity.capturedBounds,
                    allowsAccessibilityValueDelivery: policy))
                #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                    outcome,
                    response: .ok,
                    request: request) == (kind == .single && policy != false))
            }
        }
    }

    @Test
    func `single targeted click accepts one verified background focus value write`() throws {
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 9001,
            ownerProcessStartIdentity: 7,
            capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let bounds = try #require(identity.capturedBounds)
        let focus = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            unitCount: .one)

        for request in [
            PeekabooBridgeRequest.targetedClick(.init(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue,
                targetProcessIdentifier: identity.ownerProcessIdentifier,
                expectedProcessIdentity: identity.processIdentity,
                allowsAccessibilityValueDelivery: true)),
            PeekabooBridgeRequest.targetedClick(.init(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue,
                targetProcessIdentifier: identity.ownerProcessIdentifier,
                targetWindowID: identity.windowID,
                expectedWindowIdentity: identity,
                expectedWindowBounds: bounds,
                allowsAccessibilityValueDelivery: true)),
            PeekabooBridgeRequest.targetedClick(.init(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue,
                targetProcessIdentifier: identity.ownerProcessIdentifier,
                expectedProcessIdentity: identity.processIdentity)),
            PeekabooBridgeRequest.targetedClick(.init(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue,
                targetProcessIdentifier: identity.ownerProcessIdentifier,
                targetWindowID: identity.windowID,
                expectedWindowIdentity: identity,
                expectedWindowBounds: bounds)),
        ] {
            #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                focus,
                response: .ok,
                request: request))
        }

        let optedOut = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("field"),
            clickType: .single,
            snapshotId: SnapshotReferenceFixtures.first.rawValue,
            targetProcessIdentifier: identity.ownerProcessIdentifier,
            expectedProcessIdentity: identity.processIdentity,
            allowsAccessibilityValueDelivery: false))
        #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            focus,
            response: .ok,
            request: optedOut))

        let exactOptedOut = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("field"),
            clickType: .single,
            snapshotId: SnapshotReferenceFixtures.first.rawValue,
            targetProcessIdentifier: identity.ownerProcessIdentifier,
            targetWindowID: identity.windowID,
            expectedWindowIdentity: identity,
            expectedWindowBounds: bounds,
            allowsAccessibilityValueDelivery: false))
        #expect(!PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            focus,
            response: .ok,
            request: exactOptedOut))
    }
}
