import Darwin
import Security
import Testing
@testable import PeekabooBridge

struct PeekabooBridgePeerSigningIdentityTests {
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
}
