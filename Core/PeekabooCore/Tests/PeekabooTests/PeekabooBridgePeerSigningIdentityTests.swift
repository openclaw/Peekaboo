import Darwin
import Foundation
import Security
import Testing
@testable import PeekabooBridge

struct PeekabooBridgePeerSigningIdentityTests {
    @Test
    func `same UID legacy peer retains kernel identity without signing metadata`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }

        let peer = try #require(PeekabooBridgeHost.peerInfoIfAllowed(
            fd: sockets.reader,
            allowedTeamIDs: [],
            signingIdentityProvider: { _ in nil }))

        #expect(peer.processIdentifier == getpid())
        #expect(peer.auditTokenProcessIdentifierVersion != nil)
        #expect(peer.codeSignatureHash == nil)
        #expect(peer.userIdentifier == geteuid())
    }

    @Test
    func `team restricted peer still requires signing metadata`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }

        let peer = PeekabooBridgeHost.peerInfoIfAllowed(
            fd: sockets.reader,
            allowedTeamIDs: ["FWJYW4S8P8"],
            signingIdentityProvider: { _ in nil })

        #expect(peer == nil)
    }

    @Test
    func `single signing information lookup supplies bundle and team identity`() {
        var lookupCount = 0
        let identity = PeekabooBridgeHost.signingIdentity(pid: getpid()) { requestedPID in
            lookupCount += 1
            #expect(requestedPID == getpid())
            return [
                kSecCodeInfoIdentifier as String: "boo.peekaboo.peekaboo",
                kSecCodeInfoTeamIdentifier as String: "FWJYW4S8P8",
            ]
        }

        #expect(lookupCount == 1)
        #expect(identity?.bundleIdentifier == "boo.peekaboo.peekaboo")
        #expect(identity?.teamIdentifier == "FWJYW4S8P8")
    }

    @Test
    func `signing identity preserves application identifier team fallback`() {
        let identity = PeekabooBridgeHost.signingIdentity(pid: getpid()) { _ in
            [
                kSecCodeInfoIdentifier as String: "boo.peekaboo.peekaboo",
                kSecCodeInfoEntitlementsDict as String: [
                    "application-identifier": "FWJYW4S8P8.boo.peekaboo.peekaboo",
                ],
            ]
        }

        #expect(identity?.bundleIdentifier == "boo.peekaboo.peekaboo")
        #expect(identity?.teamIdentifier == "FWJYW4S8P8")
    }

    private static func socketPair() throws -> (reader: Int32, writer: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptors[0], descriptors[1])
    }
}
