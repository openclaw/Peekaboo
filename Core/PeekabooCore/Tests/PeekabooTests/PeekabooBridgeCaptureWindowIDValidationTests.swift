import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeCaptureWindowIDValidationTests {
    @Test(arguments: [-1, 0, Int(CGWindowID.max) + 1])
    func `receiptless raw capture window rejects IDs outside positive UInt32`(windowId: Int) async throws {
        let services = await MainActor.run { StubServices() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in Self.allowedPermissions })
        }

        let response = try await self.decode(server.decodeAndHandle(
            Self.rawCaptureWindowRequest(windowId: windowId),
            peer: nil))

        guard case let .error(error) = response else {
            Issue.record("Expected invalid capture window response, got \(response)")
            return
        }
        #expect(error.code == .invalidRequest)
        #expect(error.message == "captureWindow windowId must be between 1 and \(CGWindowID.max)")
        #expect(!error.operationMayHaveCompleted)
        #expect(await MainActor.run { services.screenCaptureStub.lastWindowId } == nil)
    }

    @Test
    func `receiptless raw capture window accepts maximum UInt32 ID`() async throws {
        let services = await MainActor.run { StubServices() }
        let expectedWindowID = CGWindowID.max
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in Self.allowedPermissions },
                windowOwnerProcessIdentifierProvider: { windowID in
                    windowID == expectedWindowID ? 42 : nil
                },
                windowBoundsProvider: { windowID in
                    windowID == expectedWindowID ? CGRect(x: 10, y: 20, width: 300, height: 200) : nil
                },
                processStartIdentityProvider: { processIdentifier in
                    processIdentifier == 42 ? 7 : nil
                })
        }

        let response = try await self.decode(server.decodeAndHandle(
            Self.rawCaptureWindowRequest(windowId: Int(expectedWindowID)),
            peer: nil))

        guard case .capture = response else {
            Issue.record("Expected maximum capture window ID to dispatch, got \(response)")
            return
        }
        #expect(await MainActor.run { services.screenCaptureStub.lastWindowId } == expectedWindowID)
    }

    @Test(arguments: [-1, 0, Int(CGWindowID.max) + 1])
    func `protocol 1_29 signs invalid capture window refusal without dispatch`(windowId: Int) async throws {
        let socketPath = "/tmp/peekaboo-capture-window-id-\(UUID().uuidString).sock"
        let services = await MainActor.run { StubServices() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in Self.allowedPermissions })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(
            client: Self.clientIdentity,
            protocolVersion: PeekabooBridgeConstants.attestedOperationReceiptVersion)
        #expect(handshake.negotiatedVersion == PeekabooBridgeConstants.attestedOperationReceiptVersion)

        let request = Self.captureWindowRequest(windowId: windowId)
        let response = try await client.send(request)
        guard case let .error(error) = response else {
            Issue.record("Expected signed invalid capture window response, got \(response)")
            return
        }
        #expect(error.code == .invalidRequest)
        #expect(error.context?.hasPrefix("bridge_target_attribution:") == true)
        #expect(!error.operationMayHaveCompleted)
        #expect(await MainActor.run { services.screenCaptureStub.lastWindowId } == nil)

        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.operation == .captureWindow)
        #expect(bundle.receipt.payload.target == nil)
        #expect(bundle.receipt.payload.targetAttributionFailure != nil)
        #expect(bundle.receipt.payload.outcome == nil)
        let certifiedResponse = try self.decode(bundle.canonicalResponse)
        guard case let .error(certifiedError) = certifiedResponse else {
            Issue.record("Expected receipt to certify the invalid-request refusal")
            return
        }
        #expect(certifiedError.code == .invalidRequest)
        #expect(!certifiedError.operationMayHaveCompleted)
    }

    private static let allowedPermissions = PermissionsStatus(
        screenRecording: true,
        accessibility: true,
        postEvent: true)

    private static var clientIdentity: PeekabooBridgeClientIdentity {
        PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.capture-window-id-tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil)
    }

    private static func captureWindowRequest(windowId: Int) -> PeekabooBridgeRequest {
        .captureWindow(.init(
            appIdentifier: "",
            windowIndex: nil,
            windowId: windowId,
            visualizerMode: .none,
            scale: .logical1x))
    }

    private static func rawCaptureWindowRequest(windowId: Int) throws -> Data {
        let encoded = try JSONEncoder.peekabooBridgeEncoder().encode(Self.captureWindowRequest(windowId: 1))
        var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var requestCase = try #require(root["captureWindow"] as? [String: Any])
        var payload = try #require(requestCase["_0"] as? [String: Any])
        payload["windowId"] = NSNumber(value: windowId)
        requestCase["_0"] = payload
        root["captureWindow"] = requestCase
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func decode(_ data: Data) throws -> PeekabooBridgeResponse {
        try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
    }
}
