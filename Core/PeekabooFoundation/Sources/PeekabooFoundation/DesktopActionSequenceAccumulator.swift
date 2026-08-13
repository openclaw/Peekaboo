/// What a composite desktop action knows about mutation dispatch independent of its semantic outcome.
///
/// This deliberately distinguishes a definite dispatch from a possible dispatch. The compatibility
/// `mutation_dispatched` boolean collapses both to `true`, but composition must retain the distinction
/// so cancellation and response-loss paths cannot become retry-safe by accident.
public enum DesktopActionMutationDisposition: Equatable, Sendable {
    case none
    case definite(unitCount: DesktopActionOutcome.DispatchUnitCount?)
    case possible(unitCount: DesktopActionOutcome.DispatchUnitCount?)

    public init(dispatchState: DesktopActionOutcome.DispatchState) {
        switch dispatchState {
        case .none:
            self = .none
        case let .dispatched(unitCount):
            self = .definite(unitCount: unitCount)
        case let .mayHaveDispatched(unitCount):
            self = .possible(unitCount: unitCount)
        }
    }

    public var mutationDispatched: Bool {
        self != .none
    }

    public var unitCount: DesktopActionOutcome.DispatchUnitCount? {
        switch self {
        case .none:
            nil
        case let .definite(unitCount), let .possible(unitCount):
            unitCount
        }
    }
}

/// Canonical, presentation-neutral composition of setup, leaf-delivery, and cleanup action phases.
///
/// Callers must state receiptless dispatch explicitly. A missing outcome is never silently interpreted:
/// a successfully returned legacy action is `.dispatched`, while an interrupted or otherwise uncertain
/// phase is `.mayHaveDispatched`.
public struct DesktopActionSequenceAccumulator: Sendable {
    public enum Step: Sendable {
        case outcome(DesktopActionOutcome)
        case reportedOutcome(
            DesktopActionOutcome,
            defaultDispatchedUnitCount: DesktopActionOutcome.DispatchUnitCount)
        case dispatched(
            route: DesktopActionOutcome.Route?,
            delivery: DesktopActionOutcome.Delivery?,
            unitCount: DesktopActionOutcome.DispatchUnitCount?)
        case mayHaveDispatched(
            route: DesktopActionOutcome.Route?,
            delivery: DesktopActionOutcome.Delivery?,
            unitCount: DesktopActionOutcome.DispatchUnitCount?)
    }

    public struct Resolution: Sendable {
        public let outcome: DesktopActionOutcome?
        public let mutationDisposition: DesktopActionMutationDisposition

        public var mutationDispatched: Bool {
            self.mutationDisposition.mutationDispatched
        }

        public var retrySafety: DesktopActionOutcome.RetrySafety {
            self.outcome?.retrySafety ?? (self.mutationDisposition == .none ? .safe : .unsafe)
        }

        public var retrySafe: Bool {
            self.retrySafety == .safe
        }

        public var requiresFreshObservation: Bool {
            self.outcome?.projection.requiresFreshObservation ?? self.mutationDisposition.mutationDispatched
        }
    }

    public private(set) var completedStepCount = 0
    public private(set) var mutationDisposition: DesktopActionMutationDisposition = .none
    private var allStepsReported = true
    private var allReportedOutcomesAreConfirmedNoChange = true

    private var allReportedOutcomesAreConfirmed = true
    private var singleReportedOutcome: DesktopActionOutcome?
    private var dispatchedRoute = HomogeneousValue<DesktopActionOutcome.Route>()
    private var dispatchedDelivery = HomogeneousValue<DesktopActionOutcome.Delivery>()
    private var noDispatchRoute = HomogeneousValue<DesktopActionOutcome.Route>()

    public init() {}

    public mutating func record(_ step: Step) {
        self.completedStepCount += 1
        switch step {
        case let .outcome(outcome):
            self.recordReportedOutcome(outcome)
        case let .reportedOutcome(outcome, defaultUnitCount):
            self.recordReportedOutcome(outcome, defaultDispatchedUnitCount: defaultUnitCount)
        case let .dispatched(route, delivery, unitCount):
            self.recordReceiptlessMutation(
                disposition: .definite(unitCount: unitCount),
                route: route,
                delivery: delivery)
        case let .mayHaveDispatched(route, delivery, unitCount):
            self.recordReceiptlessMutation(
                disposition: .possible(unitCount: unitCount),
                route: route,
                delivery: delivery)
        }
    }

