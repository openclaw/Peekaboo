import Foundation
import PeekabooFoundation

/// Explicit opt-in carriage for a legacy mutating Bridge request.
///
/// Bridge connections serve one request each, so a prior handshake cannot select the response
/// shape of a later connection. A capable client therefore wraps each action request while the
/// nested request preserves the established wire payload exactly.
public struct PeekabooBridgeProjectedActionRequest: Codable, Sendable {
    public let request: PeekabooBridgeRequest

    public init(request: PeekabooBridgeRequest) {
        self.request = request
    }

    /// Returns the legacy action request after enforcing the one-layer mutating-only contract.
    public func validatedRequest() throws -> PeekabooBridgeRequest {
        if case .projectedAction = self.request {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Projected Bridge action requests cannot be nested")
        }
        guard self.request.mayMutateDesktop else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Projected Bridge action carriage requires a mutating request")
        }
        return self.request
    }
}

/// Additive response carriage for one projected action request.
///
/// `response` remains the legacy response. `outcome` is optional because older service seams do
/// not all expose their successful native outcome yet; absence must never be upgraded to a
/// fabricated confirmation.
public struct PeekabooBridgeProjectedActionResponse: Codable, Sendable {
    public let response: PeekabooBridgeResponse
    public let outcome: DesktopActionOutcome.Projection?

    public init(
        response: PeekabooBridgeResponse,
        outcome: DesktopActionOutcome.Projection?)
    {
        self.response = response
        self.outcome = outcome
    }
}
