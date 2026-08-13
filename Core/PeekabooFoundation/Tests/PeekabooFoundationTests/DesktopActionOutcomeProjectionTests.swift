import Foundation
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing

struct DesktopActionOutcomeProjectionTests {
    @Test
    func `projection exposes the exhaustive seven-state table`() {
        let cases = DesktopActionOutcomeFixtures.canonicalCases

        #expect(cases.map(\.state) == Self.allProjectionStates)
        for item in cases {
            let projection = item.outcome.projection
            #expect(projection.outcome == item.outcome)
            #expect(projection.state == item.state)
            #expect(projection.effect == item.effect)
            #expect(projection.route == item.route)
            #expect(projection.deliveryMechanism == item.delivery?.mechanism)
            #expect(projection.deliveryMode == item.delivery?.mode)
            #expect(projection.evidence == item.evidence)
            #expect(projection.dispatchState == item.dispatchState)
            #expect(projection.dispatchedUnitCount == item.unitCount)
            #expect(projection.retrySafety == item.retrySafety)
            #expect(projection.escalation == item.escalation)
            #expect(projection.refusalReason == item.refusalReason)
            #expect(projection.mutationDispatched == item.mutationDispatched)
            #expect(projection.retrySafe == item.retrySafe)
            #expect(projection.requiresFreshObservation == item.requiresFreshObservation)
        }
    }

    @Test
    func `projection round trips every canonical field and compatibility derivation`() throws {
        for outcome in DesktopActionOutcomeFixtures.canonicalCases.map(\.outcome) {
            let projection = outcome.projection
            let data = try JSONEncoder().encode(projection)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

            #expect(object["state"] as? String == projection.state.rawValue)
            #expect(object["effect"] as? String == projection.effect.rawValue)
            #expect(object["route"] as? String == projection.route.rawValue)
            #expect(object["delivery_mechanism"] as? String == projection.deliveryMechanism?.rawValue)
            #expect(object["delivery_mode"] as? String == projection.deliveryMode?.rawValue)
            #expect(object["evidence"] as? String == projection.evidence.rawValue)
            #expect(object["dispatch_state"] as? String == Self.dispatchStateName(projection.dispatchState))
            #expect(object["dispatched_unit_count"] as? Int == projection.dispatchedUnitCount?.rawValue)
            #expect(object["retry_safety"] as? String == projection.retrySafety.rawValue)
            #expect(object["escalation"] as? String == projection.escalation.rawValue)
            #expect(object["refusal_reason"] as? String == projection.refusalReason?.rawValue)
            #expect(object["mutation_dispatched"] as? Bool == projection.mutationDispatched)
            #expect(object["retry_safe"] as? Bool == projection.retrySafe)
            #expect(object["requires_fresh_observation"] as? Bool == projection.requiresFreshObservation)
            #expect(try JSONDecoder().decode(DesktopActionOutcome.Projection.self, from: data) == projection)
        }
    }

    @Test
    func `projection decoder rejects every forged compatibility boolean`() throws {
        for outcome in DesktopActionOutcomeFixtures.canonicalCases.map(\.outcome) {
            let projection = outcome.projection
            for (key, value) in [
                ("mutation_dispatched", projection.mutationDispatched),
                ("retry_safe", projection.retrySafe),
                ("requires_fresh_observation", projection.requiresFreshObservation),
            ] {
                let data = try self.mutatedJSON(projection) { object in
                    object[key] = !value
                }
                #expect(throws: DecodingError.self) {
                    try JSONDecoder().decode(DesktopActionOutcome.Projection.self, from: data)
                }
            }
        }
    }

    @Test
    func `projection decoder requires all compatibility booleans`() throws {
        let projection = DesktopActionOutcome.refused(reason: .invalidRequest).projection
        for key in ["mutation_dispatched", "retry_safe", "requires_fresh_observation"] {
            let data = try self.mutatedJSON(projection) { object in
                object.removeValue(forKey: key)
            }
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(DesktopActionOutcome.Projection.self, from: data)
            }
        }
    }

    @Test
    func `projection decoder delegates forged canonical fields to outcome validation`() throws {
        let projection = DesktopActionOutcome.indeterminate(evidence: .responseLost).projection
        for mutation in [
            { (object: inout [String: Any]) in object["effect"] = "confirmed" },
            { (object: inout [String: Any]) in object["dispatch_state"] = "none" },
            { (object: inout [String: Any]) in object["retry_safety"] = "safe" },
            { (object: inout [String: Any]) in object["escalation"] = "none" },
        ] {
            let data = try self.mutatedJSON(projection, mutation: mutation)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(DesktopActionOutcome.Projection.self, from: data)
            }
        }
    }

    @Test
    func `lost response is dispatched retry unsafe and requires fresh observation`() {
        let projection = DesktopActionOutcome.indeterminate(evidence: .responseLost).projection

        #expect(projection.dispatchState == .mayHaveDispatched(unitCount: nil))
        #expect(projection.mutationDispatched)
        #expect(!projection.retrySafe)
        #expect(projection.requiresFreshObservation)
    }

    private func mutatedJSON(
        _ projection: DesktopActionOutcome.Projection,
        mutation: (inout [String: Any]) -> Void) throws -> Data
    {
        let data = try JSONEncoder().encode(projection)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        mutation(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func dispatchStateName(_ state: DesktopActionOutcome.DispatchState) -> String {
        switch state {
        case .none: "none"
        case .dispatched: "dispatched"
        case .mayHaveDispatched: "may_have_dispatched"
        }
    }

    private static let allProjectionStates: [DesktopActionOutcome.State] = [
        .confirmedChange,
        .confirmedNoChange,
        .partial,
        .dispatchedUnverified,
        .suspectedNoop,
        .refused,
        .indeterminate,
    ]
}
