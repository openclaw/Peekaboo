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
    public struct InterruptedBatchResult: Sendable {
        public let outcome: DesktopActionOutcome?
        public let effect: DesktopActionOutcome.Effect

        fileprivate init(
            outcome: DesktopActionOutcome?,
            fallbackEffect: DesktopActionOutcome.Effect)
        {
            self.outcome = outcome
            self.effect = outcome?.effect ?? fallbackEffect
        }
    }

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
    private var allReportedOutcomesAreSuspectedNoop = true
    private var hasReportedResponseLoss = false
    private var singleReportedOutcome: DesktopActionOutcome?
    private var dispatchedRoute = HomogeneousValue<DesktopActionOutcome.Route>()
    private var dispatchedDelivery = CompatibleDeliveryValue()
    private var noDispatchRoute = HomogeneousValue<DesktopActionOutcome.Route>()

    public init() {}

    /// Resolves a batch whose caller separately tracks which payloads succeeded.
    ///
    /// Callers provide exactly one optional receipt per attempt. A batch with no reported receipts
    /// preserves legacy omission so callers can retain their payload-based compatibility semantics.
    /// Once any receipt is present, each missing receipt is treated as a possible one-unit dispatch,
    /// never as proof that nothing happened. A one-item batch preserves its exact reported receipt.
    /// Multi-item partial completion is representable only when every receipt is present and every
    /// dispatched item is definite with one route and delivery mechanism. An unrepresentable mix of
    /// complete, more-specific receipts omits the aggregate rather than inventing weaker evidence.
    public static func completedBatch(
        outcomes: [DesktopActionOutcome?],
        succeededCount: Int,
        attemptedCount: Int,
        fallbackRoute: DesktopActionOutcome.Route = .local) -> DesktopActionOutcome?
    {
        guard attemptedCount >= 0,
              (0...attemptedCount).contains(succeededCount),
              outcomes.count == attemptedCount
        else { return nil }
        if outcomes.count == 1, let outcome = outcomes[0] {
            return outcome
        }

        let reportedOutcomes = outcomes.compactMap(\.self)
        guard !reportedOutcomes.isEmpty else { return nil }
        if succeededCount == 0,
           reportedOutcomes.count == attemptedCount,
           let first = reportedOutcomes.first,
           first.state == .refused,
           let refusalReason = first.refusalReason,
           reportedOutcomes.allSatisfy({
               $0.state == .refused &&
                   $0.route == first.route &&
                   $0.refusalReason == refusalReason
           })
        {
            return .refused(route: first.route, reason: refusalReason)
        }

        var sequence = Self()
        for outcome in outcomes {
            if let outcome {
                sequence.record(.reportedOutcome(outcome, defaultDispatchedUnitCount: .one))
            } else {
                sequence.record(.mayHaveDispatched(route: nil, delivery: nil, unitCount: .one))
            }
        }
        let resolution = sequence.successResolution()
        // Complete leaf receipts remain authoritative; composition must not replace their known
        // states with an unverified aggregate that none of the leaves reported.
        let aggregateOutcome: DesktopActionOutcome? = if resolution.outcome?.state == .dispatchedUnverified,
                                                         reportedOutcomes.allSatisfy({
                                                             $0.state != .dispatchedUnverified
                                                         })
        {
            nil
        } else {
            resolution.outcome
        }
        let hasMissingReceipt = reportedOutcomes.count != outcomes.count
        if hasMissingReceipt {
            guard attemptedCount > 0 else { return nil }
            let responseLost = reportedOutcomes.first { $0.evidence == .responseLost }
            let indeterminate = responseLost ?? reportedOutcomes.first { $0.state == .indeterminate }
            let homogeneousRoute = reportedOutcomes.first.map(\.route).flatMap { route in
                reportedOutcomes.allSatisfy { $0.route == route } ? route : nil
            }
            return .indeterminate(
                route: indeterminate?.route ?? homogeneousRoute ?? fallbackRoute,
                delivery: indeterminate?.delivery,
                evidence: responseLost == nil ? .completionUnknown : .responseLost,
                unitCount: resolution.mutationDisposition.unitCount)
        }
        let hasReportedPartial = reportedOutcomes.contains { $0.state == .partial }
        guard hasReportedPartial || (succeededCount > 0 && succeededCount < attemptedCount) else {
            return aggregateOutcome
        }
        let hasStrongerUncertainty = reportedOutcomes.contains {
            $0.state == .dispatchedUnverified || $0.state == .indeterminate
        }
        guard !hasStrongerUncertainty else { return aggregateOutcome }

        let dispatched = reportedOutcomes.filter(\.dispatchState.mutationDispatched)
        guard !dispatched.isEmpty,
              let route = sequence.dispatchedRoute.value,
              let delivery = sequence.dispatchedDelivery.value,
              dispatched.allSatisfy({
                  if case .dispatched = $0.dispatchState {
                      true
                  } else {
                      false
                  }
              })
        else {
            return aggregateOutcome
        }
        return .partial(
            route: route,
            delivery: delivery,
            unitCount: resolution.mutationDisposition.unitCount)
    }

    /// Convenience for batches where every attempt returned a canonical receipt.
    public static func completedBatch(
        outcomes: [DesktopActionOutcome],
        succeededCount: Int,
        attemptedCount: Int) -> DesktopActionOutcome?
    {
        self.completedBatch(
            outcomes: outcomes.map(Optional.some),
            succeededCount: succeededCount,
            attemptedCount: attemptedCount)
    }

    /// Resolves the completed prefix of a batch that stopped before every planned target finished.
    ///
    /// A complete prefix cannot remain a confirmed outcome for the whole batch. Definite, homogeneous
    /// delivery becomes partial; stronger uncertainty remains authoritative. If cancellation interrupted
    /// an in-flight attempt, that attempt may have dispatched and the aggregate becomes indeterminate.
    /// Receiptless prefixes continue to omit the additive outcome only when cancellation happened
    /// between targets; an in-flight interruption must retain possible-dispatch uncertainty.
    public static func interruptedBatch(
        completedOutcomes outcomes: [DesktopActionOutcome?],
        succeededCount: Int,
        attemptedCount: Int,
        plannedCount: Int,
        inFlightAttemptMayHaveDispatched: Bool,
        fallbackRoute: DesktopActionOutcome.Route = .local) -> InterruptedBatchResult?
    {
        guard plannedCount > attemptedCount,
              attemptedCount >= 0,
              (0...attemptedCount).contains(succeededCount),
              outcomes.count == attemptedCount
        else { return nil }

        let completedOutcome = self.completedBatch(
            outcomes: outcomes,
            succeededCount: succeededCount,
            attemptedCount: attemptedCount,
            fallbackRoute: fallbackRoute)

        if inFlightAttemptMayHaveDispatched {
            var sequence = Self()
            for outcome in outcomes {
                if let outcome {
                    sequence.record(.reportedOutcome(outcome, defaultDispatchedUnitCount: .one))
                } else {
                    sequence.record(.mayHaveDispatched(route: nil, delivery: nil, unitCount: .one))
                }
            }
            sequence.record(.mayHaveDispatched(route: nil, delivery: nil, unitCount: .one))
            return InterruptedBatchResult(
                outcome: .indeterminate(
                    route: completedOutcome?.route ?? fallbackRoute,
                    delivery: nil,
                    evidence: .completionUnknown,
                    unitCount: sequence.mutationDisposition.unitCount),
                fallbackEffect: .unverifiable)
        }

        guard let completedOutcome else {
            let reportedOutcomes = outcomes.compactMap(\.self)
            let allReportedOutcomesAvoidedDispatch = reportedOutcomes.count == attemptedCount &&
                !reportedOutcomes.isEmpty &&
                reportedOutcomes.allSatisfy { !$0.dispatchState.mutationDispatched }
            let fallbackEffect: DesktopActionOutcome.Effect = if allReportedOutcomesAvoidedDispatch {
                reportedOutcomes.contains(where: { $0.state == .refused }) ? .refused : .suspectedNoop
            } else if reportedOutcomes.contains(where: {
                $0.state == .dispatchedUnverified || $0.state == .indeterminate
            }) {
                .unverifiable
            } else if reportedOutcomes.contains(where: \.dispatchState.mutationDispatched) ||
                attemptedCount > 0
            {
                .partial
            } else {
                .suspectedNoop
            }
            return InterruptedBatchResult(outcome: nil, fallbackEffect: fallbackEffect)
        }
        switch completedOutcome.state {
        case .confirmedChange, .suspectedNoop:
            guard let delivery = completedOutcome.delivery else { return nil }
            return InterruptedBatchResult(
                outcome: .partial(
                    route: completedOutcome.route,
                    delivery: delivery,
                    unitCount: completedOutcome.dispatchState.unitCount),
                fallbackEffect: .partial)
        case .confirmedNoChange:
            return InterruptedBatchResult(outcome: nil, fallbackEffect: .suspectedNoop)
        case .refused:
            return InterruptedBatchResult(outcome: completedOutcome, fallbackEffect: .refused)
        case .partial, .dispatchedUnverified, .indeterminate:
            return InterruptedBatchResult(outcome: completedOutcome, fallbackEffect: completedOutcome.effect)
        }
    }

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
            } else if self.allStepsReported,
                      self.allReportedOutcomesAreSuspectedNoop,
                      let route = self.dispatchedRoute.value,
                      let delivery = self.dispatchedDelivery.value
            {
                .suspectedNoop(route: route, delivery: delivery, unitCount: unitCount)
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
                    evidence: self.hasReportedResponseLoss ? .responseLost : .completionUnknown,
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
                return DesktopActionFailure.partial(
                    route: route,
                    delivery: delivery,
                    unitCount: unitCount,
                    message: message,
                    hint: hint ?? leafFailure.hint,
                    causeDescription: causeDescription ?? leafFailure.causeDescription)
                    .selectingLeaves(leafFailure.selectedLeafEvidence)
            }

            let evidence: DesktopActionOutcome.IndeterminateEvidence =
                leafFailure.outcome.evidence == .responseLost ? .responseLost : .completionUnknown
            return DesktopActionFailure.indeterminate(
                route: route,
                delivery: aggregate.dispatchedRoute.value == nil ? nil : aggregate.dispatchedDelivery.value,
                evidence: evidence,
                unitCount: unitCount,
                message: message,
                hint: hint ?? leafFailure.hint,
                causeDescription: causeDescription ?? leafFailure.causeDescription)
                .selectingLeaves(leafFailure.selectedLeafEvidence)
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
        self.allReportedOutcomesAreSuspectedNoop = self.allReportedOutcomesAreSuspectedNoop &&
            outcome.state == .suspectedNoop
        self.hasReportedResponseLoss = self.hasReportedResponseLoss || outcome.evidence == .responseLost
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
        self.allReportedOutcomesAreSuspectedNoop = false
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
            let (sum, overflow) = lhsCount.addingReportingOverflow(rhsCount)
            guard !overflow else { return nil }
            return DesktopActionOutcome.DispatchUnitCount(sum)
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

/// Combines delivery mechanisms while retaining the most disruptive mode they used.
///
/// A known sequence that crosses mechanisms remains exactly representable as `composite`.
/// Missing delivery evidence still makes the aggregate unavailable rather than inventing a route.
private struct CompatibleDeliveryValue: Sendable {
    private(set) var value: DesktopActionOutcome.Delivery?
    private var isAvailable = true

    mutating func record(_ value: DesktopActionOutcome.Delivery?) {
        guard self.isAvailable else { return }
        guard let value else {
            self.value = nil
            self.isAvailable = false
            return
        }
        guard let existing = self.value else {
            self.value = value
            return
        }
        let mechanism: DesktopActionOutcome.Delivery.Mechanism =
            existing.mechanism == value.mechanism ? existing.mechanism : .composite
        self.value = DesktopActionOutcome.Delivery(
            mechanism: mechanism,
            mode: existing.mode == .foreground || value.mode == .foreground ? .foreground : .background)
    }
}
