import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct CommandActionSequenceAccumulatorTests {
    @Test
    func `leaf refusal preserves prior focus dispatch and exact target`() throws {
        let target = try Self.target(pid: 41, generation: 7, windowID: 101)
        let sequence = CommandActionSequenceAccumulator()
        try sequence.record(UIAutomationActionResult(
            payload: (),
            outcome: .confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground)
            ),
            targetIdentity: target
        ))

        let refusal = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "The leaf target disappeared."
        )
        let preserved = try #require(sequence.preservingFailure(
            refusal,
            fallbackRoute: .bridge,
            message: "The action failed after focus.",
            hint: "Observe before retrying."
        ) as? DesktopActionFailure)

        #expect(preserved.outcome.state == .indeterminate)
        #expect(preserved.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        #expect(preserved.outcome.retrySafety == .unsafe)
        #expect(preserved.outcome.escalation == .observeBeforeRetry)
        #expect(preserved.targetReceipt?.processIdentifier == 41)
        #expect(preserved.targetReceipt?.processStartIdentity == 7)
        #expect(preserved.targetReceipt?.windowID == 101)
    }

    @Test
    func `generic leaf error after focus becomes retry unsafe and target bound`() throws {
        let target = try Self.target(pid: 46, generation: 12, windowID: 106)
        let sequence = CommandActionSequenceAccumulator()
        try sequence.record(UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one
            ),
            targetIdentity: target
        ))

        let preserved = try #require(sequence.preservingFailure(
            FixtureLeafError(),
            fallbackRoute: .bridge,
            message: "The leaf failed after focus.",
            hint: "Observe before retrying."
        ) as? DesktopActionFailure)

        #expect(preserved.outcome.state == .indeterminate)
        #expect(preserved.outcome.retrySafety == .unsafe)
        #expect(preserved.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        #expect(preserved.targetReceipt?.windowID == 106)
    }

    @Test
    func `cancellation after dispatch delegates retry and target semantics`() throws {
        let target = try Self.target(pid: 48, generation: 14, windowID: 108)
        let sequence = CommandActionSequenceAccumulator()
        try sequence.record(UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one
            ),
            targetIdentity: target
        ))

        let preserved = try #require(sequence.preservingFailure(
            CancellationError(),
            fallbackRoute: .bridge,
            message: "The action was cancelled after dispatch.",
            hint: "Observe before retrying."
        ) as? DesktopActionFailure)

        #expect(preserved.outcome.state == .indeterminate)
        #expect(preserved.outcome.retrySafety == .unsafe)
        #expect(preserved.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        #expect(preserved.targetReceipt == target.actionTargetReceipt)
    }

    @Test
    func `successful focus and leaf coalesce target and dispatch units`() throws {
        let target = try Self.target(pid: 42, generation: 8, windowID: 102)
        let processTarget = try DesktopTargetIdentity(processIdentity: target.processIdentity)
        let sequence = CommandActionSequenceAccumulator()
        try sequence.record(UIAutomationActionResult(
            payload: (),
            outcome: .confirmedChange(
                route: .local,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground)
            ),
            targetIdentity: target
        ))
        try sequence.record(UIAutomationActionResult(
            payload: "done",
            outcome: .confirmedChange(
                route: .local,
                delivery: .init(mechanism: .accessibilityValue, mode: .foreground)
            ),
            targetIdentity: processTarget
        ))

        let result = sequence.result(payload: "done")
        var canonical = UIAutomationActionResultSequenceAccumulator(
            targetProjectionPolicy: .coalescedIdentity
        )
        canonical.record(
            .reportedOutcome(
                .confirmedChange(
                    route: .local,
                    delivery: .init(mechanism: .accessibilityAction, mode: .foreground)
                ),
                defaultDispatchedUnitCount: .one
            ),
            targetIdentity: target,
            attribution: .sequenceTarget
        )
        canonical.record(
            .reportedOutcome(
                .confirmedChange(
                    route: .local,
                    delivery: .init(mechanism: .accessibilityValue, mode: .foreground)
                ),
                defaultDispatchedUnitCount: .one
            ),
            targetIdentity: processTarget,
            attribution: .sequenceTarget
        )
        let canonicalResult = try canonical.result(
            payload: "done",
            operation: "Canonical command sequence",
            requiresOutcome: true,
            requiresCompatibleTarget: true
        )
        #expect(result.payload == "done")
        #expect(result.outcome == .confirmedChange(
            route: .local,
            delivery: .init(mechanism: .composite, mode: .foreground),
            unitCount: DesktopActionOutcome.DispatchUnitCount(2)
        ))
        #expect(result.targetIdentity == target)
        #expect(result.outcome == canonicalResult.outcome)
        #expect(result.targetIdentity == canonicalResult.targetIdentity)
    }

    @Test
    func `receiptless successful focus remains a dispatched setup step`() throws {
        let target = try Self.target(pid: 45, generation: 11, windowID: 105)
        let sequence = CommandActionSequenceAccumulator()
        try sequence.record(
            UIAutomationActionResult(payload: (), outcome: nil, targetIdentity: target),
            operation: "Legacy focus",
            receiptlessStep: .dispatched(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                unitCount: .one
            )
        )
        try sequence.record(UIAutomationActionResult(
            payload: (),
            outcome: .confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityValue, mode: .foreground)
            ),
            targetIdentity: DesktopTargetIdentity(processIdentity: target.processIdentity)
        ))

        let result = sequence.result(payload: ())
        #expect(result.outcome == .dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2)
        ))
        #expect(result.targetIdentity == target)
    }

    @Test
    func `exact leaf without target evidence drops setup target projection`() throws {
        let target = try Self.target(pid: 47, generation: 13, windowID: 107)
        let sequence = CommandActionSequenceAccumulator()
        try sequence.record(UIAutomationActionResult(
            payload: (),
            outcome: .confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground)
            ),
            targetIdentity: target
        ))
        try sequence.recordExactTargetLeaf(
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one
            ),
            targetIdentity: nil,
            operation: "Exact leaf"
        )

        let result = sequence.result(payload: ())
        #expect(result.outcome == .dispatchedUnverified(
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2)
        ))
        #expect(result.targetIdentity == nil)
    }

    @Test
    func `focus refusal stops the sequence before any dispatch is recorded`() throws {
        let sequence = CommandActionSequenceAccumulator()
        let refusal = DesktopActionOutcome.refused(route: .bridge, reason: .targetUnavailable)

        #expect(throws: DesktopActionFailure.self) {
            try sequence.record(
                UIAutomationActionResult(payload: (), outcome: refusal),
                operation: "Setup focus"
            )
        }
        #expect(sequence.mutationDisposition == .none)
        #expect(sequence.resolution.outcome == nil)
    }

    @Test
    func `contradictory completed targets fail closed without projecting either target`() throws {
        let focusTarget = try Self.target(pid: 43, generation: 9, windowID: 103)
        let leafTarget = try Self.target(pid: 44, generation: 10, windowID: 104)
        let sequence = CommandActionSequenceAccumulator()
        try sequence.record(UIAutomationActionResult(
            payload: (),
            outcome: .confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground)
            ),
            targetIdentity: focusTarget
        ))

        let contradiction: any Error
        do {
            try sequence.record(UIAutomationActionResult(
                payload: (),
                outcome: .confirmedChange(
                    delivery: .init(mechanism: .accessibilityValue, mode: .foreground)
                ),
                targetIdentity: leafTarget
            ))
            Issue.record("Expected contradictory targets to be rejected")
            return
        } catch {
            contradiction = error
        }
        #expect(contradiction as? DesktopTargetIdentityError == .contradictoryProcessIdentifier)

        let preserved = try #require(sequence.preservingFailure(
            contradiction,
            fallbackRoute: .local,
            message: "The action returned contradictory target receipts.",
            hint: "Observe before retrying."
        ) as? DesktopActionFailure)
        #expect(preserved.outcome.state == .indeterminate)
        #expect(preserved.outcome.dispatchState == .mayHaveDispatched(
            unitCount: DesktopActionOutcome.DispatchUnitCount(2)
        ))
        #expect(preserved.targetReceipt == nil)
    }

    private static func target(
        pid: Int32,
        generation: UInt64,
        windowID: Int
    ) throws -> DesktopTargetIdentity {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let identity = WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: pid,
            ownerProcessStartIdentity: generation,
            capturedBounds: bounds
        )
        return try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds
        ))
    }

    private struct FixtureLeafError: LocalizedError {
        var errorDescription: String? {
            "The fixture leaf failed."
        }
    }
}
