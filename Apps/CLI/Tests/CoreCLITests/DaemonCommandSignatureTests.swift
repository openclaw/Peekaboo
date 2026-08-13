import Testing
@testable import PeekabooCLI

struct DaemonCommandSignatureTests {
    @Test
    func `Daemon commands share the canonical bridge socket option`() throws {
        let arguments = ["--bridge-socket", "/tmp/peekaboo-test.sock"]

        #expect(try DaemonCommand.Start.parse(arguments).bridgeSocket == "/tmp/peekaboo-test.sock")
        #expect(try DaemonCommand.Stop.parse(arguments).bridgeSocket == "/tmp/peekaboo-test.sock")
        #expect(try DaemonCommand.Status.parse(arguments).bridgeSocket == "/tmp/peekaboo-test.sock")
        #expect(try DaemonCommand.Run.parse(arguments).bridgeSocket == "/tmp/peekaboo-test.sock")
    }
}
