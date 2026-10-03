import Darwin
import Foundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@MainActor
struct PeekabooBridgeGUIClientAuthorizationTests {
    @Test(arguments: [
        "boo.peekaboo.peekaboo",
        "boo.peekaboo.mac",
        "boo.peekaboo.peekaboo-certification-controller",
    ], ["Y5PE65HELJ", "FWJYW4S8P8"])
    func `accepts first party clients`(bundle: String, team: String) throws {
        try Self.server().validatePeerAuthorization(Self.peer(bundle: bundle, team: team))
    }

    @Test(arguments: [
        "org.openclaw.unrelated",
        "boo.peekaboo.peekaboo-certification-controller.extra",
        "boo.peekaboo.background-computer-use-probe",
    ])
    func `rejects unlisted bundles`(bundle: String) {
        self.expectRefusal(Self.peer(bundle: bundle))
    }

    @Test(arguments: ["UNTRUSTED1", nil] as [String?])
    func `rejects untrusted or missing team`(team: String?) {
        self.expectRefusal(Self.peer(team: team))
    }

    @Test
    func `rejects missing peer or bundle and wrong user`() {
        self.expectRefusal(nil)
        self.expectRefusal(Self.peer(bundle: nil))
        self.expectRefusal(Self.peer(uid: getuid() + 1))
    }

    @Test
    func `rejects forged controller handshake from unlisted peer`() async throws {
        let request = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            client: .init(
                bundleIdentifier: PeekabooBridgeConstants.certificationControllerBundleIdentifier,
                teamIdentifier: "FWJYW4S8P8",
                processIdentifier: getpid(),
                hostname: nil),
            requestedHostKind: .gui))
        let response = try await Self.server().decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: Self.peer(bundle: "org.openclaw.unrelated"))
        guard case let .error(error) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: response)
        else {
            Issue.record("An unlisted peer must not claim the controller identity in its handshake")
            return
        }
        #expect(error.code == .unauthorizedClient)
    }

    private func expectRefusal(_ peer: PeekabooBridgePeer?) {
        do {
            try Self.server().validatePeerAuthorization(peer)
            Issue.record("Expected GUI client authorization refusal")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .unauthorizedClient)
        } catch {
            Issue.record("Unexpected authorization error: \(error)")
        }
    }

    private static func server() -> PeekabooBridgeServer {
        PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: PeekabooBridgeConstants.trustedReleaseTeamIDs,
            allowlistedBundles: PeekabooBridgeConstants.guiClientBundleIdentifiers)
    }

    private static func peer(
        bundle: String? = "boo.peekaboo.peekaboo-certification-controller",
        team: String? = "FWJYW4S8P8",
        uid: uid_t = getuid()) -> PeekabooBridgePeer
    {
        PeekabooBridgePeer(
            processIdentifier: getpid(),
            userIdentifier: uid,
            bundleIdentifier: bundle,
            teamIdentifier: team)
    }
}
