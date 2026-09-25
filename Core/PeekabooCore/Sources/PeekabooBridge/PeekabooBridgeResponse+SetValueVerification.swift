import PeekabooAutomationKit

extension PeekabooBridgeResponse {
    /// Old receivers drop unknown result fields before reconstructing the signed response digest.
    func projectingSetValueVerification(offered: Bool) -> Self {
        guard !offered else { return self }
        switch self {
        case let .elementActionResult(result):
            return .elementActionResult(.init(
                target: result.target,
                actionName: result.actionName,
                anchorPoint: result.anchorPoint,
                oldValue: result.oldValue,
                newValue: result.newValue))
        case let .projectedAction(projected):
            return .projectedAction(.init(
                response: projected.response.projectingSetValueVerification(offered: false),
                outcome: projected.outcome))
        default:
            return self
        }
    }
}
