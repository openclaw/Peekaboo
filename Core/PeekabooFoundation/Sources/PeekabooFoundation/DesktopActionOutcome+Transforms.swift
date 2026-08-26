import Foundation

extension DesktopActionOutcome {
    /// Promotes an accepted but unverified dispatch after a caller completes an exact readback.
    /// All other states and an unavailable readback remain byte-for-byte unchanged.
    public func confirmingDispatchedOutcome(observedChange: Bool?) -> Self {
        guard self.state == .dispatchedUnverified,
              let observedChange,
              let delivery = self.delivery
        else {
            return self
        }
        if observedChange {
            return .confirmedChange(
                route: self.route,
                delivery: delivery,
                unitCount: self.dispatchState.unitCount)
        }
        return .confirmedNoChange(route: self.route)
    }

    /// Reprojects one validated outcome through a different concrete delivery route without
    /// changing its state, route, dispatch count, or evidence meaning.
    public func reprojectingDelivery(_ delivery: Delivery) -> Self {
        switch self.state {
        case .confirmedChange:
            return .confirmedChange(
                route: self.route,
                delivery: delivery,
                unitCount: self.dispatchState.unitCount)
        case .confirmedNoChange, .refused:
            return self
        case .partial:
            return .partial(
                route: self.route,
                delivery: delivery,
                unitCount: self.dispatchState.unitCount)
        case .dispatchedUnverified:
            guard let evidence = DispatchedUnverifiedEvidence(rawValue: self.evidence.rawValue) else {
                return self
            }
            return .dispatchedUnverified(
                route: self.route,
                delivery: delivery,
                evidence: evidence,
                unitCount: self.dispatchState.unitCount)
        case .suspectedNoop:
            return .suspectedNoop(
                route: self.route,
                delivery: delivery,
                unitCount: self.dispatchState.unitCount)
        case .indeterminate:
            guard self.delivery != nil else { return self }
            guard let evidence = IndeterminateEvidence(rawValue: self.evidence.rawValue) else {
                return self
            }
            return .indeterminate(
                route: self.route,
                delivery: delivery,
                evidence: evidence,
                unitCount: self.dispatchState.unitCount)
        }
    }

    /// Fills a missing unit count only for states that can represent a successful accepted
    /// dispatch at compatibility boundaries. Existing counts and every other state are unchanged.
    public func fillingSuccessfulDispatchUnitCount(_ unitCount: DispatchUnitCount) -> Self {
        guard self.dispatchState.unitCount == nil,
              let delivery = self.delivery
        else {
            return self
        }
        switch self.state {
        case .confirmedChange:
            return .confirmedChange(route: self.route, delivery: delivery, unitCount: unitCount)
        case .dispatchedUnverified:
            guard let evidence = DispatchedUnverifiedEvidence(rawValue: self.evidence.rawValue) else {
                return self
            }
            return .dispatchedUnverified(
                route: self.route,
                delivery: delivery,
                evidence: evidence,
                unitCount: unitCount)
        case .suspectedNoop:
            return .suspectedNoop(route: self.route, delivery: delivery, unitCount: unitCount)
        case .confirmedNoChange, .partial, .refused, .indeterminate:
            return self
        }
    }
}
