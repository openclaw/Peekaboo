import Foundation
import Logging
import MCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooMCPHostTransportFailureTests {
    @Test
    @MainActor
    func `host transport startup failure releases its snapshot owner`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let server = try await PeekabooMCPServer(toolContext: context)
        let snapshots = await MCPToolUISnapshotStore(owner: server.snapshotOwnerForTesting())
        let snapshot = await snapshots.createSnapshot()
        let transport = FailingHostTransport()

        await #expect(throws: HostTransportError.connectionFailed) {
            try await server.serve(transport: transport)
        }

        #expect(await transport.connectCount == 1)
        #expect(await snapshots.getSnapshot(id: snapshot.id) == nil)
        #expect(await !snapshots.hasOwnerState())
    }
}

private enum HostTransportError: Error, Equatable {
    case connectionFailed
}

private actor FailingHostTransport: Transport {
    nonisolated let logger = Logger(label: "boo.peekaboo.tests.host-transport")
    private(set) var connectCount = 0

    func connect() async throws {
        self.connectCount += 1
        throw HostTransportError.connectionFailed
    }

    func disconnect() async {}

    func send(_: Data) async throws {
        throw HostTransportError.connectionFailed
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { $0.finish(throwing: HostTransportError.connectionFailed) }
    }
}