    /// Resolves a successfully completed sequence without inventing route or delivery fields.
    ///
    /// Mixed or receiptless phases can leave `outcome` nil. The returned mutation disposition still
    /// supplies the authoritative retry/fresh-observation compatibility semantics.
    public func successResolution() -> Resolution {
        if self.completedStepCount == 1,
           let outcome = self.singleReportedOutcome,
           outcome.isConfirmed
        {
            return Resolution(
                outcome: outcome,
                mutationDisposition: self.mutationDisposition)
        }
        let outcome: DesktopActionOutcome? = switch self.mutationDisposition {
        case .none:
            if self.completedStepCount > 0,
               self.allStepsReported,
               self.allReportedOutcomesAreConfirmedNoChange,
               let route = self.noDispatchRoute.value
            {
                .confirmedNoChange(route: route)
            } else {
                nil
            }
        case let .definite(unitCount):
            if self.allStepsReported,
               self.allReportedOutcomesAreConfirmed,
               let route = self.dispatchedRoute.value,
               let delivery = self.dispatchedDelivery.value
            {
                .confirmedChange(route: route, delivery: delivery, unitCount: unitCount)
            } else if let route = self.dispatchedRoute.value,
                      let delivery = self.dispatchedDelivery.value
            {
                .dispatchedUnverified(
                    route: route,
                    delivery: delivery,
                    evidence: .deliveryAccepted,
                    unitCount: unitCount)
            } else {
                nil
            }
        case let .possible(unitCount):
            if let route = self.dispatchedRoute.value {
                .indeterminate(
                    route: route,
                    delivery: self.dispatchedDelivery.value,
                    evidence: .completionUnknown,
                    unitCount: unitCount)
            } else {
                nil
            }
        }
        return Resolution(
            outcome: outcome,
            mutationDisposition: self.mutationDisposition)
    }

    /// Composes a failed leaf with every phase that completed before it.
    ///
    /// A leaf refusal/no-change receipt survives only while the prefix proves no mutation. Once the
    /// prefix dispatched or may have dispatched, the composite becomes partial (only for one fully
    /// homogeneous partial route) or indeterminate and retry-unsafe.
    public func failure(
        combining leafFailure: DesktopActionFailure,
        message: String,
        hint: String? = nil,
        causeDescription: String? = nil) -> DesktopActionFailure
    {
        guard self.mutationDisposition == .none else {
            var aggregate = self
            aggregate.record(.outcome(leafFailure.outcome))
            let route = aggregate.dispatchedRoute.value ?? leafFailure.outcome.route
            let unitCount = aggregate.mutationDisposition.unitCount

            if leafFailure.outcome.state == .partial,
               case .definite = aggregate.mutationDisposition,
               aggregate.dispatchedRoute.value != nil,
               let delivery = aggregate.dispatchedDelivery.value
            {
                return .partial(
                    route: route,
                    delivery: delivery,
                    unitCount: unitCount,
                    message: message,
                    hint: hint ?? leafFailure.hint,
                    causeDescription: causeDescription ?? leafFailure.causeDescription)
            }

            let evidence: DesktopActionOutcome.IndeterminateEvidence =
                leafFailure.outcome.evidence == .responseLost ? .responseLost : .completionUnknown
            return .indeterminate(
                route: route,
                delivery: aggregate.dispatchedRoute.value == nil ? nil : aggregate.dispatchedDelivery.value,
                evidence: evidence,
                unitCount: unitCount,
                message: message,
                hint: hint ?? leafFailure.hint,
                causeDescription: causeDescription ?? leafFailure.localizedDescription)
        }
        return leafFailure
    }

