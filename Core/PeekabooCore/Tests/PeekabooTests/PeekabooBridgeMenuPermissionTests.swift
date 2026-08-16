import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeMenuPermissionTests {
    @Test
    func `indexed menu click requires AX and post event while named click remains AX only`() async throws {
        let denied = try await self.handshake(postEvent: false)
        #expect(denied.permissionTags[PeekabooBridgeOperation.clickMenuBarItemNamed.rawValue] == [.accessibility])
        #expect(denied.permissionTags[PeekabooBridgeOperation.clickMenuBarItemIndex.rawValue] == [
            .accessibility,
            .postEvent,
        ])
        #expect(denied.enabledOperations?.contains(.clickMenuBarItemNamed) == true)
        #expect(denied.enabledOperations?.contains(.clickMenuBarItemIndex) == false)

        let enabled = try await self.handshake(postEvent: true)
        #expect(enabled.enabledOperations?.contains(.clickMenuBarItemNamed) == true)
        #expect(enabled.enabledOperations?.contains(.clickMenuBarItemIndex) == true)
        #expect(PeekabooBridgeOperation.clickMenuBarItemIndex.requiredPermissions == [
            .accessibility,
            .postEvent,
        ])
    }

    private func handshake(postEvent: Bool) async throws -> PeekabooBridgeHandshakeResponse {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [.clickMenuBarItemNamed, .clickMenuBarItemIndex],
                postEventAccessEvaluator: { postEvent },
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: true,
                        postEvent: postEvent)
                })
        }
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)
        let request = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: .init(major: 1, minor: 28),
            client: identity,
            requestedHostKind: .gui))
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(data, peer: nil)
        guard case let .handshake(handshake) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: responseData)
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Expected menu permission handshake")
        }
        return handshake
    }
}
