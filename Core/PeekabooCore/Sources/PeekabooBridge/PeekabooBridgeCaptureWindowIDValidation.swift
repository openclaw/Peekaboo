import CoreGraphics

extension PeekabooBridgeCaptureWindowRequest {
    func validatedWindowID() throws -> CGWindowID? {
        guard let windowId = self.windowId else { return nil }
        guard windowId > 0, let windowID = CGWindowID(exactly: windowId) else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "captureWindow windowId must be between 1 and \(CGWindowID.max)")
        }
        return windowID
    }
}

extension PeekabooBridgeRequest {
    func validatePlatformIdentifierBounds() throws {
        switch self {
        case let .attestedOperation(payload):
            try payload.request.validatePlatformIdentifierBounds()
        case let .projectedAction(payload):
            try payload.request.validatePlatformIdentifierBounds()
        case let .captureWindow(payload):
            _ = try payload.validatedWindowID()
        default:
            return
        }
    }
}
