import PeekabooFoundation

extension PeekabooBridgeOperationResultSemantics {
    enum BrowserResponseProgressMismatch: String {
        case requestBinding = "browser response request binding"
        case typedFailureMarker = "browser response typed failure marker"
        case progressAndOutcome = "browser response progress and outcome"
        case unknownProgress = "browser response unknown progress"
        case zeroProgressRefusal = "browser response zero progress refusal"
        case positiveProgress = "browser response positive progress"
        case actionFailure = "browser response action failure"
        case successfulOutcome = "successful browser response outcome"
    }

    static func browserResponseProgressMismatch(
        _ response: PeekabooBridgeBrowserToolResponse,
        projection: DesktopActionOutcome.Projection,
        plan: PeekabooBridgeRequestPlan) -> BrowserResponseProgressMismatch?
    {
        guard let request = plan.request.browserExecutionRequest else { return .requestBinding }
        guard response.isError == (response.actionFailure != nil) else { return .typedFailureMarker }
        let outcome = projection.outcome
        guard let completed = response.completedCallCount,
              let dispatched = response.dispatchedCallCount
        else {
            guard response.completedCallCount == nil,
                  response.dispatchedCallCount == nil,
                  let failure = response.actionFailure,
                  failure.outcome.projection == projection,
                  outcome.state == .indeterminate,
                  outcome.delivery == .init(mechanism: .browserProtocol, mode: .background),
                  outcome.evidence == .completionUnknown,
                  outcome.dispatchState.unitCount == nil,
                  self.failureOutcomeMatchesContract(failure.outcome, plan: plan)
            else { return .unknownProgress }
            return nil
        }
        let requested = request.mutationCallCount
        guard completed >= 0, dispatched >= completed, dispatched <= requested else { return .progressAndOutcome }
        if dispatched == 0 {
            guard completed == 0,
                  let failure = response.actionFailure,
                  failure.outcome.projection == projection,
                  outcome.state == .refused,
                  self.failureOutcomeMatchesContract(failure.outcome, plan: plan)
            else { return .zeroProgressRefusal }
            return nil
        }
        guard let units = DesktopActionOutcome.DispatchUnitCount(dispatched),
              outcome.dispatchState.unitCount == units
        else { return .positiveProgress }
        if let failure = response.actionFailure {
            guard failure.outcome.projection == projection,
                  self.failureOutcomeMatchesContract(failure.outcome, plan: plan)
            else { return .actionFailure }
            return nil
        }
        guard completed == requested,
              dispatched == requested,
              self.successfulOutcomeMatchesContract(outcome, response: .browserToolResponse(response), plan: plan)
        else { return .successfulOutcome }
        return nil
    }
}
