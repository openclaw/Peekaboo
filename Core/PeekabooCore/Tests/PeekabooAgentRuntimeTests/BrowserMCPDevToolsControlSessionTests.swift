import Foundation
import Testing
@testable import PeekabooAgentRuntime

struct BrowserMCPDevToolsControlSessionTests {
    @Test
    func `one explicit connection retains one socket across all read commands`() async throws {
        let transport = FakeControlTransport { command in
            let request = try Self.decodeCommand(command)
            switch request.method {
            case "Browser.getVersion":
                return [
                    .success(Self.json(["method": "Target.targetCreated", "params": [:]])),
                    .success(Self.response(
                        id: request.id,
                        result: ["product": "Chrome/151.0", "protocolVersion": "1.3"])),
                ]
            case "Target.getTargets":
                let filter = request.params["filter"] as? [[String: Any]]
                #expect(filter?.count == 2)
                #expect(filter?.first?["type"] as? String == "page")
                #expect(filter?.first?["exclude"] as? Bool == false)
                #expect(filter?.last?["exclude"] as? Bool == true)
                return [.success(Self.response(
                    id: request.id,
                    result: [
                        "targetInfos": [[
                            "targetId": "target-a",
                            "type": "page",
                            "title": "Example",
                            "url": "https://example.com/",
                        ]],
                    ]))]
            case "Browser.getWindowForTarget":
                #expect(request.params["targetId"] as? String == "target-a")
                return [.success(Self.response(id: request.id, result: ["windowId": 41]))]
            case "Browser.getWindowBounds":
                #expect(request.params["windowId"] as? Int == 41)
                return [.success(Self.response(
                    id: request.id,
                    result: [
                        "bounds": [
                            "left": 12,
                            "top": 34,
                            "width": 1200,
                            "height": 800,
                            "windowState": "normal",
                        ],
                    ]))]
            default:
                Issue.record("Unexpected CDP method \(request.method)")
                return []
            }
        }
        let opener = FakeControlTransportOpener(transport: transport)
        let dispatches = LockedInteger()
        let connection = try await BrowserMCPDevToolsControlSession.connect(
            Self.webSocketURL,
            expectedBrowserID: "browser-a",
            deadline: Self.deadline(seconds: 2),
            onDispatch: { dispatches.increment() },
            transportFactory: opener.factory)

        #expect(connection.version == .init(browserVersion: "Chrome/151.0", protocolVersion: "1.3"))
        let targets = try await connection.session.getTargets(deadline: Self.deadline(seconds: 1))
        #expect(targets == [BrowserMCPDevToolsTargetInfo(
            targetID: "target-a",
            type: "page",
            title: "Example",
            url: "https://example.com/")])
        let windowID = try await connection.session.getWindowForTarget(
            targetID: "target-a",
            deadline: Self.deadline(seconds: 1))
        #expect(windowID == BrowserMCPDevToolsWindowID(rawValue: 41))
        let bounds = try await connection.session.getWindowBounds(
            windowID: windowID,
            deadline: Self.deadline(seconds: 1))
        #expect(bounds == BrowserMCPDevToolsWindowBounds(
            left: 12,
            top: 34,
            width: 1200,
            height: 800,
            state: .normal))
        #expect(await connection.session.state() == .open)
        #expect(opener.openCount == 1)
        #expect(dispatches.value == 1)
        #expect(try transport.sentCommands().map(Self.decodeCommand).map(\.id) == [1, 2, 3, 4])
        #expect(try transport.sentCommands().map(Self.decodeCommand).map(\.method) == [
            "Browser.getVersion",
            "Target.getTargets",
            "Browser.getWindowForTarget",
            "Browser.getWindowBounds",
        ])
        await connection.session.close()
    }

    @Test
    func `valid page inventory larger than legacy 64 KiB remains usable`() async throws {
        let pageCount = 1500
        let transport = FakeControlTransport { command in
            let request = try Self.decodeCommand(command)
            if request.method == "Browser.getVersion" {
                return [.success(Self.response(
                    id: request.id,
                    result: ["product": "Chrome/151.0", "protocolVersion": "1.3"]))]
            }
            let targets = (0..<pageCount).map { index in
                [
                    "targetId": "target-\(index)",
                    "type": "page",
                    "title": "Page \(index)",
                    "url": "https://example.test/page/\(index)?value=abcdefghijklmnopqrstuvwxyz",
                ]
            }
            let response = Self.response(id: request.id, result: ["targetInfos": targets])
            #expect(response.count > 64 * 1024)
            #expect(response.count < 1024 * 1024)
            return [.success(response)]
        }
        let opener = FakeControlTransportOpener(transport: transport)
        let connection = try await self.connect(opener)

        let targets = try await connection.session.getTargets(deadline: Self.deadline(seconds: 2))

        #expect(targets.count == pageCount)
        #expect(await connection.session.state() == .open)
        #expect(opener.openCount == 1)
        await connection.session.close()
    }

    @Test
    func `unexpected response identity kills control without reopening`() async throws {
        let transport = FakeControlTransport { command in
            let request = try Self.decodeCommand(command)
            let id = request.method == "Browser.getVersion" ? request.id : request.id + 100
            let result: [String: Any] = if request.method == "Browser.getVersion" {
                ["product": "Chrome/151.0", "protocolVersion": "1.3"]
            } else {
                ["targetInfos": []]
            }
            return [.success(Self.response(id: id, result: result))]
        }
        let opener = FakeControlTransportOpener(transport: transport)
        let connection = try await self.connect(opener)

        await #expect(throws: BrowserMCPDevToolsControlError.self) {
            _ = try await connection.session.getTargets(deadline: Self.deadline(seconds: 1))
        }
        guard case let .failed(.malformedResponse(reason)) = await connection.session.state() else {
            Issue.record("Expected a terminal response-correlation failure")
            return
        }
        #expect(reason.contains("did not match an outstanding request"))
        await #expect(throws: BrowserMCPDevToolsControlError.self) {
            _ = try await connection.session.getTargets(deadline: Self.deadline(seconds: 1))
        }
        #expect(opener.openCount == 1)
        #expect(transport.sentCommands().count == 2)
    }

    @Test
    func `oversized response kills control at the payload bound`() async throws {
        let transport = FakeControlTransport { command in
            let request = try Self.decodeCommand(command)
            if request.method == "Browser.getVersion" {
                return [.success(Self.response(
                    id: request.id,
                    result: ["product": "Chrome/151.0", "protocolVersion": "1.3"]))]
            }
            return [.success(Data(repeating: 0x20, count: 1024 * 1024 + 1))]
        }
        let opener = FakeControlTransportOpener(transport: transport)
        let connection = try await self.connect(opener)

        await #expect(throws: BrowserMCPDevToolsControlError.self) {
            _ = try await connection.session.getTargets(deadline: Self.deadline(seconds: 1))
        }
        guard case .failed(.malformedResponse) = await connection.session.state() else {
            Issue.record("Expected a terminal payload-bound failure")
            return
        }
        #expect(opener.openCount == 1)
        #expect(transport.cancelCount == 1)
    }

    @Test
    func `request deadline closes retained control instead of leaving a late response`() async throws {
        let transport = FakeControlTransport { command in
            let request = try Self.decodeCommand(command)
            guard request.method == "Browser.getVersion" else { return [] }
            return [.success(Self.response(
                id: request.id,
                result: ["product": "Chrome/151.0", "protocolVersion": "1.3"]))]
        }
        let opener = FakeControlTransportOpener(transport: transport)
        let connection = try await self.connect(opener)

        await #expect(throws: BrowserMCPDevToolsControlError.timedOut(method: "Target.getTargets")) {
            _ = try await connection.session.getTargets(deadline: Self.deadline(milliseconds: 30))
        }
        #expect(await connection.session.state() == .failed(.timedOut(method: "Target.getTargets")))
        #expect(opener.openCount == 1)
        #expect(transport.cancelCount == 1)
    }

    @Test
    func `caller cancellation closes retained control and remains cancellation`() async throws {
        let transport = FakeControlTransport { command in
            let request = try Self.decodeCommand(command)
            guard request.method == "Browser.getVersion" else { return [] }
            return [.success(Self.response(
                id: request.id,
                result: ["product": "Chrome/151.0", "protocolVersion": "1.3"]))]
        }
        let opener = FakeControlTransportOpener(transport: transport)
        let connection = try await self.connect(opener)
        let query = Task {
            try await connection.session.getTargets(deadline: Self.deadline(seconds: 30))
        }
        try await transport.waitForSentCommandCount(2)
        query.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await query.value
        }
        #expect(await connection.session.state() == .failed(.cancelled))
        #expect(opener.openCount == 1)
        #expect(transport.cancelCount == 1)
    }

    @Test
    func `transport death is typed persistent state and never reconnects`() async throws {
        let transport = FakeControlTransport { command in
            let request = try Self.decodeCommand(command)
            guard request.method == "Browser.getVersion" else {
                return [.failure(FakeControlTransportError.connectionLost)]
            }
            return [.success(Self.response(
                id: request.id,
                result: ["product": "Chrome/151.0", "protocolVersion": "1.3"]))]
        }
        let opener = FakeControlTransportOpener(transport: transport)
        let connection = try await self.connect(opener)

        await #expect(throws: BrowserMCPDevToolsControlError.controlDied("fixture connection lost")) {
            _ = try await connection.session.getTargets(deadline: Self.deadline(seconds: 1))
        }
        #expect(await connection.session.state() == .failed(.controlDied("fixture connection lost")))
        await #expect(throws: BrowserMCPDevToolsControlError.controlDied("fixture connection lost")) {
            _ = try await connection.session.getTargets(deadline: Self.deadline(seconds: 1))
        }
        #expect(opener.openCount == 1)
        #expect(transport.sentCommands().count == 2)
    }

    @Test
    func `idle transport death becomes observable without a query or reopen`() async throws {
        let transport = FakeControlTransport.respondingNormally
        let opener = FakeControlTransportOpener(transport: transport)
        let connection = try await self.connect(opener)

        transport.inject(.failure(FakeControlTransportError.connectionLost))
        try await connection.session.waitForState(
            .failed(.controlDied("fixture connection lost")),
            deadline: Self.deadline(seconds: 1))

        #expect(await connection.session.state() == .failed(.controlDied("fixture connection lost")))
        #expect(opener.openCount == 1)
        #expect(transport.sentCommands().count == 1)
    }

    @Test
    func `stale target and window are typed without killing healthy control`() async throws {
        let transport = FakeControlTransport { command in
            let request = try Self.decodeCommand(command)
            switch request.method {
            case "Browser.getVersion":
                return [.success(Self.response(
                    id: request.id,
                    result: ["product": "Chrome/151.0", "protocolVersion": "1.3"]))]
            case "Browser.getWindowForTarget":
                return [.success(Self.errorResponse(
                    id: request.id,
                    code: -32000,
                    message: "No target with given id found"))]
            case "Browser.getWindowBounds":
                return [.success(Self.errorResponse(
                    id: request.id,
                    code: -32000,
                    message: "Browser window not found"))]
            case "Target.getTargets":
                return [.success(Self.response(id: request.id, result: ["targetInfos": []]))]
            default:
                return []
            }
        }
        let opener = FakeControlTransportOpener(transport: transport)
        let connection = try await self.connect(opener)

        await #expect(throws: BrowserMCPDevToolsControlError.staleTarget("gone")) {
            _ = try await connection.session.getWindowForTarget(
                targetID: "gone",
                deadline: Self.deadline(seconds: 1))
        }
        let windowID = BrowserMCPDevToolsWindowID(rawValue: 99)
        await #expect(throws: BrowserMCPDevToolsControlError.staleWindow(windowID)) {
            _ = try await connection.session.getWindowBounds(
                windowID: windowID,
                deadline: Self.deadline(seconds: 1))
        }
        #expect(try await connection.session.getTargets(deadline: Self.deadline(seconds: 1)).isEmpty)
        #expect(await connection.session.state() == .open)
        #expect(opener.openCount == 1)
        #expect(transport.cancelCount == 0)
        await connection.session.close()
    }

    @Test
    func `explicit close is observable and refuses commands without reopening`() async throws {
        let transport = FakeControlTransport.respondingNormally
        let opener = FakeControlTransportOpener(transport: transport)
        let connection = try await self.connect(opener)

        await connection.session.close()
        #expect(await connection.session.state() == .closed)
        await #expect(throws: BrowserMCPDevToolsControlError.closed) {
            _ = try await connection.session.getTargets(deadline: Self.deadline(seconds: 1))
        }
        #expect(opener.openCount == 1)
        #expect(transport.sentCommands().count == 1)
        #expect(transport.cancelCount == 1)
    }

    @Test
    func `invalid endpoint is rejected before transport open`() async throws {
        let transport = FakeControlTransport.respondingNormally
        let opener = FakeControlTransportOpener(transport: transport)
        let wrongURL = try #require(URL(string: "ws://127.0.0.1:9222/devtools/browser/browser-b"))

        await #expect(throws: BrowserMCPDevToolsControlError.invalidEndpoint(
            "expected the exact published loopback browser identity"))
        {
            _ = try await BrowserMCPDevToolsControlSession.connect(
                wrongURL,
                expectedBrowserID: "browser-a",
                deadline: Self.deadline(seconds: 1),
                transportFactory: opener.factory)
        }
        #expect(opener.openCount == 0)
        #expect(transport.sentCommands().isEmpty)
    }

    private func connect(_ opener: FakeControlTransportOpener) async throws
        -> BrowserMCPDevToolsControlConnection
    {
        try await BrowserMCPDevToolsControlSession.connect(
            Self.webSocketURL,
            expectedBrowserID: "browser-a",
            deadline: Self.deadline(seconds: 2),
            transportFactory: opener.factory)
    }

    static let webSocketURL = URL(
        string: "ws://127.0.0.1:9222/devtools/browser/browser-a")!

    static func response(id: Int, result: [String: Any]) -> Data {
        self.json(["id": id, "result": result])
    }

    static func errorResponse(id: Int, code: Int, message: String) -> Data {
        self.json(["id": id, "error": ["code": code, "message": message]])
    }

    static func json(_ object: [String: Any]) -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            preconditionFailure("Invalid fixture JSON: \(error)")
        }
    }

    static func decodeCommand(_ data: Data) throws -> DecodedControlCommand {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try DecodedControlCommand(
            id: #require(object["id"] as? Int),
            method: #require(object["method"] as? String),
            params: #require(object["params"] as? [String: Any]))
    }

    private static func deadline(seconds: TimeInterval) -> ContinuousClock.Instant {
        ContinuousClock.now.advanced(by: .seconds(seconds))
    }

    private static func deadline(milliseconds: Int) -> ContinuousClock.Instant {
        ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
    }
}

