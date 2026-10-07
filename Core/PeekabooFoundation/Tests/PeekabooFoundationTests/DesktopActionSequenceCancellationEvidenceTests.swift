import PeekabooFoundation
import Testing

struct DesktopActionSequenceCancellationEvidenceTests {
    @Test(arguments: [
        DesktopActionOutcome.IndeterminateEvidence.responseLost,
        DesktopActionOutcome.IndeterminateEvidence.completionUnknown,
    ])
    func `cancellation retains the strongest reported uncertainty`(
        evidence: DesktopActionOutcome.IndeterminateEvidence) throws
    {
        let leaf = DesktopActionOutcome.indeterminate(
            route: .bridge, evidence: evidence, unitCount: .one)
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.outcome(leaf))
        let cancelled = try #require(sequence.cancellationFailure(
            fallbackRoute: .local, message: "Cancelled", hint: "Observe", causeDescription: "Cancellation"))
        #expect(cancelled.outcome.evidence.rawValue == evidence.rawValue)
        #expect(cancelled.outcome.route == .bridge)
        #expect(cancelled.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        #expect(cancelled.outcome.projection.requiresFreshObservation)
        #expect(!cancelled.outcome.projection.retrySafe)

        let interrupted = try #require(DesktopActionSequenceAccumulator.interruptedBatch(
            completedOutcomes: [leaf],
            succeededCount: 0,
            attemptedCount: 1,
            plannedCount: 2,
            inFlightAttemptMayHaveDispatched: true))
        let outcome = try #require(interrupted.outcome)
        #expect(outcome.evidence.rawValue == evidence.rawValue)
        #expect(outcome.route == .bridge)
        #expect(outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(outcome.projection.requiresFreshObservation)
        #expect(!outcome.projection.retrySafe)
    }

    @Test
    func `cancellation before mutation does not manufacture an action failure`() {
        let sequence = DesktopActionSequenceAccumulator()
        #expect(sequence.cancellationFailure(
            fallbackRoute: .bridge, message: "Cancelled", hint: "Observe", causeDescription: "Cancellation") == nil)
    }
}
