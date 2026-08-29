import Foundation
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeCanonicalHostAuthenticationTests {
    @Test(arguments: ["Y5PE65HELJ", "FWJYW4S8P8", "OTHER-TEAM", "wrong-hash", nil] as [String?])
    func `canonical OpenClaw trust retains connected signer validation`(signer: String?) async throws {
        let canonicalPath = URL(fileURLWithPath: PeekabooBridgeConstants.peekabooSocketPath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenClaw/bridge.sock").path
        // Exercise the canonical policy on a test-owned socket, never the installed OpenClaw listener.
        let trustedTeams = try #require(PeekabooBridgeConstants.defaultTrustedHostTeamIDs(socketPath: canonicalPath))
        let acceptedSigner = signer == "Y5PE65HELJ" || signer == "FWJYW4S8P8"
        let peer = try ScriptedBridgePeer(responses: [
            .error(.init(
                code: acceptedSigner ? .invalidRequest : .versionMismatch,
                message: "A refused signer must not trigger protocol fallback")),
        ])
        let client = PeekabooBridgeClient(
            socketPath: peer.socketPath,
            requestTimeoutSec: 1,
            trustedHostTeamIDs: trustedTeams,
            hostAuthentication: .init(signingIdentity: { auditIdentity in
                guard let signer,
                      let hash = PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(auditIdentity: auditIdentity)
                else { return nil }
                return PeekabooBridgeHost.PeerSigningIdentity(
                    bundleIdentifier: "dev.peekaboo.test-host",
                    teamIdentifier: signer == "wrong-hash" ? "Y5PE65HELJ" : signer,
                    codeSignatureHash: signer == "wrong-hash" ? "mismatched-hash" : hash)
            }))
        do {
            do {
                try await client.handshake(client: .init(
                    bundleIdentifier: "dev.peekaboo.signer-tests",
                    teamIdentifier: nil,
                    processIdentifier: ProcessInfo.processInfo.processIdentifier))
                Issue.record("Expected handshake refusal")
            } catch let envelope as PeekabooBridgeErrorEnvelope {
                #expect(envelope.code == (acceptedSigner ? .invalidRequest : .unauthorizedClient))
            }
            #expect(await peer.acceptedConnectionCount == 1)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }
}
