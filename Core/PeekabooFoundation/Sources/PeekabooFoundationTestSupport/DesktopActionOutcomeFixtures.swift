import PeekabooFoundation

/// One independently specified case in the closed desktop-action outcome matrix.
///
/// Expected fields are stored separately from ``DesktopActionOutcome/Projection`` so tests can
/// detect a bad derivation instead of generating their oracle through the code under test.
public struct CanonicalDesktopActionOutcomeCase: Equatable, Sendable {
    public let outcome: DesktopActionOutcome
    public let state: DesktopActionOutcome.State
    public let effect: DesktopActionOutcome.Effect
    public let route: DesktopActionOutcome.Route
    public let delivery: DesktopActionOutcome.Delivery?
    public let evidence: DesktopActionOutcome.Evidence
    public let dispatchState: DesktopActionOutcome.DispatchState
    public let unitCount: DesktopActionOutcome.DispatchUnitCount?
    public let retrySafety: DesktopActionOutcome.RetrySafety
    public let escalation: DesktopActionOutcome.Escalation
    public let refusalReason: DesktopActionOutcome.RefusalReason?
    public let mutationDispatched: Bool
    public let retrySafe: Bool
    public let requiresFreshObservation: Bool
    public let failure: DesktopActionFailure?

    public var isFailureEligible: Bool {
        self.failure != nil
    }
}

public enum DesktopActionOutcomeFixtures {
    public static let backgroundAccessibilityDelivery = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .background)

    public static let canonicalCases: [CanonicalDesktopActionOutcomeCase] = {
        let oneUnit = Self.unitCount(1)
        let twoUnits = Self.unitCount(2)
        let threeUnits = Self.unitCount(3)
        let backgroundAX = Self.backgroundAccessibilityDelivery

        let confirmedChange = DesktopActionOutcome.confirmedChange(
            delivery: backgroundAX,
            unitCount: oneUnit)
        let confirmedNoChange = DesktopActionOutcome.confirmedNoChange(route: .bridge)
        let partial = DesktopActionOutcome.partial(
            route: .bridge,
            delivery: backgroundAX,
            unitCount: twoUnits)
        let dispatchedUnverified = DesktopActionOutcome.dispatchedUnverified(
            delivery: backgroundAX,
            evidence: .operationStillRunning,
            unitCount: threeUnits)
        let suspectedNoop = DesktopActionOutcome.suspectedNoop(delivery: backgroundAX)
        let refused = DesktopActionOutcome.refused(route: .bridge, reason: .permissionDenied)
        let indeterminate = DesktopActionOutcome.indeterminate(
            route: .bridge,
            evidence: .responseLost,
            unitCount: threeUnits)

        return [
            CanonicalDesktopActionOutcomeCase(
                outcome: confirmedChange,
                state: .confirmedChange,
                effect: .confirmed,
                route: .local,
                delivery: backgroundAX,
                evidence: .verifiedChange,
                dispatchState: .dispatched(unitCount: oneUnit),
                unitCount: oneUnit,
                retrySafety: .notApplicable,
                escalation: .none,
                refusalReason: nil,
                mutationDispatched: true,
                retrySafe: false,
                requiresFreshObservation: false,
                failure: nil),
            CanonicalDesktopActionOutcomeCase(
                outcome: confirmedNoChange,
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
                requiresFreshObservation: false,
                failure: nil),
            CanonicalDesktopActionOutcomeCase(
                outcome: partial,
                state: .partial,
                effect: .partial,
                route: .bridge,
                delivery: backgroundAX,
                evidence: .primaryChangeVerifiedCleanupFailed,
                dispatchState: .dispatched(unitCount: twoUnits),
                unitCount: twoUnits,
                retrySafety: .unsafe,
                escalation: .recoverSideEffect,
                refusalReason: nil,
                mutationDispatched: true,
                retrySafe: false,
                requiresFreshObservation: false,
                failure: DesktopActionFailure(
                    outcome: partial,
                    message: "Action completed partially",
                    hint: "Recover the side effect before retrying")),
            CanonicalDesktopActionOutcomeCase(
                outcome: dispatchedUnverified,
                state: .dispatchedUnverified,
                effect: .unverifiable,
                route: .local,
                delivery: backgroundAX,
                evidence: .operationStillRunning,
                dispatchState: .dispatched(unitCount: threeUnits),
                unitCount: threeUnits,
                retrySafety: .unsafe,
                escalation: .observeBeforeRetry,
                refusalReason: nil,
                mutationDispatched: true,
                retrySafe: false,
                requiresFreshObservation: true,
                failure: DesktopActionFailure(
                    outcome: dispatchedUnverified,
                    message: "Action dispatch could not be verified",
                    hint: "Observe the target before retrying")),
            CanonicalDesktopActionOutcomeCase(
                outcome: suspectedNoop,
                state: .suspectedNoop,
                effect: .suspectedNoop,
                route: .local,
                delivery: backgroundAX,
                evidence: .observedNoChange,
                dispatchState: .dispatched(unitCount: nil),
                unitCount: nil,
                retrySafety: .safe,
                escalation: .refreshTarget,
                refusalReason: nil,
                mutationDispatched: true,
                retrySafe: true,
                requiresFreshObservation: false,
                failure: DesktopActionFailure(
                    outcome: suspectedNoop,
                    message: "Action may have produced no change",
                    hint: "Refresh the target before retrying")),
            CanonicalDesktopActionOutcomeCase(
                outcome: refused,
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
                requiresFreshObservation: false,
                failure: DesktopActionFailure(
                    outcome: refused,
                    message: "Action request was refused",
                    hint: "Grant permission before retrying")),
            CanonicalDesktopActionOutcomeCase(
                outcome: indeterminate,
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
                requiresFreshObservation: true,
                failure: DesktopActionFailure(
                    outcome: indeterminate,
                    message: "Action outcome is indeterminate",
                    hint: "Observe the target before retrying",
                    causeDescription: "The response channel closed")),
        ]
    }()

    public static var canonicalOutcomes: [DesktopActionOutcome] {
        self.canonicalCases.map(\.outcome)
    }

    private static func unitCount(_ value: Int) -> DesktopActionOutcome.DispatchUnitCount {
        guard let count = DesktopActionOutcome.DispatchUnitCount(value) else {
            preconditionFailure("Canonical fixture unit counts must be positive")
        }
        return count
    }
}
