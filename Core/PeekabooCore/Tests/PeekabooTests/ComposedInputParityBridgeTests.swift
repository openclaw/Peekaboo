import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

struct ComposedInputParityBridgeTests {
    @Test
    func `protocol 1 33 exclusively advertises composed input parity operations`() {
        let previous = PeekabooBridgeProtocolVersion(major: 1, minor: 32)
        let current = PeekabooBridgeProtocolVersion(major: 1, minor: 33)
        let operations: Set<PeekabooBridgeOperation> = [
            .permissionsStatus,
            .exactWindowPixelFocusType,
            .foregroundModifierClick,
        ]

        #expect(PeekabooBridgeConstants.protocolVersion == current)
        #expect(PeekabooBridgeConstants.composedInputParityVersion == current)
        #expect(PeekabooBridgeOperation.compatible(operations, with: previous) == [.permissionsStatus])
        #expect(PeekabooBridgeOperation.compatible(operations, with: current) == operations)
    }

    @Test
    @MainActor
    func `attested composed input returns its exact target identity`() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let identity = WindowMutationIdentity(
            windowID: 77,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds)
        let automation = MockAutomationService(accessibilityGranted: true)
        let socketPath = "/tmp/peekaboo-composed-input-client-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: StubServices(automation: automation),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.composed-input-client-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))

        let pixel = try await client.typeActionsByFocusingPixelWithOutcome(.init(
            point: CGPoint(x: 20, y: 20),
            actions: [.text("x")],
            cadence: .fixed(milliseconds: 0),
            snapshotID: "snapshot",
            windowIdentity: identity,
            windowBounds: bounds))
        let modifier = try await client.foregroundModifierClickWithOutcome(.init(
            point: CGPoint(x: 20, y: 20),
            clickType: .single,
            modifiers: [.command],
            windowIdentity: identity,
            windowBounds: bounds))

        #expect(pixel.targetIdentity?.exactWindow?.identity == identity)
        #expect(modifier.targetIdentity?.exactWindow?.identity == identity)
        #expect(automation.pixelFocusTypeRequests.count == 1)
        #expect(automation.foregroundModifierClickRequests.count == 1)
        await host.stop()
    }
}
