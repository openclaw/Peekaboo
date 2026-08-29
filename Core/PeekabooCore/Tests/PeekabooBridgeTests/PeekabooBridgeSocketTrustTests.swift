import Foundation
import PeekabooBridge
import Testing

struct PeekabooBridgeSocketTrustTests {
    @Test
    func `canonical OpenClaw socket trusts both release signing teams`() {
        let path = Self.applicationSupport.appendingPathComponent("OpenClaw/bridge.sock").path
        #expect(PeekabooBridgeConstants.openClawSocketPath == path)
        #expect(PeekabooBridgeConstants.defaultTrustedHostTeamIDs(socketPath: path) ==
            ["Y5PE65HELJ", "FWJYW4S8P8"])
    }

    @Test(arguments: [
        "Peekaboo/bridge.sock",
        "Peekaboo/daemon.sock",
        "Peekaboo/daemon-0123456789abcdef.sock",
        "Claude/bridge.sock",
        "clawdbot/bridge.sock",
    ])
    func `existing canonical and legacy sockets keep release trust`(relativePath: String) {
        let path = Self.applicationSupport.appendingPathComponent(relativePath).path
        #expect(PeekabooBridgeConstants.defaultTrustedHostTeamIDs(socketPath: path) ==
            ["Y5PE65HELJ", "FWJYW4S8P8"])
    }

    @Test(arguments: [
        "OpenClaw/other.sock",
        "OpenClaw/bridge.sock.backup",
        "OpenClaw/daemon.sock",
        "OpenClaw/daemon-0123456789abcdef.sock",
        "OpenClaw/nested/bridge.sock",
        "OpenClaw-copy/bridge.sock",
        "openclaw/bridge.sock",
        "OpenClaw.app/bridge.sock",
        "Other/OpenClaw/bridge.sock",
        "Other/bridge.sock",
        "OpenClaw/../Other/bridge.sock",
        "Peekaboo/daemon-0123456789abcdeg.sock",
        "Peekaboo/daemon-0123456789abcde.sock",
        "Peekaboo/daemon-0123456789abcdef0.sock",
    ])
    func `lookalike sibling and custom sockets receive no default trust`(relativePath: String) {
        let path = Self.applicationSupport.appendingPathComponent(relativePath).path
        #expect(PeekabooBridgeConstants.defaultTrustedHostTeamIDs(socketPath: path) == nil)
    }

    @Test(arguments: ["/tmp/custom-peekaboo.sock", "/tmp/OpenClaw/bridge.sock"])
    func `matching names outside application support receive no default trust`(path: String) {
        #expect(PeekabooBridgeConstants.defaultTrustedHostTeamIDs(socketPath: path) == nil)
    }

    private static var applicationSupport: URL {
        URL(fileURLWithPath: PeekabooBridgeConstants.peekabooSocketPath)
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}
