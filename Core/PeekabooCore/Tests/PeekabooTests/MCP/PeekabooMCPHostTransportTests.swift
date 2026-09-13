import Foundation
import Logging
import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooMCPHostTransportTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor
    func `shutdown cancels and drains an accepted tool before serve returns`(cancelsServerTask: Bool) async throws {
        let provider = HeldPermissionsProvider()
        defer { provider.release() }
        let context = await MCPToolTestHelpers.makeContext(permissionsStatusProvider: provider)
        let server = try await PeekabooMCPServer(toolContext: context)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        // InMemoryTransport drops messages sent before the receiving peer connects.
        try await serverTransport.connect()
        let client = Client(name: "MCPShutdownTests", version: "1")
        defer { Task { await client.disconnect(); await server.stopForTesting() } }
        var completedWithDrainedCall = false
        let serving = Task {
            defer { completedWithDrainedCall = provider.finished }
            try await server.serve(transport: serverTransport)
        }
        _ = try await client.connect(transport: clientTransport)
        let call: RequestContext<CallTool.Result> = try await client.callTool(name: "permissions", arguments: [:])
        var started = provider.started.makeAsyncIterator()
        #expect(await started.next() != nil)
        if cancelsServerTask {
            serving.cancel()
        } else {
            await clientTransport.disconnect()
        }
        let release = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            provider.release()
        }

        if cancelsServerTask {
            await #expect(throws: CancellationError.self) { try await serving.value }
        } else {
            try await serving.value
        }
        await release.value
        await client.disconnect()
        _ = try? await call.value
        #expect(provider.sawCancellation)
        #expect(provider.finished)
        #expect(completedWithDrainedCall)
    }

    @Test
    @MainActor
    func `cancelling serve disconnects a host transport only once`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let server = try await PeekabooMCPServer(toolContext: context)
        let (clientTransport, underlying) = await InMemoryTransport.createConnectedPair()
        try await underlying.connect()
        let transport = HeldDisconnectTransport(wrapping: underlying)
        let client = Client(name: "MCPSingleShutdownTests", version: "1")
        let serving = Task { try await server.serve(transport: transport) }
        _ = try await client.connect(transport: clientTransport)

        serving.cancel()
        var started = transport.disconnectStarted.makeAsyncIterator()
        #expect(await started.next() != nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.disconnectCount == 1)
        await transport.release()
        await #expect(throws: CancellationError.self) { try await serving.value }
        #expect(await transport.disconnectCount == 1)
        await client.disconnect()
    }

    @Test
    @MainActor
    func `a concurrent serve refuses before connecting a second transport`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let server = try await PeekabooMCPServer(toolContext: context)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        // InMemoryTransport drops messages sent before the receiving peer connects.
        try await serverTransport.connect()
        let client = Client(name: "MCPConcurrentServeTests", version: "1")
        let serving = Task { try await server.serve(transport: serverTransport) }
        _ = try await client.connect(transport: clientTransport)
        let second = LifecycleHostTransport(failsToConnect: false)
        await #expect(throws: (any Error).self) { try await server.serve(transport: second) }
        #expect(await second.connectCount == 0)
        await client.disconnect()
        try await serving.value
    }

    @Test
    @MainActor
    func `cancellation waits for startup before disconnecting its session`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let server = try await PeekabooMCPServer(toolContext: context)
        let transport = LifecycleHostTransport(failsToConnect: false, holdsConnect: true)
        let serving = Task { try await server.serve(transport: transport) }
        var started = transport.connectStarted.makeAsyncIterator()
        #expect(await started.next() != nil)

        serving.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.disconnectCount == 0)
        await transport.releaseConnect()
        await #expect(throws: CancellationError.self) { try await serving.value }
        #expect(await transport.connectSawCancellation)
        #expect(await transport.disconnectCount == 1)
    }

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

@MainActor
private final class HeldPermissionsProvider: PermissionsStatusProviding {
    let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var finished = false
    private(set) var sawCancellation = false

    init() {
        let pair = AsyncStream<Void>.makeStream()
        self.started = pair.stream
        self.continuation = pair.continuation
    }

    func permissionsStatus() async throws -> PermissionsStatus {
        self.continuation.yield(())
        await withCheckedContinuation { self.waiter = $0 }
        self.sawCancellation = Task.isCancelled
        self.finished = true
        return PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
    }

    func release() {
        self.waiter?.resume()
        self.waiter = nil
        self.continuation.finish()
    }
}

private enum HostTransportError: Error, Equatable {
    case connectionFailed
}

private actor LifecycleHostTransport: Transport {
    nonisolated let logger = Logger(label: "boo.peekaboo.tests.host-transport")
    nonisolated let connectStarted: AsyncStream<Void>
    private let connectContinuation: AsyncStream<Void>.Continuation
    private let failsToConnect: Bool
    private let holdsConnect: Bool
    private var connectWaiter: CheckedContinuation<Void, Never>?
    private(set) var connectSawCancellation = false
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0

    init(failsToConnect: Bool = true, holdsConnect: Bool = false) {
        self.failsToConnect = failsToConnect
        self.holdsConnect = holdsConnect
        let pair = AsyncStream<Void>.makeStream()
        self.connectStarted = pair.stream
        self.connectContinuation = pair.continuation
    }

    func connect() async throws {
        self.connectCount += 1
        self.connectContinuation.yield(())
        if self.holdsConnect {
            await withCheckedContinuation { self.connectWaiter = $0 }
        }
        self.connectSawCancellation = Task.isCancelled
        if self.failsToConnect {
            throw HostTransportError.connectionFailed
        }
    }

    func releaseConnect() {
        self.connectWaiter?.resume()
        self.connectWaiter = nil
        self.connectContinuation.finish()
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

private actor HeldDisconnectTransport: Transport {
    nonisolated let logger = Logger(label: "boo.peekaboo.tests.held-disconnect")
    nonisolated let disconnectStarted: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let underlying: any Transport
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var disconnectCount = 0

    init(wrapping underlying: any Transport) {
        self.underlying = underlying
        let pair = AsyncStream<Void>.makeStream()
        self.disconnectStarted = pair.stream
        self.continuation = pair.continuation
    }

    func connect() async throws {
        try await self.underlying.connect()
    }

    func send(_ data: Data) async throws {
        try await self.underlying.send(data)
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    for try await data in await self.underlying.receive() {
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    func disconnect() async {
        self.disconnectCount += 1
        await self.underlying.disconnect()
        self.continuation.yield(())
        if !self.released {
            await withCheckedContinuation { self.waiters.append($0) }
        }
    }

    func release() {
        self.released = true
        for waiter in self.waiters {
            waiter.resume()
        }
        self.waiters.removeAll()
        self.continuation.finish()
    }
}
