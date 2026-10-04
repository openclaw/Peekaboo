import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@MainActor
@Suite(.serialized)
struct PeekabooBridgeTextSelectionHostTests {
    @Test(arguments: [false, true])
    func `selection requires new host capability before wire dispatch`(oldHost: Bool) async throws {
        let services = StubServices()
        services.automationStub.supportsTextSelection = true
        let generation = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        services.automationStub.uiAutomationOutcomeTargetIdentity = try DesktopTargetIdentity(exactWindow: .init(
            identity: .init(
                windowID: 42,
                ownerProcessIdentifier: getpid(),
                ownerProcessStartIdentity: generation,
                capturedBounds: CGRect(x: 0, y: 0, width: 500, height: 400),
                isMinimized: false),
            bounds: CGRect(x: 0, y: 0, width: 500, height: 400)))
        let version = oldHost ? PeekabooBridgeProtocolVersion(major: 1, minor: 41) : PeekabooBridgeConstants
            .protocolVersion
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: PeekabooBridgeConstants.minimumProtocolVersion...version,
            allowedOperations: [.selectText],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
            })
        let socket = "/tmp/peekaboo-selection-synthetic-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(socketPath: socket, server: server, allowedTeamIDs: [], requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socket, requestTimeoutSec: 2)
        let handshake = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.text-selection-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: version)
        #expect(handshake.supportedOperations.contains(.selectText) == !oldHost)
        #expect(handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.textSelection) == !oldHost)
        if oldHost {
            let failure = await #expect(throws: DesktopActionFailure.self) {
                _ = try await client.selectText(target: "T1", request: .init(text: "needle"), snapshotId: "snapshot")
            }
            #expect(failure?.outcome.retrySafety == .safe)
            #expect(services.automationStub.textSelectionCalls == 0)
        } else {
            let result = try await client.selectText(
                target: "T1", request: .init(text: "needle", selectionType: .cursorAfter), snapshotId: "snapshot")
            #expect(result.payload.textSelection?.selectedRange == TextSelectionRange(location: 6, length: 0))
            #expect(result.outcome?.state == .confirmedChange)
            #expect(services.automationStub.textSelectionCalls == 1)
            try #require(await client.lastOperationReceiptBundle()).validate()
        }
        await host.stop()
    }
}
