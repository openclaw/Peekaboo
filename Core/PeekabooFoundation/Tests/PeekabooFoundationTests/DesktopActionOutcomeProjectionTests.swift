import Foundation
import PeekabooFoundation
import Testing

struct DesktopActionOutcomeProjectionTests {
    private let backgroundAX = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .background)

    @Test
    func `projection exposes the exhaustive seven-state table`() throws {
        let oneUnit = try self.positiveUnitCount(1)
        let twoUnits = try self.positiveUnitCount(2)
        let threeUnits = try self.positiveUnitCount(3)
        let cases = [
            ProjectionCase(
                outcome: .confirmedChange(delivery: self.backgroundAX, unitCount: oneUnit),
                state: .confirmedChange,
                effect: .confirmed,
                route: .local,
                delivery: self.backgroundAX,
                evidence: .verifiedChange,
                dispatchState: .dispatched(unitCount: oneUnit),
                unitCount: oneUnit,
                retrySafety: .notApplicable,
                escalation: .none,
                refusalReason: nil,
                mutationDispatched: true,
                retrySafe: false,
                requiresFreshObservation: false),
            ProjectionCase(
                outcome: .confirmedNoChange(route: .bridge),
                state: .confirmedNoChange,
                effect: .confirmed,
                route: .bridge,
                delivery: nil,
                evidence: .verifiedNoChange,
                dispatchState: .none,
                unitCount: nil,
                retrySafety: .notApplicable,
                escalation: .none,
                refusalReason: nil,
                mutationDispatched: false,
                retrySafe: false,
                requiresFreshObservation: false),
            ProjectionCase(
                outcome: .partial(route: .bridge, delivery: self.backgroundAX, unitCount: twoUnits),
                state: .partial,
                effect: .partial,
                route: .bridge,
                delivery: self.backgroundAX,
                evidence: .primaryChangeVerifiedCleanupFailed,
                dispatchState: .dispatched(unitCount: twoUnits),
                unitCount: twoUnits,
                retrySafety: .unsafe,
                escalation: .recoverSideEffect,
                refusalReason: nil,
                mutationDispatched: true,
                retrySafe: false,
                requiresFreshObservation: false),
            ProjectionCase(
                outcome: .dispatchedUnverified(
                    delivery: self.backgroundAX,
                    evidence: .operationStillRunning,
                    unitCount: threeUnits),
                state: .dispatchedUnverified,
                effect: .unverifiable,
                route: .local,
                delivery: self.backgroundAX,
                evidence: .operationStillRunning,
                dispatchState: .dispatched(unitCount: threeUnits),
                unitCount: threeUnits,
                retrySafety: .unsafe,
                escalation: .observeBeforeRetry,
                refusalReason: nil,
                mutationDispatched: true,
                retrySafe: false,
                requiresFreshObservation: true),
            ProjectionCase(
                outcome: .suspectedNoop(delivery: self.backgroundAX),
                state: .suspectedNoop,
                effect: .suspectedNoop,
                route: .local,
                delivery: self.backgroundAX,
                evidence: .observedNoChange,
                dispatchState: .dispatched(unitCount: nil),
                unitCount: nil,
                retrySafety: .safe,
                escalation: .refreshTarget,
                refusalReason: nil,
                mutationDispatched: true,
                retrySafe: true,
                requiresFreshObservation: false),
            ProjectionCase(
                outcome: .refused(route: .bridge, reason: .permissionDenied),
                state: .refused,
                effect: .refused,
                route: .bridge,
                delivery: nil,
                evidence: .requestRefused,
                dispatchState: .none,
                unitCount: nil,
                retrySafety: .safe,
                escalation: .grantPermission,
                refusalReason: .permissionDenied,
                mutationDispatched: false,
                retrySafe: true,
                requiresFreshObservation: false),
            ProjectionCase(
                outcome: .indeterminate(
                    route: .bridge,
                    evidence: .responseLost,
                    unitCount: threeUnits),
                state: .indeterminate,
                effect: .unverifiable,
                route: .bridge,
                delivery: nil,
                evidence: .responseLost,
                dispatchState: .mayHaveDispatched(unitCount: threeUnits),
                unitCount: threeUnits,
                retrySafety: .unsafe,
                escalation: .observeBeforeRetry,
                refusalReason: nil,
                mutationDispatched: true,
                retrySafe: false,
                requiresFreshObservation: true),
        ]

        #expect(cases.map(\.state) == DesktopActionOutcome.State.allProjectionStates)
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
        for outcome in try self.allOutcomes() {
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
        for outcome in try self.allOutcomes() {
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

    private func allOutcomes() throws -> [DesktopActionOutcome] {
        let oneUnit = try self.positiveUnitCount(1)
        return [
            .confirmedChange(delivery: self.backgroundAX, unitCount: oneUnit),
            .confirmedNoChange(route: .bridge),
            .partial(delivery: self.backgroundAX),
            .dispatchedUnverified(delivery: self.backgroundAX, evidence: .deliveryAccepted),
            .suspectedNoop(delivery: self.backgroundAX),
            .refused(route: .bridge, reason: .runtimeIncompatible),
            .indeterminate(route: .bridge, evidence: .completionUnknown, unitCount: oneUnit),
        ]
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

    private func positiveUnitCount(_ value: Int) throws -> DesktopActionOutcome.DispatchUnitCount {
        try #require(DesktopActionOutcome.DispatchUnitCount(value))
    }

    private static func dispatchStateName(_ state: DesktopActionOutcome.DispatchState) -> String {
        switch state {
        case .none: "none"
        case .dispatched: "dispatched"
        case .mayHaveDispatched: "may_have_dispatched"
        }
    }

    private struct ProjectionCase {
        let outcome: DesktopActionOutcome
        let state: DesktopActionOutcome.State
        let effect: DesktopActionOutcome.Effect
        let route: DesktopActionOutcome.Route
        let delivery: DesktopActionOutcome.Delivery?
        let evidence: DesktopActionOutcome.Evidence
        let dispatchState: DesktopActionOutcome.DispatchState
        let unitCount: DesktopActionOutcome.DispatchUnitCount?
        let retrySafety: DesktopActionOutcome.RetrySafety
        let escalation: DesktopActionOutcome.Escalation
        let refusalReason: DesktopActionOutcome.RefusalReason?
        let mutationDispatched: Bool
        let retrySafe: Bool
        let requiresFreshObservation: Bool
    }
}

extension DesktopActionOutcome.State {
    fileprivate static let allProjectionStates: [Self] = [
        .confirmedChange,
        .confirmedNoChange,
        .partial,
        .dispatchedUnverified,
        .suspectedNoop,
        .refused,
        .indeterminate,
    ]
}
