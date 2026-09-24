import PeekabooAutomationKit
import PeekabooFoundation

/// A route-bound restriction, not permission to enter either capture backend. The authenticated host still
/// validates every request. A classic-only route never widens during the lifetime of its service graph.
public enum RemoteCapturePolicy: Sendable {
    case unrestricted
    case classicOnly(DesktopActionFailure)

    func applying(to request: DesktopObservationRequest) throws -> DesktopObservationRequest {
        guard case .classicOnly = self else { return request }
        var request = request
        switch request.capture.engine {
        case .auto:
            request.capture.engine = .legacy
        case .modern:
            try self.requireScreenCaptureKit()
        case .legacy:
            break
        }
        return request
    }

    func requireScreenCaptureKit() throws {
        if case let .classicOnly(failure) = self {
            throw failure.routed(to: .bridge)
        }
    }
}
