import Foundation
import Testing
@testable import PeekabooAgentRuntime

struct BrowserMCPDevToolsWebSocketProberTests {
    @Test
    func `approval wait keeps one exact exchange pending until Chrome responds`() async throws {
        let barrier = WebSocketProbeBarrier()
        let completed = SynchronizedCounter()
        let exchanges = SynchronizedCounter()

        let probe = Task {
            defer { completed.increment() }
            return try await BrowserMCPDevToolsWebSocketProber.probeVersion(
                Self.webSocketURL,
                expectedBrowserID: "browser-a",
                deadline: Self.deadline(seconds: 2),
                exchange: { request, command, requestID, onDispatch in
                    onDispatch()
                    exchanges.increment()
                    #expect(request.url == Self.webSocketURL)
                    #expect(command == #"{"id":1,"method":"Browser.getVersion"}"#)
                    #expect(requestID == 1)
                    await barrier.block()
                    return Self.successResponse()
                })
        }

        await barrier.waitUntilBlocked()
        #expect(completed.value == 0)
        #expect(exchanges.value == 1)
        await barrier.release()

        let version = try await probe.value
        #expect(version == .init(browserVersion: "Chrome/151.0", protocolVersion: "1.3"))
        #expect(completed.value == 1)
        #expect(exchanges.value == 1)
    }

