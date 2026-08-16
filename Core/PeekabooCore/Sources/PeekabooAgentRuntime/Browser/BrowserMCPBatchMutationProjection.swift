import PeekabooFoundation

extension BrowserMCPExecutionResult {
    /// Projects provider-call progress onto only the calls that can mutate browser state.
    ///
    /// Chrome DevTools batches can mix observations and mutations. Provider progress counts every
    /// MCP call, but desktop-action units count only mutations; otherwise a failed observation can
    /// falsely claim that a later page mutation ran and make a safe retry look unsafe.
    public func projectingMutationProgress(
        for calls: [BrowserMCPMappedCall]) throws -> BrowserMCPExecutionResult
    {
        let semantics = calls.map { call in
            BrowserMCPPageRoutingContract.actionSemantics(
                for: call.toolName,
                arguments: call.arguments) ?? .mutating
        }
        let plannedMutationCount = semantics.count(where: { $0 == .mutating })
        guard self.completedCallCount <= calls.count,
              self.dispatchedCallCount <= calls.count
        else {
            if let unitCount = DesktopActionOutcome.DispatchUnitCount(plannedMutationCount) {
                throw DesktopActionFailure.indeterminate(
                    route: self.actionFailure?.outcome.route ?? .local,
                    delivery: Self.browserDelivery,
                    evidence: .completionUnknown,
                    unitCount: unitCount,
                    message: "Browser provider reported progress beyond the requested call sequence.",
                    hint: "Observe the browser before retrying and update the browser provider.")
            }
            throw PeekabooError.commandFailed(
                "Browser provider reported progress beyond the requested read-only call sequence")
        }
        guard plannedMutationCount != semantics.count else { return self }

        let completedMutationCount = Self.mutationCount(
            in: semantics,
            prefixCount: self.completedCallCount)
        let dispatchedMutationCount = Self.mutationCount(
            in: semantics,
            prefixCount: self.dispatchedCallCount)
        let projectedFailure = self.projectedMutationFailure(
            semantics: semantics,
            completedMutationCount: completedMutationCount,
            dispatchedMutationCount: dispatchedMutationCount)

        return BrowserMCPExecutionResult(
            response: self.response,
            connectionReceipt: self.connectionReceipt,
            connectionOutcome: self.connectionOutcome,
            completedCallCount: completedMutationCount,
            dispatchedCallCount: dispatchedMutationCount,
            actionFailure: projectedFailure,
            failureStage: self.failureStage,
            providerReturnedError: self.providerReturnedError)
    }

    private func projectedMutationFailure(
        semantics: [BrowserMCPPageRoutingContract.ActionSemantics],
        completedMutationCount: Int,
        dispatchedMutationCount: Int) -> DesktopActionFailure?
    {
        guard let failure = self.actionFailure else { return nil }
        guard dispatchedMutationCount > 0 else {
            if failure.outcome.dispatchState == .none {
                return failure
            }
            return .preDispatchRefusal(
                route: failure.outcome.route,
                reason: .targetUnavailable,
                message: "Browser execution stopped before any mutating tool call was dispatched.",
                hint: "Refresh the browser state and retry the mutation sequence if it is still needed.",
                causeDescription: failure.causeDescription ?? failure.message)
        }

        let projectedOutcome: DesktopActionOutcome = switch self.failureStage {
        case let .call(index) where semantics.indices.contains(index) && semantics[index] == .readOnly:
            .partial(
                route: failure.outcome.route,
                delivery: Self.browserDelivery,
                unitCount: Self.dispatchUnitCount(completedMutationCount))
        case .connectionValidation, nil:
            .indeterminate(
                route: failure.outcome.route,
                delivery: Self.browserDelivery,
                evidence: failure.outcome.evidence == .responseLost ? .responseLost : .completionUnknown,
                unitCount: Self.dispatchUnitCount(dispatchedMutationCount))
        case .call:
            Self.reprojectMutationFailure(
                failure.outcome,
                completedMutationCount: completedMutationCount,
                dispatchedMutationCount: dispatchedMutationCount)
        }

        guard let projected = DesktopActionFailure(
            outcome: projectedOutcome,
            message: failure.message,
            hint: failure.hint,
            causeDescription: failure.causeDescription,
            targetReceipt: failure.targetReceipt)
        else {
            preconditionFailure("A projected browser batch failure must remain non-confirmed")
        }
        return projected
    }

    private static func reprojectMutationFailure(
        _ outcome: DesktopActionOutcome,
        completedMutationCount: Int,
        dispatchedMutationCount: Int) -> DesktopActionOutcome
    {
        let delivery = outcome.delivery ?? self.browserDelivery
        switch outcome.state {
        case .partial:
            return .partial(
                route: outcome.route,
                delivery: delivery,
                unitCount: self.dispatchUnitCount(completedMutationCount))
        case .indeterminate:
            return .indeterminate(
                route: outcome.route,
                delivery: delivery,
                evidence: outcome.evidence == .responseLost ? .responseLost : .completionUnknown,
                unitCount: self.dispatchUnitCount(dispatchedMutationCount))
        case .dispatchedUnverified:
            return .dispatchedUnverified(
                route: outcome.route,
                delivery: delivery,
                evidence: outcome.evidence == .operationStillRunning ? .operationStillRunning : .deliveryAccepted,
                unitCount: self.dispatchUnitCount(dispatchedMutationCount))
        case .suspectedNoop:
            return .suspectedNoop(
                route: outcome.route,
                delivery: delivery,
                unitCount: self.dispatchUnitCount(dispatchedMutationCount))
        case .refused, .confirmedChange, .confirmedNoChange:
            return .indeterminate(
                route: outcome.route,
                delivery: delivery,
                evidence: .completionUnknown,
                unitCount: self.dispatchUnitCount(dispatchedMutationCount))
        }
    }

    private static func mutationCount(
        in semantics: [BrowserMCPPageRoutingContract.ActionSemantics],
        prefixCount: Int) -> Int
    {
        semantics.prefix(prefixCount).count(where: { $0 == .mutating })
    }

    private static func dispatchUnitCount(_ count: Int) -> DesktopActionOutcome.DispatchUnitCount {
        guard let unitCount = DesktopActionOutcome.DispatchUnitCount(count) else {
            preconditionFailure("A projected browser mutation outcome must account for at least one dispatch")
        }
        return unitCount
    }

    private static let browserDelivery = DesktopActionOutcome.Delivery(
        mechanism: .browserProtocol,
        mode: .background)
}
