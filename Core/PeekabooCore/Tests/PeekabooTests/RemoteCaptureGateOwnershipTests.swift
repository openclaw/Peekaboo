import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import Testing
@testable import PeekabooCore

@MainActor
struct RemoteCaptureGateOwnershipTests {
    @Test
    func `legacy remote observation delegates capture transaction gating to host`() {
        let client = PeekabooBridgeClient(
            socketPath: "/tmp/nonexistent-\(UUID().uuidString).sock",
            requestTimeoutSec: 1)
        let legacyObservation = RemotePeekabooServices(client: client, supportsDesktopObservation: false)
        let modernObservation = RemotePeekabooServices(client: client, supportsDesktopObservation: true)

        #expect(legacyObservation.desktopObservation is DesktopObservationService)
        #expect(modernObservation.desktopObservation is RemoteDesktopObservationService)
        #expect(
            legacyObservation.screenCapture.captureTransactionGateOwner == CaptureTransactionGateOwner.service)
    }
}
