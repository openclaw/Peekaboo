import Foundation
import Logging
import MCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooMCPHostTransportTests {
    @Test
    @MainActor
    func `host transport startup failure releases its snapshot owner`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let server = try await PeekabooMCPServer(toolContext: context)
        let snapshots = await MCPToolUISnapshotStore(owner: server.snapshotOwnerForTesting())
        let snapshot = await snapshots.createSnapshot()
        let transport = LifecycleHostTransport()

        await #expect(throws: HostTransportError.connectionFailed) {
            try await server.serve(transport: transport)
        }

        #expect(await transport.connectCount == 1)
        #expect(await transport.disconnectCount == 1)
        #expect(await snapshots.getSnapshot(id: snapshot.id) == nil)
        #expect(await !snapshots.hasOwnerState())
    }

    @Test
    @MainActor
    func `host transport completion disconnects the SDK session`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let server = try await PeekabooMCPServer(toolContext: context)
        let transport = LifecycleHostTransport(failsToConnect: false)

        try await server.serve(transport: transport)

        #expect(await transport.connectCount == 1)
        #expect(await transport.disconnectCount == 1)
    }
}

private enum HostTransportError: Error, Equatable {
    case connectionFailed
}

private actor LifecycleHostTransport: Transport {
    nonisolated let logger = Logger(label: "boo.peekaboo.tests.host-transport")
    private let failsToConnect: Bool
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0

    init(failsToConnect: Bool = true) {
        self.failsToConnect = failsToConnect
    }

    func connect() async throws {
        self.connectCount += 1
        if self.failsToConnect {
            throw HostTransportError.connectionFailed
        }
    }

    func disconnect() async {
        self.disconnectCount += 1
    }

    func send(_: Data) async throws {
        throw HostTransportError.connectionFailed
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
