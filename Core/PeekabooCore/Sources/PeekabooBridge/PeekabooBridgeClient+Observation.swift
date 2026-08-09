import Foundation
import PeekabooAutomationKit

extension PeekabooBridgeClient {
    public func desktopObservation(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        let timeout = Self.desktopObservationRequestTimeout(
            overallTimeout: request.timeout.overall,
            defaultTimeout: self.requestTimeoutSec)
        let response = try await self.send(.desktopObservation(request), timeoutSec: timeout)
        switch response {
        case let .desktopObservation(result):
            return result
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected desktop observation response")
        }
    }

    static func desktopObservationRequestTimeout(
        overallTimeout: TimeInterval?,
        defaultTimeout: TimeInterval) -> TimeInterval?
    {
        overallTimeout.map { max(defaultTimeout, $0 + 5) }
    }
}
