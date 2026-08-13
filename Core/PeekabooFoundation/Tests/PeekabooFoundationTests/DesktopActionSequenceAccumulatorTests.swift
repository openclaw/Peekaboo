import Foundation
import PeekabooFoundation
import Testing

struct DesktopActionSequenceAccumulatorTests {
    private let localBackground = DesktopActionOutcome.Delivery(
        mechanism: .processTargetedEvents,
        mode: .background)
    private let localForeground = DesktopActionOutcome.Delivery(
        mechanism: .globalEvents,
        mode: .foreground)

    @Test
    func `mutation disposition preserves none definite and possible dispatch`() throws {
        let two = try self.units(2)
        let three = try self.units(3)

        #expect(DesktopActionMutationDisposition(dispatchState: .none) == .none)
        #expect(
            DesktopActionMutationDisposition(dispatchState: .dispatched(unitCount: two)) ==
                .definite(unitCount: two))
        #expect(
            DesktopActionMutationDisposition(dispatchState: .mayHaveDispatched(unitCount: three)) ==
                .possible(unitCount: three))

        #expect(!DesktopActionMutationDisposition.none.mutationDispatched)
        #expect(DesktopActionMutationDisposition.possible(unitCount: nil).mutationDispatched)
    }

    @Test
    func `homogeneous confirmed sequence composes exact units`() throws {
        var sequence = DesktopActionSequenceAccumulator()
        try sequence.record(.outcome(.confirmedChange(
            delivery: self.localBackground,
            unitCount: self.units(2))))
        sequence.record(.outcome(.confirmedNoChange()))
        try sequence.record(.outcome(.confirmedChange(
            delivery: self.localBackground,
            unitCount: self.units(3))))

        let resolution = sequence.successResolution()
        #expect(try resolution.outcome == .confirmedChange(
            delivery: self.localBackground,
            unitCount: self.units(5)))
        #expect(try resolution.mutationDisposition == .definite(unitCount: self.units(5)))
        #expect(!resolution.retrySafe)
        #expect(!resolution.requiresFreshObservation)
    }

    @Test
    func `single reported leaf preserves its exact canonical receipt`() {
        let leaf = DesktopActionOutcome.confirmedChange(delivery: self.localForeground)
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.reportedOutcome(leaf, defaultDispatchedUnitCount: .one))

        #expect(sequence.mutationDisposition == .definite(unitCount: .one))
        #expect(sequence.successResolution().outcome == leaf)
    }

    @Test
    func `all no-dispatch phases preserve confirmed no-change only with one route`() {
        var homogeneous = DesktopActionSequenceAccumulator()
        homogeneous.record(.outcome(.confirmedNoChange(route: .bridge)))
        homogeneous.record(.outcome(.confirmedNoChange(route: .bridge)))
        #expect(homogeneous.successResolution().outcome == .confirmedNoChange(route: .bridge))

        var mixed = homogeneous
        mixed.record(.outcome(.confirmedNoChange(route: .local)))
        let mixedResolution = mixed.successResolution()
        #expect(mixedResolution.outcome == nil)
        #expect(mixedResolution.mutationDisposition == .none)
        #expect(mixedResolution.retrySafe)
        #expect(!mixedResolution.requiresFreshObservation)
    }

    @Test
    func `receiptless definite and possible phases never fabricate delivery`() throws {
        var known = DesktopActionSequenceAccumulator()
        try known.record(.dispatched(
            route: .local,
            delivery: self.localForeground,
            unitCount: self.units(1)))
        let knownResolution = known.successResolution()
        #expect(try knownResolution.outcome == .dispatchedUnverified(
            delivery: self.localForeground,
            evidence: .deliveryAccepted,
            unitCount: self.units(1)))
        #expect(knownResolution.requiresFreshObservation)
        #expect(!knownResolution.retrySafe)

        var unknown = DesktopActionSequenceAccumulator()
        try unknown.record(.mayHaveDispatched(route: nil, delivery: nil, unitCount: self.units(1)))
        let unknownResolution = unknown.successResolution()
        #expect(unknownResolution.outcome == nil)
        #expect(try unknownResolution.mutationDisposition == .possible(unitCount: self.units(1)))
        #expect(unknownResolution.requiresFreshObservation)
        #expect(!unknownResolution.retrySafe)
    }

    @Test
    func `unknown unit count stays unknown across otherwise exact phases`() throws {
        var sequence = DesktopActionSequenceAccumulator()
        try sequence.record(.dispatched(route: .local, delivery: self.localBackground, unitCount: self.units(2)))
        sequence.record(.dispatched(route: .local, delivery: self.localBackground, unitCount: nil))

        #expect(sequence.mutationDisposition == .definite(unitCount: nil))
        #expect(sequence.successResolution().outcome == .dispatchedUnverified(
            delivery: self.localBackground,
            evidence: .deliveryAccepted,
            unitCount: nil))
    }

    @Test
    func `mixed route or delivery keeps disposition but suppresses a false aggregate`() throws {
        var mixedRoute = DesktopActionSequenceAccumulator()
        try mixedRoute.record(.outcome(.confirmedChange(
            route: .local,
            delivery: self.localBackground,
            unitCount: self.units(1))))
        try mixedRoute.record(.outcome(.confirmedChange(
            route: .bridge,
            delivery: self.localBackground,
            unitCount: self.units(1))))
        #expect(mixedRoute.successResolution().outcome == nil)
        #expect(try mixedRoute.mutationDisposition == .definite(unitCount: self.units(2)))

        var mixedDelivery = DesktopActionSequenceAccumulator()
        mixedDelivery.record(.outcome(.confirmedChange(delivery: self.localBackground)))
        mixedDelivery.record(.outcome(.confirmedChange(delivery: self.localForeground)))
        #expect(mixedDelivery.successResolution().outcome == nil)
        #expect(mixedDelivery.successResolution().requiresFreshObservation)
    }

    @Test
    func `leaf refusal is preserved only while the whole composite has no dispatch`() throws {
        let refusal = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Target drifted",
            causeDescription: "The pinned window generation changed")

        var noDispatch = DesktopActionSequenceAccumulator()
        noDispatch.record(.outcome(.confirmedNoChange(route: .bridge)))
        #expect(noDispatch.failure(combining: refusal, message: "Composite failed") == refusal)

        var dispatched = noDispatch
        try dispatched.record(.dispatched(
            route: .local,
            delivery: self.localForeground,
            unitCount: self.units(1)))
        let composed = dispatched.failure(
            combining: refusal,
            message: "Composite failed",
            hint: "Observe before retrying")
        #expect(composed.outcome.state == .indeterminate)
        #expect(try composed.outcome.dispatchState == .mayHaveDispatched(unitCount: self.units(1)))
        #expect(composed.outcome.retrySafety == .unsafe)
        #expect(composed.outcome.projection.requiresFreshObservation)
        #expect(composed.causeDescription == "The pinned window generation changed")
    }

    @Test
    func `foreground setup cannot be erased by a no-dispatch leaf`() throws {
        var sequence = DesktopActionSequenceAccumulator()
        try sequence.record(.mayHaveDispatched(route: nil, delivery: nil, unitCount: self.units(1)))
        let refusal = DesktopActionFailure.preDispatchRefusal(
            reason: .runtimeIncompatible,
            message: "Leaf refused")

        let composed = sequence.failure(
            combining: refusal,
            message: "Typing failed after setup focus",
            hint: "Observe before retrying")
        #expect(composed.outcome.state == .indeterminate)
        #expect(try composed.outcome.dispatchState == .mayHaveDispatched(unitCount: self.units(1)))
        #expect(composed.outcome.delivery == nil)
        #expect(composed.outcome.retrySafety == .unsafe)
        #expect(composed.outcome.projection.requiresFreshObservation)
    }

    @Test
    func `homogeneous partial failure retains delivery while contradictions do not`() throws {
        var homogeneous = DesktopActionSequenceAccumulator()
        try homogeneous.record(.outcome(.confirmedChange(
            route: .bridge,
            delivery: self.localBackground,
            unitCount: self.units(2))))
        let partial = try DesktopActionFailure.partial(
            route: .bridge,
            delivery: self.localBackground,
            unitCount: self.units(1),
            message: "Cleanup failed")
        let retained = homogeneous.failure(combining: partial, message: "Composite cleanup failed")
        #expect(try retained.outcome == .partial(
            route: .bridge,
            delivery: self.localBackground,
            unitCount: self.units(3)))

        var mixed = homogeneous
        try mixed.record(.outcome(.confirmedChange(
            route: .local,
            delivery: self.localForeground,
            unitCount: self.units(1))))
        let suppressed = mixed.failure(combining: partial, message: "Composite cleanup failed")
        #expect(suppressed.outcome.state == .indeterminate)
        #expect(suppressed.outcome.delivery == nil)
        #expect(try suppressed.outcome.dispatchState == .mayHaveDispatched(unitCount: self.units(4)))
    }

    @Test
    func `response loss evidence and cancellation remain retry unsafe`() throws {
        var sequence = DesktopActionSequenceAccumulator()
        #expect(sequence.cancellationFailure(
            fallbackRoute: .local,
            message: "Cancelled",
            hint: "Retry",
            causeDescription: "cancelled") == nil)

        try sequence.record(.outcome(.confirmedChange(
            route: .bridge,
            delivery: self.localBackground,
            unitCount: self.units(2))))
        let responseLost = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: self.localBackground,
            evidence: .responseLost,
            message: "Response lost")
        let composed = sequence.failure(combining: responseLost, message: "Composite response lost")
        #expect(composed.outcome.evidence == .responseLost)
        #expect(composed.outcome.retrySafety == .unsafe)

        let cancellation = try #require(sequence.cancellationFailure(
            fallbackRoute: .local,
            message: "Cancelled after dispatch",
            hint: "Observe before retrying",
            causeDescription: "cancelled"))
        #expect(cancellation.outcome.route == .bridge)
        #expect(cancellation.outcome.delivery == self.localBackground)
        #expect(try cancellation.outcome.dispatchState == .mayHaveDispatched(unitCount: self.units(2)))
        #expect(cancellation.outcome.projection.requiresFreshObservation)

        var unknownRoute = DesktopActionSequenceAccumulator()
        unknownRoute.record(.dispatched(
            route: nil,
            delivery: self.localForeground,
            unitCount: .one))
        let conservative = try #require(unknownRoute.cancellationFailure(
            fallbackRoute: .local,
            message: "Cancelled",
            hint: "Observe before retrying",
            causeDescription: "cancelled"))
        #expect(conservative.outcome.delivery == nil)
    }

    @Test
    func `require confirmed if reported accepts legacy and rejects every non-confirmed state`() throws {
        try DesktopActionFailure.requireConfirmedIfReported(nil, operation: "Legacy action")
        try DesktopActionFailure.requireConfirmedIfReported(
            .confirmedNoChange(),
            operation: "No-change action")
        try DesktopActionFailure.requireConfirmedIfReported(
            .confirmedChange(delivery: self.localBackground),
            operation: "Confirmed action")

        let nonConfirmed: [DesktopActionOutcome] = [
            .partial(delivery: self.localBackground),
            .dispatchedUnverified(delivery: self.localBackground, evidence: .deliveryAccepted),
            .suspectedNoop(delivery: self.localBackground),
            .refused(reason: .invalidRequest),
            .indeterminate(evidence: .completionUnknown),
        ]
        for outcome in nonConfirmed {
            #expect(throws: DesktopActionFailure.self) {
                try DesktopActionFailure.requireConfirmedIfReported(outcome, operation: "Fixture")
            }
        }
    }

    @Test
    func `target and pinning refusals share the complete canonical projection`() {
        for reason in [
            DesktopActionOutcome.RefusalReason.invalidRequest,
            .targetUnavailable,
            .runtimeIncompatible,
            .permissionDenied,
            .foregroundConsentRequired,
        ] {
            let failure = DesktopActionFailure.preDispatchRefusal(reason: reason, message: "Refused")
            let projection = DesktopActionOutcome.preDispatchRefusalProjection(reason: reason)
            #expect(failure.outcome.projection == projection)
            #expect(projection.state == .refused)
            #expect(projection.dispatchState == .none)
            #expect(!projection.mutationDispatched)
            #expect(projection.retrySafe)
            #expect(!projection.requiresFreshObservation)
            #expect(projection.refusalReason == reason)
        }
    }

    @Test
    func `legacy refusal projection requires the complete zero-dispatch receipt`() {
        let expected = DesktopActionOutcome.preDispatchRefusalProjection(reason: .targetUnavailable)
        #expect(DesktopActionOutcome.preDispatchRefusalProjection(
            reason: .targetUnavailable,
            legacyRetrySafe: true,
            legacyMutationDispatched: false) == expected)

        for receipt in [
            (retrySafe: nil, mutationDispatched: nil),
            (retrySafe: true, mutationDispatched: nil),
            (retrySafe: nil, mutationDispatched: false),
            (retrySafe: false, mutationDispatched: false),
            (retrySafe: true, mutationDispatched: true),
        ] as [(retrySafe: Bool?, mutationDispatched: Bool?)] {
            #expect(DesktopActionOutcome.preDispatchRefusalProjection(
                reason: .targetUnavailable,
                legacyRetrySafe: receipt.retrySafe,
                legacyMutationDispatched: receipt.mutationDispatched) == nil)
        }
    }

    private func units(_ value: Int) throws -> DesktopActionOutcome.DispatchUnitCount {
        try #require(DesktopActionOutcome.DispatchUnitCount(value))
    }
}
