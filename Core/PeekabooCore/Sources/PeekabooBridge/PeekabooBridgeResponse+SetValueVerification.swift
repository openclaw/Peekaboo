import PeekabooAutomationKit

extension PeekabooBridgeResponse {
    /// Old receivers drop unknown result fields before reconstructing the signed response digest.
    func projectingSetValueVerification(offered: Bool, request: PeekabooBridgeRequest) throws -> Self {
        switch self {
        case let .elementActionResult(result):
            var newValue = result.newValue
            if case .setValue = request.unwrappedOperationRequest, let witness = result.valueVerification {
                // Validate before stripping: otherwise a forged legacy spelling could bypass typed request binding.
                let plan = PeekabooBridgeOperationResultSemantics.requestPlan(for: request, vocabulary: .current)
                try plan.validateBoundTypedResponse(self, outcome: nil)
                newValue = witness.legacyPresentation
            }
            guard !offered else { return self }
            return .elementActionResult(.init(
                target: result.target,
                actionName: result.actionName,
                anchorPoint: result.anchorPoint,
                oldValue: result.oldValue,
                newValue: newValue))
        case let .projectedAction(projected):
            return try .projectedAction(.init(
                response: projected.response.projectingSetValueVerification(offered: offered, request: request),
                outcome: projected.outcome))
        default:
            return self
        }
    }
}
