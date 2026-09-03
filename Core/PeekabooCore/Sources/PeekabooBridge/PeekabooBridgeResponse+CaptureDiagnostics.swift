import PeekabooFoundation

extension PeekabooBridgeResponse {
    /// Only an authenticated operation session can opt into fields that affect the signed response digest.
    func projectingScreenCaptureKitDiagnostics(offered: Bool) -> Self {
        guard !offered else { return self }
        switch self {
        case let .error(envelope):
            return .error(envelope.removingScreenCaptureKitDiagnostic())
        case let .projectedAction(projected):
            return .projectedAction(.init(
                response: projected.response.projectingScreenCaptureKitDiagnostics(offered: false),
                outcome: projected.outcome))
        case let .browserToolResponse(response):
            return .browserToolResponse(.init(
                content: response.content,
                isError: response.isError,
                meta: response.meta,
                structuredContent: response.structuredContent,
                connectionReceipt: response.connectionReceipt,
                completedCallCount: response.completedCallCount,
                dispatchedCallCount: response.dispatchedCallCount,
                actionFailure: response.actionFailure?.removingScreenCaptureKitDiagnostic(),
                providerSessionEpoch: response.providerSessionEpoch))
        default:
            return self
        }
    }
}