extension BrowserMCPDevToolsControlSession {
    fileprivate func waitForState(
        _ expected: BrowserMCPDevToolsControlState,
        deadline: ContinuousClock.Instant) async throws
    {
        while self.state() != expected {
            guard ContinuousClock.now < deadline else {
                throw FakeControlTransportWaitError.timedOut
            }
            await Task.yield()
        }
    }
}

struct DecodedControlCommand {
    let id: Int
    let method: String
    let params: [String: Any]
}

enum FakeControlTransportError: LocalizedError {
    case connectionLost

    var errorDescription: String? {
        "fixture connection lost"
    }
}

final class FakeControlTransport: BrowserMCPDevToolsControlTransport, @unchecked Sendable {
    typealias Handler = @Sendable (Data) throws -> [Result<Data, any Error>]

    private struct State {
        var sent: [Data] = []
        var queued: [Result<Data, any Error>] = []
        var waiter: CheckedContinuation<Data, any Error>?
        var cancelled = false
        var cancelCount = 0
    }

    private let lock = NSLock()
    private let handler: Handler
    private var state = State()

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    static var respondingNormally: FakeControlTransport {
        FakeControlTransport { command in
            let request = try BrowserMCPDevToolsControlSessionTests.decodeCommand(command)
            guard request.method == "Browser.getVersion" else {
                return [.success(BrowserMCPDevToolsControlSessionTests.response(
                    id: request.id,
                    result: ["targetInfos": []]))]
            }
            return [.success(BrowserMCPDevToolsControlSessionTests.response(
                id: request.id,
                result: ["product": "Chrome/151.0", "protocolVersion": "1.3"]))]
        }
    }

