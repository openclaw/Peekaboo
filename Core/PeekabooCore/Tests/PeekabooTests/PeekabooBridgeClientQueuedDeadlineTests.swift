import Darwin
import Dispatch
import Foundation
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeClientQueuedDeadlineTests {
    @Test
    func `expired queued handshake refuses before connecting`() async throws {
        let socket = try MissingBridgeSocket()
        defer { socket.removeDirectory() }
        let queue = QueuedBridgeTransport()
        var exchanges = queue.exchanges.makeAsyncIterator()
        let request = Self.handshake(socketPath: socket.path, queue: queue, timeout: 0.02)
        defer { request.cancel() }
        let exchange = try #require(await exchanges.next())
        defer { exchange.start() }

        try await Self.waitUntilExpired(exchange.deadline)
        exchange.start()

        await #expect(throws: POSIXError(.ETIMEDOUT)) { _ = try await request.value }
    }

    @Test
    func `unexpired queued handshake still attempts its connection`() async throws {
        let socket = try MissingBridgeSocket()
        defer { socket.removeDirectory() }
        let queue = QueuedBridgeTransport()
        var exchanges = queue.exchanges.makeAsyncIterator()
        let request = Self.handshake(socketPath: socket.path, queue: queue, timeout: 60)
        defer { request.cancel() }
        let exchange = try #require(await exchanges.next())
        defer { exchange.start() }

        exchange.start()

        await #expect(throws: POSIXError(.ENOENT)) { _ = try await request.value }
    }

    @Test
    func `cancellation wins over an expired queued handshake`() async throws {
        let socket = try MissingBridgeSocket()
        defer { socket.removeDirectory() }
        let queue = QueuedBridgeTransport()
        var exchanges = queue.exchanges.makeAsyncIterator()
        let request = Self.handshake(socketPath: socket.path, queue: queue, timeout: 0.02)
        defer { request.cancel() }
        let exchange = try #require(await exchanges.next())
        defer { exchange.start() }

        try await Self.waitUntilExpired(exchange.deadline)
        request.cancel()
        exchange.start()

        await #expect(throws: CancellationError.self) { _ = try await request.value }
    }

    @Test
    func `protocol fallback keeps the first handshake budget while queued`() async throws {
        let peer = try ScriptedBridgePeer(responses: [Self.versionMismatch])
        let queue = QueuedBridgeTransport()
        var exchanges = queue.exchanges.makeAsyncIterator()
        let timeout: TimeInterval = 1
        let request = Self.handshake(socketPath: peer.socketPath, queue: queue, timeout: timeout)
        defer { request.cancel() }
        let first = try #require(await exchanges.next())
        defer { first.start() }
        first.start()
        let fallback = try #require(await exchanges.next())
        defer { fallback.start() }

        // The first exchange was already enqueued after the overall deadline was established.
        // A reset budget on fallback would exceed this bound even if the worker is released much later.
        let originalBudgetUpperBound = first.enqueuedAt.addingTimeInterval(timeout)
        #expect(fallback.deadline <= originalBudgetUpperBound)
        await peer.waitUntilFinished()
        #expect(await peer.acceptedConnectionCount == 1)
        #expect(!FileManager.default.fileExists(atPath: peer.socketPath))
        try await Self.waitUntilExpired(originalBudgetUpperBound)
        fallback.start()

        await #expect(throws: POSIXError(.ETIMEDOUT)) { _ = try await request.value }
    }

    @Test
    func `unexpired protocol fallback preserves the peer refusal`() async throws {
        let refusal = PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "scripted refusal")
        let peer = try ScriptedBridgePeer(responses: [Self.versionMismatch, .error(refusal)])
        let queue = QueuedBridgeTransport()
        var exchanges = queue.exchanges.makeAsyncIterator()
        let request = Self.handshake(socketPath: peer.socketPath, queue: queue, timeout: 60)
        defer { request.cancel() }
        let first = try #require(await exchanges.next())
        defer { first.start() }
        first.start()
        let fallback = try #require(await exchanges.next())
        defer { fallback.start() }
        fallback.start()

        do {
            _ = try await request.value
            Issue.record("Expected the fallback peer refusal")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == refusal.code)
            #expect(error.message == refusal.message)
        }
        await peer.waitUntilFinished()
        #expect(await peer.acceptedConnectionCount == 2)
    }

    private static let versionMismatch = PeekabooBridgeResponse.error(.init(
        code: .versionMismatch,
        message: "scripted version mismatch"))

    private static func handshake(
        socketPath: String,
        queue: QueuedBridgeTransport,
        timeout: TimeInterval) -> Task<PeekabooBridgeHandshakeResponse, any Error>
    {
        let client = PeekabooBridgeClient(
            socketPath: socketPath,
            requestTimeoutSec: timeout,
            trustedHostTeamIDs: nil,
            hostAuthentication: .live,
            enqueueTransport: queue.enqueue)
        return Task {
            defer { queue.finish() }
            return try await client.handshake(
                client: .init(
                    bundleIdentifier: "dev.peekaboo.tests",
                    teamIdentifier: nil,
                    processIdentifier: getpid(),
                    hostname: nil),
                overallTimeoutSec: timeout)
        }
    }

    private static func waitUntilExpired(_ deadline: Date) async throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            try await Task.sleep(for: .seconds(remaining))
        }
    }
}

private final class QueuedBridgeTransport: Sendable {
    let exchanges: AsyncStream<QueuedBridgeExchange>
    private let continuation: AsyncStream<QueuedBridgeExchange>.Continuation

    init() {
        (self.exchanges, self.continuation) = AsyncStream.makeStream()
    }

    func enqueue(deadline: Date, operation: @escaping @Sendable () -> Void) {
        self.continuation.yield(QueuedBridgeExchange(deadline: deadline, operation: operation))
    }

    func finish() {
        self.continuation.finish()
    }
}

private final class QueuedBridgeExchange: @unchecked Sendable {
    let deadline: Date
    let enqueuedAt = Date()
    private let lock = NSLock()
    private var operation: (@Sendable () -> Void)?

    init(deadline: Date, operation: @escaping @Sendable () -> Void) {
        self.deadline = deadline
        self.operation = operation
    }

    func start() {
        let operation = self.lock.withLock {
            defer { self.operation = nil }
            return self.operation
        }
        if let operation {
            DispatchQueue.global(qos: .userInitiated).async(execute: operation)
        }
    }
}

private struct MissingBridgeSocket {
    let directory: URL
    var path: String {
        self.directory.appendingPathComponent("missing.sock").path
    }

    init() throws {
        self.directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("pb-queued-deadline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: false)
    }

    func removeDirectory() {
        try? FileManager.default.removeItem(at: self.directory)
    }
}
