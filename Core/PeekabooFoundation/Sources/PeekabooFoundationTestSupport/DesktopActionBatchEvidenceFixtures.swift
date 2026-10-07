import PeekabooFoundation

/// The same independent receipt-composition oracle for Foundation, CLI and MCP consumers.
public struct DesktopActionBatchEvidenceFixture: Sendable {
    public let name: String
    public let outcomes: [DesktopActionOutcome]
    public let failingIndexes: Set<Int>
    public let expectedOutcome: DesktopActionOutcome

    public var succeededCount: Int {
        self.outcomes.count - self.failingIndexes.count
    }
}

extension DesktopActionOutcomeFixtures {
    public static let batchEvidenceCases: [DesktopActionBatchEvidenceFixture] = {
        let delivery = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .background)
        let running = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge, delivery: delivery, evidence: .operationStillRunning, unitCount: .one)
        let accepted = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge, delivery: delivery, evidence: .deliveryAccepted, unitCount: .one)
        let confirmed = DesktopActionOutcome.confirmedChange(route: .bridge, delivery: delivery, unitCount: .one)
        let lost = DesktopActionOutcome.indeterminate(
            route: .bridge, delivery: delivery, evidence: .responseLost, unitCount: .one)
        let runningPair = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: delivery,
            evidence: .operationStillRunning,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let acceptedPair = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: delivery,
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let lostPair = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: delivery,
            evidence: .responseLost,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        return [
            .init(
                name: "running-confirmed",
                outcomes: [running, confirmed],
                failingIndexes: [0],
                expectedOutcome: runningPair),
            .init(
                name: "confirmed-running",
                outcomes: [confirmed, running],
                failingIndexes: [1],
                expectedOutcome: runningPair),
            .init(
                name: "running-accepted",
                outcomes: [running, accepted],
                failingIndexes: [0],
                expectedOutcome: runningPair),
            .init(
                name: "accepted-running",
                outcomes: [accepted, running],
                failingIndexes: [1],
                expectedOutcome: runningPair),
            .init(
                name: "accepted-accepted",
                outcomes: [accepted, accepted],
                failingIndexes: [],
                expectedOutcome: acceptedPair),
            .init(
                name: "running-response-lost",
                outcomes: [running, lost],
                failingIndexes: [0, 1],
                expectedOutcome: lostPair),
            .init(
                name: "response-lost-running",
                outcomes: [lost, running],
                failingIndexes: [0, 1],
                expectedOutcome: lostPair),
        ]
    }()
}