    var cancelCount: Int {
        self.lock.withLock { self.state.cancelCount }
    }

    func sentCommands() -> [Data] {
        self.lock.withLock { self.state.sent }
    }

    func send(_ data: Data) async throws {
        let isCancelled = self.lock.withLock {
            self.state.sent.append(data)
            return self.state.cancelled
        }
        guard !isCancelled else { throw CancellationError() }
        for result in try self.handler(data) {
            self.enqueue(result)
        }
    }

    func receive(maximumPayloadBytes _: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<Data, any Error>? = self.lock.withLock {
                if self.state.cancelled {
                    return .failure(CancellationError())
                }
                if !self.state.queued.isEmpty {
                    return self.state.queued.removeFirst()
                }
                precondition(self.state.waiter == nil, "The control session must have one receive loop")
                self.state.waiter = continuation
                return nil
            }
            if let immediate {
                continuation.resume(with: immediate)
            }
        }
    }

    func cancel() {
        let waiter: CheckedContinuation<Data, any Error>? = self.lock.withLock {
            guard !self.state.cancelled else { return nil }
            self.state.cancelled = true
            self.state.cancelCount += 1
            let waiter = self.state.waiter
            self.state.waiter = nil
            return waiter
        }
        waiter?.resume(throwing: CancellationError())
    }

    func waitForSentCommandCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while self.sentCommands().count < count {
            guard ContinuousClock.now < deadline else {
                throw FakeControlTransportWaitError.timedOut
            }
            await Task.yield()
        }
    }

    func inject(_ result: Result<Data, any Error>) {
        self.enqueue(result)
    }

    private func enqueue(_ result: Result<Data, any Error>) {
        let waiter: CheckedContinuation<Data, any Error>? = self.lock.withLock {
            guard !self.state.cancelled else { return nil }
            guard let waiter = self.state.waiter else {
                self.state.queued.append(result)
                return nil
            }
            self.state.waiter = nil
            return waiter
        }
        waiter?.resume(with: result)
    }
}

private enum FakeControlTransportWaitError: Error {
    case timedOut
}

final class FakeControlTransportOpener: @unchecked Sendable {
    private let lock = NSLock()
    private let transport: FakeControlTransport
    private var count = 0

    init(transport: FakeControlTransport) {
        self.transport = transport
    }

    var openCount: Int {
        self.lock.withLock { self.count }
    }

    var factory: BrowserMCPDevToolsControlTransportFactory {
        BrowserMCPDevToolsControlTransportFactory { [self] request, onDispatch in
            #expect(request.url == BrowserMCPDevToolsControlSessionTests.webSocketURL)
            self.lock.withLock { self.count += 1 }
            onDispatch()
            return self.transport
        }
    }
}

private final class LockedInteger: @unchecked Sendable {
    private let lock = NSLock()
    private var integer = 0

    var value: Int {
        self.lock.withLock { self.integer }
    }

    func increment() {
        self.lock.withLock { self.integer += 1 }
    }
}
