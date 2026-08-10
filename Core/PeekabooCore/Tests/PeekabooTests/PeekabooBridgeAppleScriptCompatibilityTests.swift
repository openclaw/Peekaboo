import Foundation
import PeekabooCore
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeAppleScriptCompatibilityTests {
    private func decode(_ data: Data) throws -> PeekabooBridgeResponse {
        try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
    }

    @Test
    func `Current handshake omits legacy AppleScript capability and permission`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [.permissionsStatus, ._appleScriptProbe])
        }
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil)
        let request = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            client: identity,
            requestedHostKind: nil))
        let response = try await self.decode(server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil))

        guard case let .handshake(handshake) = response else {
            Issue.record("Expected handshake response, got \(response)")
            return
        }
        #expect(!handshake.supportedOperations.contains(._appleScriptProbe))
        #expect(handshake.enabledOperations?.contains(._appleScriptProbe) != true)
        #expect(handshake.permissions?.appleScript == false)
    }

    @Test
    func `Legacy AppleScript probe decodes but current host refuses it without execution`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [._appleScriptProbe])
        }
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(PeekabooBridgeRequest.appleScriptProbe)
        let response = try await self.decode(server.decodeAndHandle(requestData, peer: nil))

        guard case let .error(envelope) = response else {
            Issue.record("Expected a structured unsupported-operation response, got \(response)")
            return
        }
        #expect(envelope.code == .operationNotSupported)
    }
}
