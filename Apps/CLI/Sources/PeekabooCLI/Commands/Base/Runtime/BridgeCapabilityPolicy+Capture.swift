import PeekabooBridge
import PeekabooFoundation

extension BridgeCapabilityPolicy {
    static func supportsScreenCaptureKitProcessOwnership(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> Bool {
        handshake.supportedOperations.contains(.desktopObservation) &&
            (handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership
            ) == true || handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.screenCaptureKitOwnershipEnforcement
            ) == true)
    }

    static func supportsClassicCaptureWithoutScreenCaptureKit(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> Bool {
        handshake.supportedOperations.contains(.desktopObservation) &&
            (handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.classicCaptureWithoutScreenCaptureKit
            ) == true || handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership
            ) == true)
    }

    static func screenCaptureKitReadinessRefusal(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> ScreenCaptureKitOwnershipDiagnostic? {
        guard self.supportsScreenCaptureKitProcessOwnership(for: handshake) else { return nil }
        // The old capability is the named compatibility contract for hosts without readiness data.
        if handshake.screenCaptureKitReadiness == nil,
           handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.screenCaptureKitOwnershipEnforcement)
           != true {
            return nil
        }
        guard handshake.screenCaptureKitReadiness?.permitsAttempt != true else { return nil }
        return handshake.screenCaptureKitReadiness?.refusal ?? ScreenCaptureKitReadiness(state: .unknown).refusal
    }
}
