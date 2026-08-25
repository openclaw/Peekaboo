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
    func `protocol 1 33 advertises composed input payloads`() {
        let previous = PeekabooBridgeProtocolVersion(major: 1, minor: 32)
        let current = PeekabooBridgeProtocolVersion(major: 1, minor: 33)
        let operations: Set<PeekabooBridgeOperation> = [
            .permissionsStatus,
            .exactWindowPixelFocusType,
            .foregroundModifierClick,
        ]

        #expect(PeekabooBridgeConstants.protocolVersion >= current)
        #expect(PeekabooBridgeConstants.composedInputParityVersion == current)
        #expect(PeekabooBridgeOperation.compatible(operations, with: previous) == [.permissionsStatus])
        #expect(PeekabooBridgeOperation.compatible(operations, with: current) == operations)
    }

    @Test
    func `legacy protocol 1 33 modifier click decodes without snapshot authority`() throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let identity = WindowMutationIdentity(
            windowID: 77,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds)
        let payload = PeekabooBridgeForegroundModifierClickRequest(request: .init(
            point: CGPoint(x: 20, y: 20),
            clickType: .single,
            modifiers: [.command],
            snapshotID: "snapshot",
            windowIdentity: identity,
            windowBounds: bounds))
        let encoded = try JSONEncoder().encode(payload)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var request = try #require(object["request"] as? [String: Any])
        request.removeValue(forKey: "snapshotID")
        object["request"] = request
        let missingSnapshot = try JSONSerialization.data(withJSONObject: object)

        let legacy = try JSONDecoder().decode(
            PeekabooBridgeForegroundModifierClickRequest.self,
            from: missingSnapshot)
        #expect(legacy.request.snapshotID.isEmpty)

        let changedSnapshot = PeekabooBridgeForegroundModifierClickRequest(request: .init(
            point: payload.request.point,
            clickType: payload.request.clickType,
            modifiers: payload.request.modifiers,
            snapshotID: "other-snapshot",
            windowIdentity: identity,
            windowBounds: bounds))
        #expect(
            try PeekabooBridgeOperationReceiptCoding.canonicalData(
                PeekabooBridgeRequest.foregroundModifierClick(payload)) !=
                PeekabooBridgeOperationReceiptCoding.canonicalData(
                    PeekabooBridgeRequest.foregroundModifierClick(changedSnapshot)))
    }

    @Test
    @MainActor
    func `protocol 1 33 host without leaf lease capability refuses before service entry`() async throws {
        let legacy = PeekabooBridgeProtocolVersion(major: 1, minor: 33)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let identity = WindowMutationIdentity(
            windowID: 77,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds)
        let automation = MockAutomationService(accessibilityGranted: true)
        automation.supportsForegroundModifierClickSnapshotLease = false
        let socketPath = "/tmp/peekaboo-modifier-lease-version-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: StubServices(automation: automation),
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: legacy...legacy)
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.modifier-lease-version-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: legacy)
        #expect(handshake.negotiatedVersion == legacy)
        #expect(!handshake.supportedOperations.contains(.foregroundModifierClick))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.foregroundModifierClickSnapshotLease) != true)

        let modifierRequest = ForegroundModifierClickRequest(
            point: CGPoint(x: 20, y: 20),
            clickType: .single,
            modifiers: [.command],
            snapshotID: "snapshot",
            windowIdentity: identity,
            windowBounds: bounds)
        let request = PeekabooBridgeRequest.foregroundModifierClick(.init(request: modifierRequest))
        do {
            _ = try await server.handleAuthorized(
                request,
                peer: nil,
                permissions: PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true))
            Issue.record("Expected direct server dispatch to enforce host leaf leasing")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .operationNotSupported)
        }

        do {
            _ = try await client.foregroundModifierClickWithOutcome(modifierRequest)
            Issue.record("Expected protocol 1.33 modifier-click to refuse before service entry")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(automation.foregroundModifierClickRequests.isEmpty)
        await host.stop()
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
        let handshake = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.composed-input-client-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.foregroundModifierClickSnapshotLease) == true)

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
            snapshotID: "snapshot",
            windowIdentity: identity,
            windowBounds: bounds))

        #expect(pixel.targetIdentity?.exactWindow?.identity == identity)
        #expect(modifier.targetIdentity?.exactWindow?.identity == identity)
        #expect(automation.pixelFocusTypeRequests.count == 1)
        #expect(automation.foregroundModifierClickRequests.count == 1)
        #expect(automation.foregroundModifierClickRequests.first?.snapshotID == "snapshot")
        await host.stop()
    }
}
