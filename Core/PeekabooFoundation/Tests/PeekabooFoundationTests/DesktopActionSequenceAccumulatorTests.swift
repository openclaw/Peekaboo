import CoreGraphics
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
    func `compatible mixed-mode sequence reports foreground maximum impact and exact units`() throws {
        let background = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .background)
        let foreground = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .foreground)
        var sequence = DesktopActionSequenceAccumulator()
        try sequence.record(.outcome(.confirmedChange(
            route: .bridge,
            delivery: background,
            unitCount: self.units(2))))
        try sequence.record(.outcome(.confirmedChange(
            route: .bridge,
            delivery: foreground,
            unitCount: self.units(3))))

        let resolution = sequence.successResolution()
        #expect(try resolution.outcome == .confirmedChange(
            route: .bridge,
            delivery: foreground,
            unitCount: self.units(5)))
        #expect(try resolution.mutationDisposition == .definite(unitCount: self.units(5)))
    }

    @Test
    func `mixed mechanisms retain composite foreground delivery and exact units`() throws {
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.dispatched(
            route: .local,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            unitCount: .one))
        sequence.record(.dispatched(
            route: .local,
            delivery: .init(mechanism: .accessibilityValue, mode: .foreground),
            unitCount: .one))
        sequence.record(.dispatched(
            route: .local,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: .one))

        let resolution = sequence.successResolution()
        #expect(try resolution.outcome == .dispatchedUnverified(
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: self.units(3)))
        #expect(try resolution.mutationDisposition == .definite(unitCount: self.units(3)))
    }

    @Test
    func `homogeneous suspected no-op sequence preserves observed no-change evidence`() throws {
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.outcome(.suspectedNoop(
            route: .bridge,
            delivery: self.localBackground,
            unitCount: .one)))
        try sequence.record(.outcome(.suspectedNoop(
            route: .bridge,
            delivery: self.localBackground,
            unitCount: self.units(2))))

        let resolution = sequence.successResolution()
        #expect(try resolution.outcome == .suspectedNoop(
            route: .bridge,
            delivery: self.localBackground,
            unitCount: self.units(3)))
        #expect(try resolution.mutationDisposition == .definite(unitCount: self.units(3)))
        #expect(resolution.retrySafe)
        #expect(!resolution.requiresFreshObservation)
    }

    @Test
    func `suspected no-op sequence does not absorb mixed evidence`() throws {
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.outcome(.suspectedNoop(
            delivery: self.localBackground,
            unitCount: .one)))
        sequence.record(.outcome(.dispatchedUnverified(
            delivery: self.localBackground,
            evidence: .deliveryAccepted,
            unitCount: .one)))

        #expect(try sequence.successResolution().outcome == .dispatchedUnverified(
            delivery: self.localBackground,
            evidence: .deliveryAccepted,
            unitCount: self.units(2)))
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
    func `mixed route suppresses aggregate while mixed mechanisms become composite`() throws {
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
        #expect(mixedDelivery.successResolution().outcome == .confirmedChange(
            delivery: .init(mechanism: .composite, mode: .foreground)))
        #expect(!mixedDelivery.successResolution().requiresFreshObservation)
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
    func `composed dispatched failures preserve selected leaf evidence`() throws {
        let leaf = try self.selectedLeaf()
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.outcome(.confirmedChange(
            route: .bridge,
            delivery: self.localBackground,
            unitCount: .one)))

        let partial = DesktopActionFailure.partial(
            route: .bridge,
            delivery: self.localBackground,
            unitCount: .one,
            message: "Selection partially completed")
            .selectingLeaves([leaf])
        let composedPartial = sequence.failure(combining: partial, message: "Composite partial failure")
        #expect(composedPartial.outcome.state == .partial)
        #expect(composedPartial.selectedLeafEvidence == [leaf])

        let indeterminate = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: self.localBackground,
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Selection completion is unknown")
            .selectingLeaves([leaf])
        let composedIndeterminate = sequence.failure(
            combining: indeterminate,
            message: "Composite indeterminate failure")
        #expect(composedIndeterminate.outcome.state == .indeterminate)
        #expect(composedIndeterminate.selectedLeafEvidence == [leaf])
    }

    @Test
    func `dispatch unit count overflow degrades to unknown`() throws {
        var sequence = DesktopActionSequenceAccumulator()
        try sequence.record(.dispatched(
            route: .local,
            delivery: self.localBackground,
            unitCount: self.units(Int.max)))
        sequence.record(.dispatched(
            route: .local,
            delivery: self.localBackground,
            unitCount: .one))

        #expect(sequence.mutationDisposition == .definite(unitCount: nil))
        #expect(sequence.successResolution().outcome == .dispatchedUnverified(
            delivery: self.localBackground,
            evidence: .deliveryAccepted,
            unitCount: nil))
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
    func `completed batch preserves one receipt and composes only homogeneous partial delivery`() throws {
        let noOp = DesktopActionOutcome.suspectedNoop(
            delivery: self.localBackground,
            unitCount: .one)
        #expect(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [noOp],
            succeededCount: 0,
            attemptedCount: 1) == noOp)

        let confirmed = DesktopActionOutcome.confirmedChange(
            delivery: self.localBackground,
            unitCount: .one)
        let partial = try #require(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [confirmed, noOp],
            succeededCount: 1,
            attemptedCount: 2))
        #expect(partial.state == .partial)
        #expect(partial.delivery == self.localBackground)
        let twoUnits = try self.units(2)
        #expect(partial.dispatchState.unitCount == twoUnits)

        let reportedPartial = DesktopActionOutcome.partial(
            delivery: self.localBackground,
            unitCount: .one)
        let allFailedPartial = try #require(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [reportedPartial, reportedPartial],
            succeededCount: 0,
            attemptedCount: 2))
        #expect(allFailedPartial.state == .partial)
        #expect(allFailedPartial.dispatchState.unitCount == twoUnits)

        let partialAndNoChange = try #require(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [reportedPartial, .confirmedNoChange()],
            succeededCount: 0,
            attemptedCount: 2))
        #expect(partialAndNoChange.state == .partial)
        #expect(partialAndNoChange.dispatchState.unitCount == .one)

        let partialAndResponseLoss = try #require(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [
                reportedPartial,
                .indeterminate(
                    delivery: self.localBackground,
                    evidence: .responseLost,
                    unitCount: .one),
            ],
            succeededCount: 0,
            attemptedCount: 2))
        #expect(partialAndResponseLoss.state == .indeterminate)
        #expect(partialAndResponseLoss.evidence == .responseLost)
        #expect(partialAndResponseLoss.dispatchState == .mayHaveDispatched(unitCount: twoUnits))

        let partialAndUnverified = try #require(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [
                reportedPartial,
                .dispatchedUnverified(
                    delivery: self.localBackground,
                    evidence: .deliveryAccepted,
                    unitCount: .one),
            ],
            succeededCount: 0,
            attemptedCount: 2))
        #expect(partialAndUnverified.state == .dispatchedUnverified)
        #expect(partialAndUnverified.dispatchState == .dispatched(unitCount: twoUnits))

        let foreground = DesktopActionOutcome.suspectedNoop(
            delivery: .init(mechanism: .processTargetedEvents, mode: .foreground),
            unitCount: .one)
        let mixedModePartial = try #require(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [confirmed, foreground],
            succeededCount: 1,
            attemptedCount: 2))
        #expect(mixedModePartial.state == .partial)
        #expect(mixedModePartial.delivery == .init(mechanism: .processTargetedEvents, mode: .foreground))
        #expect(mixedModePartial.dispatchState.unitCount == twoUnits)

        let mixedDelivery = DesktopActionOutcome.suspectedNoop(
            delivery: self.localForeground,
            unitCount: .one)
        let compositePartial = try #require(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [confirmed, mixedDelivery],
            succeededCount: 1,
            attemptedCount: 2))
        #expect(compositePartial.state == .partial)
        #expect(compositePartial.delivery == .init(mechanism: .composite, mode: .foreground))
        #expect(compositePartial.dispatchState.unitCount == twoUnits)
        #expect(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [confirmed],
            succeededCount: 1,
            attemptedCount: 2) == nil)
    }

    @Test
    func `interrupted batch never promotes its completed prefix to whole batch confirmation`() throws {
        let confirmed = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: self.localBackground,
            unitCount: .one)

        let betweenTargets = try #require(DesktopActionSequenceAccumulator.interruptedBatch(
            completedOutcomes: [confirmed],
            succeededCount: 1,
            attemptedCount: 1,
            plannedCount: 2,
            inFlightAttemptMayHaveDispatched: false))
        let betweenTargetsOutcome = try #require(betweenTargets.outcome)
        #expect(betweenTargets.effect == .partial)
        #expect(betweenTargetsOutcome.state == .partial)
        #expect(betweenTargetsOutcome.route == .bridge)
        #expect(betweenTargetsOutcome.delivery == self.localBackground)
        #expect(betweenTargetsOutcome.dispatchState == .dispatched(unitCount: .one))

        let duringTarget = try #require(DesktopActionSequenceAccumulator.interruptedBatch(
            completedOutcomes: [confirmed],
            succeededCount: 1,
            attemptedCount: 1,
            plannedCount: 2,
            inFlightAttemptMayHaveDispatched: true))
        let duringTargetOutcome = try #require(duringTarget.outcome)
        #expect(duringTarget.effect == .unverifiable)
        #expect(duringTargetOutcome.state == .indeterminate)
        #expect(duringTargetOutcome.route == .bridge)
        #expect(duringTargetOutcome.delivery == nil)
        #expect(try duringTargetOutcome.dispatchState == .mayHaveDispatched(unitCount: self.units(2)))
        #expect(duringTargetOutcome.retrySafety == .unsafe)
        #expect(duringTargetOutcome.projection.requiresFreshObservation)

        let noChange = try #require(DesktopActionSequenceAccumulator.interruptedBatch(
            completedOutcomes: [.confirmedNoChange(route: .bridge)],
            succeededCount: 1,
            attemptedCount: 1,
            plannedCount: 2,
            inFlightAttemptMayHaveDispatched: false))
        #expect(noChange.outcome == nil)
        #expect(noChange.effect == .suspectedNoop)
        let refusal = try #require(DesktopActionSequenceAccumulator.interruptedBatch(
            completedOutcomes: [.refused(route: .bridge, reason: .targetUnavailable)],
            succeededCount: 0,
            attemptedCount: 1,
            plannedCount: 2,
            inFlightAttemptMayHaveDispatched: false))
        #expect(refusal.outcome?.state == .refused)
        #expect(refusal.effect == .refused)
        let mixedRefusals = try #require(DesktopActionSequenceAccumulator.interruptedBatch(
            completedOutcomes: [
                .refused(route: .bridge, reason: .targetUnavailable),
                .refused(route: .bridge, reason: .permissionDenied),
            ],
            succeededCount: 0,
            attemptedCount: 2,
            plannedCount: 3,
            inFlightAttemptMayHaveDispatched: false))
        #expect(mixedRefusals.outcome == nil)
        #expect(mixedRefusals.effect == .refused)
        let missingRefusalReceipt = try #require(DesktopActionSequenceAccumulator.interruptedBatch(
            completedOutcomes: [
                .refused(route: .bridge, reason: .targetUnavailable),
                nil,
            ],
            succeededCount: 0,
            attemptedCount: 2,
            plannedCount: 3,
            inFlightAttemptMayHaveDispatched: false))
        #expect(missingRefusalReceipt.outcome?.state == .indeterminate)
        #expect(missingRefusalReceipt.effect == .unverifiable)
        let receiptlessInFlight = try #require(DesktopActionSequenceAccumulator.interruptedBatch(
            completedOutcomes: [nil],
            succeededCount: 1,
            attemptedCount: 1,
            plannedCount: 2,
            inFlightAttemptMayHaveDispatched: true))
        let receiptlessInFlightOutcome = try #require(receiptlessInFlight.outcome)
        #expect(receiptlessInFlight.effect == .unverifiable)
        #expect(receiptlessInFlightOutcome.state == .indeterminate)
        #expect(receiptlessInFlightOutcome.delivery == nil)
        #expect(try receiptlessInFlightOutcome.dispatchState == .mayHaveDispatched(unitCount: self.units(2)))
        #expect(receiptlessInFlightOutcome.retrySafety == .unsafe)
        let firstInFlight = try #require(DesktopActionSequenceAccumulator.interruptedBatch(
            completedOutcomes: [],
            succeededCount: 0,
            attemptedCount: 0,
            plannedCount: 1,
            inFlightAttemptMayHaveDispatched: true))
        let firstInFlightOutcome = try #require(firstInFlight.outcome)
        #expect(firstInFlight.effect == .unverifiable)
        #expect(firstInFlightOutcome.state == .indeterminate)
        #expect(firstInFlightOutcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        #expect(firstInFlightOutcome.retrySafety == .unsafe)
        let receiptlessBetweenTargets = try #require(DesktopActionSequenceAccumulator.interruptedBatch(
            completedOutcomes: [nil],
            succeededCount: 1,
            attemptedCount: 1,
            plannedCount: 2,
            inFlightAttemptMayHaveDispatched: false))
        #expect(receiptlessBetweenTargets.outcome == nil)
        #expect(receiptlessBetweenTargets.effect == .partial)
        #expect(DesktopActionSequenceAccumulator.interruptedBatch(
            completedOutcomes: [confirmed],
            succeededCount: 2,
            attemptedCount: 1,
            plannedCount: 2,
            inFlightAttemptMayHaveDispatched: true) == nil)
    }

    @Test
    func `completed batch does not weaken response loss to definite partial completion`() throws {
        let confirmed = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: self.localBackground,
            unitCount: .one)
        let responseLost = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: self.localBackground,
            evidence: .responseLost,
            unitCount: .one)

        let aggregate = try #require(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [confirmed, responseLost],
            succeededCount: 1,
            attemptedCount: 2))

        #expect(aggregate.state == .indeterminate)
        #expect(aggregate.route == .bridge)
        #expect(aggregate.delivery == self.localBackground)
        #expect(aggregate.evidence == .responseLost)
        #expect(try aggregate.dispatchState == .mayHaveDispatched(unitCount: self.units(2)))
        #expect(aggregate.retrySafety == .unsafe)
        #expect(aggregate.escalation == .observeBeforeRetry)
        #expect(aggregate.projection.requiresFreshObservation)

        let unknownUnits = try #require(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [
                confirmed,
                .indeterminate(
                    route: .bridge,
                    delivery: self.localBackground,
                    evidence: .responseLost),
            ],
            succeededCount: 1,
            attemptedCount: 2))
        #expect(unknownUnits.dispatchState == .mayHaveDispatched(unitCount: nil))
    }

    @Test
    func `completed batch treats missing receipts as possible dispatch without erasing response loss`() throws {
        let responseLost = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: self.localBackground,
            evidence: .responseLost,
            unitCount: .one)

        let mixed = try #require(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [responseLost, nil],
            succeededCount: 0,
            attemptedCount: 2))

        #expect(mixed.state == .indeterminate)
        #expect(mixed.route == .bridge)
        #expect(mixed.delivery == self.localBackground)
        #expect(mixed.evidence == .responseLost)
        #expect(try mixed.dispatchState == .mayHaveDispatched(unitCount: self.units(2)))
        #expect(mixed.retrySafety == .unsafe)
        #expect(mixed.projection.requiresFreshObservation)
    }

    @Test
    func `completed batch preserves legacy omission when every receipt is missing`() {
        #expect(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [nil, nil],
            succeededCount: 2,
            attemptedCount: 2) == nil)
        #expect(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [nil, nil],
            succeededCount: 0,
            attemptedCount: 2) == nil)
    }

    @Test
    func `completed batch preserves homogeneous suspected no-op evidence`() throws {
        let noOp = DesktopActionOutcome.suspectedNoop(
            route: .bridge,
            delivery: self.localBackground,
            unitCount: .one)
        let aggregate = DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [noOp, noOp],
            succeededCount: 0,
            attemptedCount: 2)

        #expect(try aggregate == .suspectedNoop(
            route: .bridge,
            delivery: self.localBackground,
            unitCount: self.units(2)))

        let differentRoute = DesktopActionOutcome.suspectedNoop(
            route: .local,
            delivery: self.localBackground,
            unitCount: .one)
        #expect(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [noOp, differentRoute],
            succeededCount: 0,
            attemptedCount: 2) == nil)

        let refusal = DesktopActionOutcome.refused(route: .bridge, reason: .targetUnavailable)
        #expect(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [noOp, refusal],
            succeededCount: 0,
            attemptedCount: 2) == nil)
    }

    @Test
    func `completed batch preserves compatible refusals and rejects contradictory refusal receipts`() throws {
        let refusal = DesktopActionOutcome.refused(route: .bridge, reason: .targetUnavailable)
        #expect(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [refusal, refusal],
            succeededCount: 0,
            attemptedCount: 2) == refusal)

        let differentReason = DesktopActionOutcome.refused(route: .bridge, reason: .permissionDenied)
        #expect(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [refusal, differentReason],
            succeededCount: 0,
            attemptedCount: 2) == nil)

        let differentRoute = DesktopActionOutcome.refused(route: .local, reason: .targetUnavailable)
        #expect(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [refusal, differentRoute],
            succeededCount: 0,
            attemptedCount: 2) == nil)

        let missing = try #require(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [refusal, nil],
            succeededCount: 0,
            attemptedCount: 2))
        #expect(missing.state == .indeterminate)
        #expect(missing.dispatchState == .mayHaveDispatched(unitCount: .one))
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

    private func selectedLeaf() throws -> DesktopSelectedLeafEvidence {
        try DesktopSelectedLeafEvidence(
            kind: .dockItem,
            normalizedSelector: "safari",
            matchKind: .exact,
            selectedTargetReceipt: .init(processIdentifier: 42, processStartIdentity: 99),
            selectedIndex: 0,
            selectedTitle: "Safari",
            selectedIdentifier: "com.apple.Safari",
            selectedRole: "AXDockItem",
            selectedFrame: CGRect(x: 10, y: 10, width: 20, height: 20),
            candidateSetSHA256: String(repeating: "a", count: 64),
            candidateCount: 1)
    }
}
