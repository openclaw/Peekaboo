import Foundation
import PeekabooFoundation
import Testing

struct DesktopActionOutcomeTests {
    private let backgroundAX = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .background)

    @Test
    func `factories produce the closed action state matrix`() throws {
        let oneUnit = try self.positiveUnitCount(1)
        let twoUnits = try self.positiveUnitCount(2)
        let threeUnits = try self.positiveUnitCount(3)
        let confirmed = DesktopActionOutcome.confirmedChange(delivery: self.backgroundAX, unitCount: oneUnit)
        #expect(confirmed.state == .confirmedChange)
        #expect(confirmed.effect == .confirmed)
        #expect(confirmed.dispatchState == .dispatched(unitCount: oneUnit))
        #expect(confirmed.retrySafety == .notApplicable)
        #expect(confirmed.escalation == .none)

        let unchanged = DesktopActionOutcome.confirmedNoChange(route: .bridge)
        #expect(unchanged.effect == .confirmed)
        #expect(unchanged.dispatchState == .none)
        #expect(unchanged.delivery == nil)

        let partial = DesktopActionOutcome.partial(delivery: self.backgroundAX)
        #expect(partial.effect == .partial)
        #expect(partial.retrySafety == .unsafe)
        #expect(partial.escalation == .recoverSideEffect)

        let accepted = DesktopActionOutcome.dispatchedUnverified(
            delivery: self.backgroundAX,
            evidence: .deliveryAccepted,
            unitCount: twoUnits)
        #expect(accepted.effect == .unverifiable)
        #expect(accepted.evidence == .deliveryAccepted)
        #expect(accepted.dispatchState == .dispatched(unitCount: twoUnits))
        #expect(accepted.escalation == .observeBeforeRetry)

        let running = DesktopActionOutcome.dispatchedUnverified(
            delivery: self.backgroundAX,
            evidence: .operationStillRunning)
        #expect(running.effect == .unverifiable)
        #expect(running.evidence == .operationStillRunning)
        #expect(!running.isConfirmed)

        let noOp = DesktopActionOutcome.suspectedNoop(delivery: self.backgroundAX)
        #expect(noOp.effect == .suspectedNoop)
        #expect(noOp.retrySafety == .safe)
        #expect(noOp.escalation == .refreshTarget)

        let refusal = DesktopActionOutcome.refused(reason: .permissionDenied)
        #expect(refusal.effect == .refused)
        #expect(refusal.dispatchState == .none)
        #expect(refusal.escalation == .grantPermission)

        let indeterminate = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: self.backgroundAX,
            evidence: .responseLost,
            unitCount: threeUnits)
        #expect(indeterminate.effect == .unverifiable)
        #expect(indeterminate.dispatchState == .mayHaveDispatched(unitCount: threeUnits))
        #expect(indeterminate.retrySafety == .unsafe)
    }

    @Test
    func `all factories round trip through the validated flat encoding`() throws {
        let outcomes = try [
            DesktopActionOutcome.confirmedChange(
                delivery: self.backgroundAX,
                unitCount: self.positiveUnitCount(1)),
            DesktopActionOutcome.confirmedNoChange(),
            DesktopActionOutcome.partial(route: .bridge, delivery: self.backgroundAX),
            DesktopActionOutcome.dispatchedUnverified(
                delivery: self.backgroundAX,
                evidence: .operationStillRunning),
            DesktopActionOutcome.suspectedNoop(delivery: self.backgroundAX),
            DesktopActionOutcome.refused(route: .bridge, reason: .runtimeIncompatible),
            DesktopActionOutcome.indeterminate(evidence: .completionUnknown),
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
