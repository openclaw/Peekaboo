import Foundation
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing

struct DesktopActionOutcomeTests {
    private let backgroundAX = DesktopActionOutcomeFixtures.backgroundAccessibilityDelivery

    @Test
    func `factories produce the closed action state matrix`() throws {
        let twoUnits = try self.positiveUnitCount(2)
        for item in DesktopActionOutcomeFixtures.canonicalCases {
            #expect(item.outcome.state == item.state)
            #expect(item.outcome.effect == item.effect)
            #expect(item.outcome.route == item.route)
            #expect(item.outcome.delivery == item.delivery)
            #expect(item.outcome.evidence == item.evidence)
            #expect(item.outcome.dispatchState == item.dispatchState)
            #expect(item.outcome.retrySafety == item.retrySafety)
            #expect(item.outcome.escalation == item.escalation)
            #expect(item.outcome.refusalReason == item.refusalReason)
            #expect(item.isFailureEligible == !item.outcome.isConfirmed)
            #expect(item.failure?.outcome == (item.outcome.isConfirmed ? nil : item.outcome))
        }

        let accepted = DesktopActionOutcome.dispatchedUnverified(
            delivery: self.backgroundAX,
            evidence: .deliveryAccepted,
            unitCount: twoUnits)
        #expect(accepted.effect == .unverifiable)
        #expect(accepted.evidence == .deliveryAccepted)
        #expect(accepted.dispatchState == .dispatched(unitCount: twoUnits))
        #expect(accepted.escalation == .observeBeforeRetry)
    }

    @Test
    func `all factories round trip through the validated flat encoding`() throws {
        let outcomes = try DesktopActionOutcomeFixtures.canonicalCases.map(\.outcome) + [
            DesktopActionOutcome.dispatchedUnverified(
                delivery: self.backgroundAX,
                evidence: .deliveryAccepted),
            DesktopActionOutcome.refused(route: .bridge, reason: .runtimeIncompatible),
            DesktopActionOutcome.indeterminate(
                evidence: .completionUnknown,
                unitCount: self.positiveUnitCount(1)),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let decoder = JSONDecoder()

        for outcome in outcomes {
            let data = try encoder.encode(outcome)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["effect"] as? String == outcome.effect.rawValue)
            #expect(object["dispatch_state"] != nil)
            #expect(object["retry_safety"] != nil)
            #expect(object["escalation"] != nil)
            #expect(try decoder.decode(DesktopActionOutcome.self, from: data) == outcome)
        }
    }

    @Test
    func `decoder rejects a forged effect`() throws {
        let data = try self.mutatedJSON(
            DesktopActionOutcome.indeterminate(evidence: .responseLost))
        { object in
            object["effect"] = "confirmed"
        }

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DesktopActionOutcome.self, from: data)
        }
    }

    @Test
    func `decoder rejects contradictory state safety fields`() throws {
        let data = try self.mutatedJSON(
            DesktopActionOutcome.refused(reason: .targetUnavailable))
        { object in
            object["dispatch_state"] = "dispatched"
        }

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DesktopActionOutcome.self, from: data)
        }
    }

    @Test
    func `decoder rejects incomplete delivery and invalid unit counts`() throws {
        #expect(DesktopActionOutcome.DispatchUnitCount(0) == nil)
        #expect(DesktopActionOutcome.DispatchUnitCount(-1) == nil)

        let incompleteDelivery = try self.mutatedJSON(
            DesktopActionOutcome.dispatchedUnverified(
                delivery: self.backgroundAX,
                evidence: .deliveryAccepted))
        { object in
            object.removeValue(forKey: "delivery_mode")
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DesktopActionOutcome.self, from: incompleteDelivery)
        }

        let invalidCount = try self.mutatedJSON(
            DesktopActionOutcome.confirmedChange(
                delivery: self.backgroundAX,
                unitCount: self.positiveUnitCount(1)))
        { object in
            object["dispatched_unit_count"] = 0
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DesktopActionOutcome.self, from: invalidCount)
        }
    }

    @Test
    func `failure carries only non-confirmed outcomes and projects LocalizedError context`() throws {
        let outcome = DesktopActionOutcome.indeterminate(evidence: .completionUnknown)
        let failure = try #require(DesktopActionFailure(
            outcome: outcome,
            message: "Click outcome is indeterminate",
            hint: "Observe the target before retrying",
            causeDescription: "The response channel closed"))

        #expect(failure.errorDescription == "Click outcome is indeterminate")
        #expect(failure.recoverySuggestion == "Observe the target before retrying")
        #expect(failure.failureReason == "The response channel closed")
        #expect(DesktopActionFailure(
            outcome: .confirmedNoChange(),
            message: "This must not be representable") == nil)

        let encoded = try JSONEncoder().encode(failure)
        #expect(try JSONDecoder().decode(DesktopActionFailure.self, from: encoded) == failure)

        let typedFailure = DesktopActionFailure.dispatchedUnverified(
            delivery: self.backgroundAX,
            evidence: .operationStillRunning,
            message: "Accessibility operation is still running",
            hint: "Observe before retrying")
        #expect(typedFailure.outcome.evidence == .operationStillRunning)
        #expect(typedFailure.outcome.effect == .unverifiable)

        let routedFailure = typedFailure.routed(to: .bridge)
        #expect(routedFailure.outcome.route == .bridge)
        #expect(routedFailure.message == typedFailure.message)
        #expect(routedFailure.hint == typedFailure.hint)
        #expect(routedFailure.causeDescription == typedFailure.causeDescription)
    }

    @Test
    func `rerouting preserves every validated outcome field except route`() throws {
        let original = try DesktopActionOutcome.partial(
            delivery: self.backgroundAX,
            unitCount: self.positiveUnitCount(2))

        let routed = original.routed(to: .bridge)

        #expect(routed.route == .bridge)
        #expect(routed.state == original.state)
        #expect(routed.effect == original.effect)
        #expect(routed.delivery == original.delivery)
        #expect(routed.evidence == original.evidence)
        #expect(routed.dispatchState == original.dispatchState)
        #expect(routed.retrySafety == original.retrySafety)
        #expect(routed.escalation == original.escalation)
        #expect(routed.refusalReason == original.refusalReason)
    }

    @Test
    func `failure decoder rejects a confirmed outcome`() throws {
        let validFailure = try #require(DesktopActionFailure(
            outcome: .refused(reason: .invalidRequest),
            message: "Invalid request"))
        let data = try JSONEncoder().encode(validFailure)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let confirmedData = try JSONEncoder().encode(DesktopActionOutcome.confirmedNoChange())
        object["outcome"] = try JSONSerialization.jsonObject(with: confirmedData)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                DesktopActionFailure.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
    }

    private func mutatedJSON(
        _ outcome: DesktopActionOutcome,
        mutation: (inout [String: Any]) -> Void) throws -> Data
    {
        let data = try JSONEncoder().encode(outcome)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        mutation(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func positiveUnitCount(_ value: Int) throws -> DesktopActionOutcome.DispatchUnitCount {
        try #require(DesktopActionOutcome.DispatchUnitCount(value))
    }
}
