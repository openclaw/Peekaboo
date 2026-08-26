import Foundation
import PeekabooFoundation
import Testing

struct DesktopActionOutcomeTransformTests {
    private typealias UnverifiedDispatchCase = (
        evidence: DesktopActionOutcome.DispatchedUnverifiedEvidence,
        unitCount: DesktopActionOutcome.DispatchUnitCount?)

    private let originalDelivery = DesktopActionOutcome.Delivery(
        mechanism: .browserProtocol,
        mode: .background)
    private let replacementDelivery = DesktopActionOutcome.Delivery(
        mechanism: .nativeFramework,
        mode: .foreground)

    @Test
    func `dispatch confirmation transforms only unverified dispatches`() throws {
        let one = try self.unitCount(1)
        let unchanged: [DesktopActionOutcome] = [
            .confirmedChange(route: .bridge, delivery: self.originalDelivery, unitCount: one),
            .confirmedNoChange(route: .bridge),
            .partial(route: .bridge, delivery: self.originalDelivery, unitCount: one),
            .suspectedNoop(route: .bridge, delivery: self.originalDelivery, unitCount: one),
            .refused(route: .bridge, reason: .targetUnavailable),
            .indeterminate(
                route: .bridge,
                delivery: self.originalDelivery,
                evidence: .responseLost,
                unitCount: one),
        ]

        for outcome in unchanged {
            for observedChange: Bool? in [nil, false, true] {
                let transformed = outcome.confirmingDispatchedOutcome(observedChange: observedChange)
                #expect(try self.encoded(transformed) == self.encoded(outcome))
            }
        }

        let dispatchedCases: [UnverifiedDispatchCase] = [
            (.deliveryAccepted, nil),
            (.operationStillRunning, one),
        ]
        for (evidence, unitCount) in dispatchedCases {
            let outcome = DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: self.originalDelivery,
                evidence: evidence,
                unitCount: unitCount)

            #expect(try self.encoded(outcome.confirmingDispatchedOutcome(observedChange: nil)) == self.encoded(outcome))
            #expect(outcome.confirmingDispatchedOutcome(observedChange: true) == .confirmedChange(
                route: .bridge,
                delivery: self.originalDelivery,
                unitCount: unitCount))
            #expect(outcome.confirmingDispatchedOutcome(observedChange: false) == .confirmedNoChange(route: .bridge))
        }
    }

    @Test
    func `delivery reprojection covers every state and evidence case`() throws {
        let one = try self.unitCount(1)
        let transformedCases: [(DesktopActionOutcome, DesktopActionOutcome)] = [
            (
                .confirmedChange(route: .bridge, delivery: self.originalDelivery, unitCount: one),
                .confirmedChange(route: .bridge, delivery: self.replacementDelivery, unitCount: one)),
            (
                .partial(route: .bridge, delivery: self.originalDelivery, unitCount: one),
                .partial(route: .bridge, delivery: self.replacementDelivery, unitCount: one)),
            (
                .dispatchedUnverified(
                    route: .bridge,
                    delivery: self.originalDelivery,
                    evidence: .deliveryAccepted),
                .dispatchedUnverified(
                    route: .bridge,
                    delivery: self.replacementDelivery,
                    evidence: .deliveryAccepted)),
            (
                .dispatchedUnverified(
                    route: .bridge,
                    delivery: self.originalDelivery,
                    evidence: .operationStillRunning,
                    unitCount: one),
                .dispatchedUnverified(
                    route: .bridge,
                    delivery: self.replacementDelivery,
                    evidence: .operationStillRunning,
                    unitCount: one)),
            (
                .suspectedNoop(route: .bridge, delivery: self.originalDelivery, unitCount: one),
                .suspectedNoop(route: .bridge, delivery: self.replacementDelivery, unitCount: one)),
            (
                .indeterminate(
                    route: .bridge,
                    delivery: self.originalDelivery,
                    evidence: .responseLost),
                .indeterminate(
                    route: .bridge,
                    delivery: self.replacementDelivery,
                    evidence: .responseLost)),
            (
                .indeterminate(
                    route: .bridge,
                    delivery: self.originalDelivery,
                    evidence: .completionUnknown,
                    unitCount: one),
                .indeterminate(
                    route: .bridge,
                    delivery: self.replacementDelivery,
                    evidence: .completionUnknown,
                    unitCount: one)),
        ]

        for (outcome, expected) in transformedCases {
            #expect(outcome.reprojectingDelivery(self.replacementDelivery) == expected)
        }

        let unchanged: [DesktopActionOutcome] = [
            .confirmedNoChange(route: .bridge),
            .refused(route: .bridge, reason: .permissionDenied),
            .indeterminate(route: .bridge, evidence: .responseLost, unitCount: one),
            .indeterminate(route: .bridge, evidence: .completionUnknown),
        ]
        for outcome in unchanged {
            #expect(try self.encoded(outcome.reprojectingDelivery(self.replacementDelivery)) == self.encoded(outcome))
        }
    }

    @Test
    func `unit count filling covers every state and preserves existing counts`() throws {
        let one = try self.unitCount(1)
        let two = try self.unitCount(2)
        let missingCountCases: [(DesktopActionOutcome, DesktopActionOutcome)] = [
            (
                .confirmedChange(route: .bridge, delivery: self.originalDelivery),
                .confirmedChange(route: .bridge, delivery: self.originalDelivery, unitCount: two)),
            (
                .confirmedNoChange(route: .bridge),
                .confirmedNoChange(route: .bridge)),
            (
                .partial(route: .bridge, delivery: self.originalDelivery),
                .partial(route: .bridge, delivery: self.originalDelivery)),
            (
                .dispatchedUnverified(
                    route: .bridge,
                    delivery: self.originalDelivery,
                    evidence: .deliveryAccepted),
                .dispatchedUnverified(
                    route: .bridge,
                    delivery: self.originalDelivery,
                    evidence: .deliveryAccepted,
                    unitCount: two)),
            (
                .dispatchedUnverified(
                    route: .bridge,
                    delivery: self.originalDelivery,
                    evidence: .operationStillRunning),
                .dispatchedUnverified(
                    route: .bridge,
                    delivery: self.originalDelivery,
                    evidence: .operationStillRunning,
                    unitCount: two)),
            (
                .suspectedNoop(route: .bridge, delivery: self.originalDelivery),
                .suspectedNoop(route: .bridge, delivery: self.originalDelivery, unitCount: two)),
            (
                .refused(route: .bridge, reason: .invalidRequest),
                .refused(route: .bridge, reason: .invalidRequest)),
            (
                .indeterminate(
                    route: .bridge,
                    delivery: self.originalDelivery,
                    evidence: .responseLost),
                .indeterminate(
                    route: .bridge,
                    delivery: self.originalDelivery,
                    evidence: .responseLost)),
            (
                .indeterminate(route: .bridge, evidence: .completionUnknown),
                .indeterminate(route: .bridge, evidence: .completionUnknown)),
        ]

        for (outcome, expected) in missingCountCases {
            #expect(outcome.fillingSuccessfulDispatchUnitCount(two) == expected)
        }

        let existingCountCases: [DesktopActionOutcome] = [
            .confirmedChange(route: .bridge, delivery: self.originalDelivery, unitCount: one),
            .partial(route: .bridge, delivery: self.originalDelivery, unitCount: one),
            .dispatchedUnverified(
                route: .bridge,
                delivery: self.originalDelivery,
                evidence: .deliveryAccepted,
                unitCount: one),
            .dispatchedUnverified(
                route: .bridge,
                delivery: self.originalDelivery,
                evidence: .operationStillRunning,
                unitCount: one),
            .suspectedNoop(route: .bridge, delivery: self.originalDelivery, unitCount: one),
            .indeterminate(
                route: .bridge,
                delivery: self.originalDelivery,
                evidence: .responseLost,
                unitCount: one),
            .indeterminate(route: .bridge, evidence: .completionUnknown, unitCount: one),
        ]
        for outcome in existingCountCases {
            #expect(try self.encoded(outcome.fillingSuccessfulDispatchUnitCount(two)) == self.encoded(outcome))
        }
    }

    @Test
    func `exact dispatch policy enforces state delivery and unit count`() throws {
        let one = try self.unitCount(1)
        let two = try self.unitCount(2)
        let requiredCount = DesktopActionOutcome.SuccessPolicy.confirmedNoChangeOrDispatched(
            requiring: self.originalDelivery,
            unitCount: .required)
        let exactlyOne = DesktopActionOutcome.SuccessPolicy.confirmedNoChangeOrDispatched(
            requiring: self.originalDelivery,
            unitCount: .exact(one))

        for outcome in [
            DesktopActionOutcome.confirmedNoChange(),
            DesktopActionOutcome.confirmedNoChange(route: .bridge),
        ] {
            #expect(requiredCount.accepts(outcome))
            #expect(exactlyOne.accepts(outcome))
        }

        for evidence in [
            DesktopActionOutcome.DispatchedUnverifiedEvidence.deliveryAccepted,
            .operationStillRunning,
        ] {
            let oneUnit = DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: self.originalDelivery,
                evidence: evidence,
                unitCount: one)
            let twoUnits = DesktopActionOutcome.dispatchedUnverified(
                delivery: self.originalDelivery,
                evidence: evidence,
                unitCount: two)
            let missingCount = DesktopActionOutcome.dispatchedUnverified(
                delivery: self.originalDelivery,
                evidence: evidence)

            #expect(requiredCount.accepts(oneUnit))
            #expect(requiredCount.accepts(twoUnits))
            #expect(!requiredCount.accepts(missingCount))
            #expect(exactlyOne.accepts(oneUnit))
            #expect(!exactlyOne.accepts(twoUnits))
            #expect(!exactlyOne.accepts(missingCount))
        }

        let wrongDeliveryCases = [
            DesktopActionOutcome.Delivery(mechanism: .capturePipeline, mode: .background),
            DesktopActionOutcome.Delivery(mechanism: .browserProtocol, mode: .foreground),
        ]
        for delivery in wrongDeliveryCases {
            let outcome = DesktopActionOutcome.dispatchedUnverified(
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: one)
            #expect(!requiredCount.accepts(outcome))
            #expect(!exactlyOne.accepts(outcome))
        }

        let rejectedStates: [DesktopActionOutcome] = [
            .confirmedChange(delivery: self.originalDelivery, unitCount: one),
            .partial(delivery: self.originalDelivery, unitCount: one),
            .suspectedNoop(delivery: self.originalDelivery, unitCount: one),
            .refused(reason: .targetUnavailable),
            .indeterminate(
                delivery: self.originalDelivery,
                evidence: .completionUnknown,
                unitCount: one),
        ]
        for outcome in rejectedStates {
            #expect(!requiredCount.accepts(outcome))
            #expect(!exactlyOne.accepts(outcome))
        }
    }

    private func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func unitCount(_ value: Int) throws -> DesktopActionOutcome.DispatchUnitCount {
        try #require(DesktopActionOutcome.DispatchUnitCount(value))
    }
}
