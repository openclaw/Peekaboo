import PeekabooBridge
import Testing

struct PeekabooBridgeConstantsTests {
    @Test
    func `Peekaboo host sockets have distinct roles`() {
        #expect(PeekabooBridgeConstants.peekabooSocketPath.hasSuffix("/Peekaboo/bridge.sock"))
        #expect(PeekabooBridgeConstants.daemonSocketPath.hasSuffix("/Peekaboo/daemon.sock"))
    }

    @Test
    func `Claude socket path uses Application Support/Claude`() {
        #expect(PeekabooBridgeConstants.claudeSocketPath.hasSuffix("/Claude/bridge.sock"))
    }
}
