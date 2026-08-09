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

    @Test
    func `legacy remote observation does not hold a client desktop lane across capture RPC`() async throws {
        let socketPath = "/tmp/peekaboo-remote-observation-lane-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.captureScreen],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: true,
                    postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemotePeekabooServices(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1),
            supportsDesktopObservation: false)

        let result = try await remote.desktopObservation.observe(DesktopObservationRequest(
            target: .screen(index: 0),
            detection: DesktopDetectionOptions(mode: .none)))

        #expect(result.capture.imageData == StubScreenCaptureService.sampleData)
        await host.stop()
    }
}