    @Test
    func `WebSocket refusal does not fall back or retry`() async {
        let exchanges = SynchronizedCounter()

        await #expect(throws: BrowserMCPDevToolsWebSocketProbeFailure.failed(.connectionRefused("HTTP 403"))) {
            _ = try await BrowserMCPDevToolsWebSocketProber.probeVersion(
                Self.webSocketURL,
                expectedBrowserID: "browser-a",
                deadline: Self.deadline(seconds: 1),
                exchange: { _, _, _, onDispatch in
                    onDispatch()
                    exchanges.increment()
                    throw WebSocketProbeFixtureError.forbidden
                })
        }
        #expect(exchanges.value == 1)
    }

    @Test
    func `approval timeout cancels the pending exchange exactly once`() async {
        let cancellations = SynchronizedCounter()

        await #expect(throws: BrowserMCPDevToolsWebSocketProbeFailure.failed(.timedOut)) {
            _ = try await BrowserMCPDevToolsWebSocketProber.probeVersion(
                Self.webSocketURL,
                expectedBrowserID: "browser-a",
                deadline: Self.deadline(milliseconds: 20),
                exchange: { _, _, _, onDispatch in
                    onDispatch()
                    do {
                        try await Task.sleep(for: .seconds(30))
                        return Self.successResponse()
                    } catch is CancellationError {
                        cancellations.increment()
                        throw CancellationError()
                    }
                })
        }
        #expect(cancellations.value == 1)
    }

    @Test
    func `caller cancellation remains cancellation and closes the pending exchange`() async throws {
        let barrier = WebSocketProbeBarrier()
        let cancellations = SynchronizedCounter()
        let probe = Task {
            try await BrowserMCPDevToolsWebSocketProber.probeVersion(
                Self.webSocketURL,
                expectedBrowserID: "browser-a",
                deadline: Self.deadline(seconds: 30),
                exchange: { _, _, _, onDispatch in
                    onDispatch()
                    await barrier.noteBlocked()
                    do {
                        try await Task.sleep(for: .seconds(30))
                        return Self.successResponse()
                    } catch is CancellationError {
                        cancellations.increment()
                        throw CancellationError()
                    }
                })
        }

        await barrier.waitUntilBlocked()
        probe.cancel()
        do {
            _ = try await probe.value
            Issue.record("Expected caller cancellation")
        } catch BrowserMCPDevToolsWebSocketProbeFailure.cancelled {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(cancellations.value == 1)
    }

    @Test
    func `cancellation before WebSocket resume stays pre dispatch`() async {
        let dispatches = SynchronizedCounter()
        let probe = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BrowserMCPDevToolsWebSocketProber.probeVersion(
                Self.webSocketURL,
                expectedBrowserID: "browser-a",
                deadline: Self.deadline(seconds: 30),
                onDispatch: { dispatches.increment() },
                exchange: { _, _, _, onDispatch in
                    try Task.checkCancellation()
                    onDispatch()
                    return Self.successResponse()
                })
        }

        await #expect(throws: CancellationError.self) {
            _ = try await probe.value
        }
        #expect(dispatches.value == 0)
    }

    @Test
    func `malformed Browser getVersion responses fail closed`() async {
        let malformedResponses = [
            Data("not-json".utf8),
            Data(#"{"id":2,"result":{"product":"Chrome/151.0","protocolVersion":"1.3"}}"#.utf8),
            Data(#"{"id":1,"result":{"protocolVersion":"1.3"}}"#.utf8),
            Data(#"{"id":1,"result":{"product":"Chrome/151.0"}}"#.utf8),
            Data(#"{"id":1,"result":{"product":"Chromium/151.0","protocolVersion":"1.3"}}"#.utf8),
        ]

        for response in malformedResponses {
            do {
                _ = try await BrowserMCPDevToolsWebSocketProber.probeVersion(
                    Self.webSocketURL,
                    expectedBrowserID: "browser-a",
                    deadline: Self.deadline(seconds: 1),
                    exchange: { _, _, _, onDispatch in
                        onDispatch()
                        return response
                    })
                Issue.record("Expected malformed CDP to be refused")
            } catch is BrowserMCPDevToolsWebSocketProbeFailure {
                // Expected.
            } catch {
                Issue.record("Expected a typed WebSocket probe error, got \(error)")
            }
        }
    }

    @Test
    func `CDP error response is a typed refusal`() async {
        await #expect(throws: BrowserMCPDevToolsWebSocketProbeFailure.failed(.connectionRefused("denied"))) {
            _ = try await BrowserMCPDevToolsWebSocketProber.probeVersion(
                Self.webSocketURL,
                expectedBrowserID: "browser-a",
                deadline: Self.deadline(seconds: 1),
                exchange: { _, _, _, onDispatch in
                    onDispatch()
                    return Data(#"{"id":1,"error":{"code":-32000,"message":"denied"}}"#.utf8)
                })
        }
    }

    @Test
    func `probe refuses any WebSocket other than the exact published loopback identity`() async throws {
        let exchanges = SynchronizedCounter()
        let wrongURL = try #require(URL(string: "ws://127.0.0.1:9222/devtools/browser/browser-b"))

        await #expect(throws: BrowserMCPDevToolsWebSocketProbeError.self) {
            _ = try await BrowserMCPDevToolsWebSocketProber.probeVersion(
                wrongURL,
                expectedBrowserID: "browser-a",
                deadline: Self.deadline(seconds: 1),
                exchange: { _, _, _, _ in
                    exchanges.increment()
                    return Self.successResponse()
                })
        }
        #expect(exchanges.value == 0)
    }

    private static let webSocketURL = URL(
        string: "ws://127.0.0.1:9222/devtools/browser/browser-a")!

    private static func successResponse() -> Data {
        Data(#"{"id":1,"result":{"product":"Chrome/151.0","protocolVersion":"1.3"}}"#.utf8)
    }

    private static func deadline(seconds: TimeInterval) -> ContinuousClock.Instant {
        ContinuousClock.now.advanced(by: .seconds(seconds))
    }

    private static func deadline(milliseconds: Int) -> ContinuousClock.Instant {
        ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
    }
}

private enum WebSocketProbeFixtureError: LocalizedError {
    case forbidden

    var errorDescription: String? {
        "HTTP 403"
    }
}

private final class SynchronizedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}

private actor WebSocketProbeBarrier {
    private var isBlocked = false
    private var isReleased = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func noteBlocked() {
        self.isBlocked = true
        let waiters = self.blockedWaiters
        self.blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func block() async {
        self.noteBlocked()
        guard !self.isReleased else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard !self.isBlocked else { return }
        await withCheckedContinuation { continuation in
            self.blockedWaiters.append(continuation)
        }
    }

    func release() {
        self.isReleased = true
        let waiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
