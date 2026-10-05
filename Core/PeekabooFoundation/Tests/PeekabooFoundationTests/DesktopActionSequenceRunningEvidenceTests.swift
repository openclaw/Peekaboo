import PeekabooFoundation
import Testing

struct DesktopActionSequenceRunningEvidenceTests {
    @Test(arguments: [false, true])
    func `successful sequence retains an operation still running`(withConfirmedPrefix: Bool) throws {
        let delivery = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .background)
        let running = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge, delivery: delivery, evidence: .operationStillRunning, unitCount: .one)
        var sequence = DesktopActionSequenceAccumulator()
        if withConfirmedPrefix {
            sequence.record(.outcome(.confirmedChange(route: .bridge, delivery: delivery, unitCount: .one)))
        }
        sequence.record(.outcome(running))
        let outcome = try #require(sequence.successResolution().outcome)
        #expect(outcome.evidence == .operationStillRunning)
        #expect(outcome.dispatchState.unitCount?.rawValue == (withConfirmedPrefix ? 2 : 1))
        #expect(outcome.projection.requiresFreshObservation)
        #expect(!outcome.projection.retrySafe)

        let batch = try #require(DesktopActionSequenceAccumulator.completedBatch(
            outcomes: [running, .confirmedChange(route: .bridge, delivery: delivery, unitCount: .one)],
            succeededCount: 1,
            attemptedCount: 2))
        #expect(batch.evidence == .operationStillRunning)
        #expect(batch.dispatchState.unitCount?.rawValue == 2)
    }

    @Test
    func `accepted deliveries do not acquire running evidence`() throws {
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.outcome(.dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)))
        #expect(try #require(sequence.successResolution().outcome).evidence == .deliveryAccepted)
    }
}