    /// Returns a canonical cancellation failure only after mutation became possible.
    /// Pre-dispatch cancellation remains ordinary cancellation and returns nil.
    public func cancellationFailure(
        fallbackRoute: DesktopActionOutcome.Route,
        message: String,
        hint: String,
        causeDescription: String) -> DesktopActionFailure?
    {
        guard self.mutationDisposition.mutationDispatched else { return nil }
        return .indeterminate(
            route: self.dispatchedRoute.value ?? fallbackRoute,
            delivery: self.dispatchedRoute.value == nil ? nil : self.dispatchedDelivery.value,
            evidence: .completionUnknown,
            unitCount: self.mutationDisposition.unitCount,
            message: message,
            hint: hint,
            causeDescription: causeDescription)
    }

    private mutating func recordReportedOutcome(
        _ outcome: DesktopActionOutcome,
        defaultDispatchedUnitCount: DesktopActionOutcome.DispatchUnitCount? = nil)
    {
        if self.completedStepCount == 1 {
            self.singleReportedOutcome = outcome
        } else {
            self.singleReportedOutcome = nil
        }
        self.allReportedOutcomesAreConfirmed = self.allReportedOutcomesAreConfirmed && outcome.isConfirmed
        self.allReportedOutcomesAreConfirmedNoChange = self.allReportedOutcomesAreConfirmedNoChange &&
            outcome.state == .confirmedNoChange
        let disposition: DesktopActionMutationDisposition = switch outcome.dispatchState {
        case .none:
            .none
        case let .dispatched(unitCount):
            .definite(unitCount: unitCount ?? defaultDispatchedUnitCount)
        case let .mayHaveDispatched(unitCount):
            .possible(unitCount: unitCount)
        }
        if disposition == .none {
            self.noDispatchRoute.record(outcome.route)
        } else {
            self.dispatchedRoute.record(outcome.route)
            self.dispatchedDelivery.record(outcome.delivery)
        }
        self.mutationDisposition = Self.combined(self.mutationDisposition, disposition)
    }

    private mutating func recordReceiptlessMutation(
        disposition: DesktopActionMutationDisposition,
        route: DesktopActionOutcome.Route?,
        delivery: DesktopActionOutcome.Delivery?)
    {
        self.singleReportedOutcome = nil
        self.allStepsReported = false
        self.allReportedOutcomesAreConfirmed = false
        self.allReportedOutcomesAreConfirmedNoChange = false
        self.dispatchedRoute.record(route)
        self.dispatchedDelivery.record(delivery)
        self.mutationDisposition = Self.combined(self.mutationDisposition, disposition)
    }

    private static func combined(
        _ lhs: DesktopActionMutationDisposition,
        _ rhs: DesktopActionMutationDisposition) -> DesktopActionMutationDisposition
    {
        let unitCount = Self.combinedUnitCount(lhs, rhs)
        switch (lhs, rhs) {
        case (.none, .none):
            return .none
        case (.possible, _), (_, .possible):
            return .possible(unitCount: unitCount)
        case (.definite, _), (_, .definite):
            return .definite(unitCount: unitCount)
        }
    }

    private static func combinedUnitCount(
        _ lhs: DesktopActionMutationDisposition,
        _ rhs: DesktopActionMutationDisposition) -> DesktopActionOutcome.DispatchUnitCount?
    {
        switch (lhs, rhs) {
        case (.none, .none):
            return nil
        case let (.none, value), let (value, .none):
            return value.unitCount
        default:
            guard let lhsCount = lhs.unitCount?.rawValue,
                  let rhsCount = rhs.unitCount?.rawValue
            else { return nil }
            return DesktopActionOutcome.DispatchUnitCount(lhsCount + rhsCount)
        }
    }
}

private struct HomogeneousValue<Value: Equatable & Sendable>: Sendable {
    private(set) var value: Value?
    private var isAvailable = true

    mutating func record(_ value: Value?) {
        guard self.isAvailable else { return }
        guard let value else {
            self.value = nil
            self.isAvailable = false
            return
        }
        if let existing = self.value, existing != value {
            self.value = nil
            self.isAvailable = false
        } else {
            self.value = value
        }
    }
}
