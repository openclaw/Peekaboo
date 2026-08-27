import Foundation

struct BrowserMCPDevToolsTargetInfo: Sendable, Equatable {
    let targetID: String
    let type: String
    let title: String
    let url: String
}

struct BrowserMCPDevToolsWindowID: RawRepresentable, Sendable, Equatable, Hashable {
    let rawValue: Int
}

enum BrowserMCPDevToolsWindowState: String, Sendable, Equatable {
    case normal
    case minimized
    case maximized
    case fullscreen
}

struct BrowserMCPDevToolsWindowBounds: Sendable, Equatable {
    let left: Int?
    let top: Int?
    let width: Int?
    let height: Int?
    let state: BrowserMCPDevToolsWindowState
}

enum BrowserMCPDevToolsControlError: LocalizedError, Sendable, Equatable {
    case invalidEndpoint(String)
    case cancelled
    case timedOut(method: String)
    case closed
    case controlDied(String)
    case malformedResponse(String)
    case cdpError(method: String, code: Int?, message: String)
    case staleTarget(String)
    case staleWindow(BrowserMCPDevToolsWindowID)

    var errorDescription: String? {
        switch self {
        case let .invalidEndpoint(reason):
            "the DevTools control WebSocket endpoint was invalid: \(reason)"
        case .cancelled:
            "the retained DevTools control session was cancelled"
        case let .timedOut(method):
            "the retained DevTools control session did not complete \(method) before its deadline"
        case .closed:
            "the retained DevTools control session is closed"
        case let .controlDied(reason):
            "the retained DevTools control WebSocket died: \(reason)"
        case let .malformedResponse(reason):
            "the retained DevTools control WebSocket returned an invalid response: \(reason)"
        case let .cdpError(method, code, message):
            if let code {
                "Chrome rejected \(method) with CDP error \(code): \(message)"
            } else {
                "Chrome rejected \(method): \(message)"
            }
        case let .staleTarget(targetID):
            "the DevTools target is stale: \(targetID)"
        case let .staleWindow(windowID):
            "the DevTools browser window is stale: \(windowID.rawValue)"
        }
    }
}

enum BrowserMCPDevToolsControlState: Sendable, Equatable {
    case open
    case closed
    case failed(BrowserMCPDevToolsControlError)
}

struct BrowserMCPDevToolsControlConnection: Sendable {
    let session: BrowserMCPDevToolsControlSession
    let version: BrowserMCPDevToolsVersion
}

protocol BrowserMCPDevToolsControlTransport: Sendable {
    func send(_ data: Data) async throws
    func receive(maximumPayloadBytes: Int) async throws -> Data
    func cancel()
}

struct BrowserMCPDevToolsControlTransportFactory: Sendable {
    typealias Open = @Sendable (
        URLRequest,
        @escaping @Sendable () -> Void) async throws -> any BrowserMCPDevToolsControlTransport

    let open: Open

    static let live = BrowserMCPDevToolsControlTransportFactory { request, onDispatch in
        let task = BrowserMCPNoRedirectURLSession.shared.webSocketTask(with: request)
        let transport = BrowserMCPURLSessionControlTransport(task: task)
        try Task.checkCancellation()
        onDispatch()
        task.resume()
        return transport
    }
}

actor BrowserMCPDevToolsControlSession {
    private static let maximumRequestPayloadBytes = 64 * 1024
    private static let maximumResponsePayloadBytes = 1024 * 1024
    private static let maximumTargetCount = 4096
    private static let maximumTargetIDBytes = 1024
    private static let approvalTimeout: Duration = .seconds(60)

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, any Error>
        var timeoutTask: Task<Void, Never>?
    }

    private struct Request {
        let id: Int
        let method: String
        let payload: Data
        let deadline: ContinuousClock.Instant
    }

    private struct MessageHeader: Decodable {
        let id: Int?
        let method: String?
    }

    private struct Command<Parameters: Encodable>: Encodable {
        let id: Int
        let method: String
        let params: Parameters
    }

    private struct EmptyParameters: Encodable {}

    private struct TargetFilterEntry: Encodable {
        let type: String?
        let exclude: Bool
    }

    private struct TargetsParameters: Encodable {
        let filter = [
            TargetFilterEntry(type: "page", exclude: false),
            TargetFilterEntry(type: nil, exclude: true),
        ]
    }

    private struct TargetParameters: Encodable {
        let targetId: String
    }

    private struct WindowParameters: Encodable {
        let windowId: Int
    }

    private struct ResponseEnvelope<Result: Decodable>: Decodable {
        let id: Int
        let result: Result?
        let error: ResponseError?
    }

    private struct ResponseError: Decodable {
        let code: Int?
        let message: String
    }

    private struct VersionResult: Decodable {
        let product: String
        let protocolVersion: String
    }

    private struct TargetsResult: Decodable {
        let targetInfos: [TargetInfo]
    }

    private struct TargetInfo: Decodable {
        let targetId: String
        let type: String
        let title: String
        let url: String
    }

    private struct WindowResult: Decodable {
        let windowId: Int
    }

    private struct BoundsResult: Decodable {
        let bounds: Bounds
    }

    private struct Bounds: Decodable {
        let left: Int?
        let top: Int?
        let width: Int?
        let height: Int?
        let windowState: String
    }

    private let transport: any BrowserMCPDevToolsControlTransport
    private var controlState: BrowserMCPDevToolsControlState = .open
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var receiveTask: Task<Void, Never>?

    private init(transport: any BrowserMCPDevToolsControlTransport) {
        self.transport = transport
    }

    deinit {
        self.transport.cancel()
    }

    static func connect(
        _ webSocketURL: URL,
        expectedBrowserID: String,
        deadline: ContinuousClock.Instant,
        onDispatch: @escaping @Sendable () -> Void = {},
        transportFactory: BrowserMCPDevToolsControlTransportFactory = .live) async throws
        -> BrowserMCPDevToolsControlConnection
    {
        try self.validate(webSocketURL, expectedBrowserID: expectedBrowserID)
        try Task.checkCancellation()
        let approvalDeadline = min(
            deadline,
            ContinuousClock.now.advanced(by: Self.approvalTimeout))
        let remaining = ContinuousClock.now.duration(to: approvalDeadline)
        guard remaining > .zero else {
            throw BrowserMCPDevToolsControlError.timedOut(method: "Browser.getVersion")
        }

        var request = URLRequest(url: webSocketURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = self.timeInterval(remaining)
        let dispatchMarker = BrowserMCPDevToolsControlDispatchMarker(onDispatch: onDispatch)
        let transport: any BrowserMCPDevToolsControlTransport
        do {
            transport = try await transportFactory.open(request, dispatchMarker.markDispatched)
        } catch is CancellationError {
            if dispatchMarker.didDispatch {
                throw BrowserMCPDevToolsControlError.cancelled
            }
            throw CancellationError()
        } catch {
            if dispatchMarker.didDispatch {
                throw BrowserMCPDevToolsControlError.controlDied(error.localizedDescription)
            }
            throw error
        }

        let session = BrowserMCPDevToolsControlSession(transport: transport)
        await session.startReceiving()
        do {
            let version = try await session.getVersion(deadline: approvalDeadline)
            return BrowserMCPDevToolsControlConnection(session: session, version: version)
        } catch is CancellationError {
            await session.fail(.cancelled, pendingError: CancellationError())
            throw BrowserMCPDevToolsControlError.cancelled
        } catch {
            await session.closeAfterFailedConnect()
            throw error
        }
    }

    func state() -> BrowserMCPDevToolsControlState {
        self.controlState
    }

    func close() {
        self.terminate(state: .closed, pendingError: BrowserMCPDevToolsControlError.closed)
    }

    func getTargets(deadline: ContinuousClock.Instant) async throws -> [BrowserMCPDevToolsTargetInfo] {
        let request = try self.makeRequest(
            method: "Target.getTargets",
            parameters: TargetsParameters(),
            deadline: deadline)
        let result: TargetsResult = try await self.perform(request)
        guard result.targetInfos.count <= Self.maximumTargetCount else {
            throw self.malformedResponse(
                "Target.getTargets exceeded the bounded page-target inventory")
        }
        var targetIDs = Set<String>()
        return try result.targetInfos.map { target in
            guard !target.targetId.isEmpty,
                  target.targetId.utf8.count <= Self.maximumTargetIDBytes,
                  !target.type.isEmpty,
                  targetIDs.insert(target.targetId).inserted
            else {
                throw self.malformedResponse(
                    "Target.getTargets returned an empty, oversized, or duplicate target identity")
            }
            return BrowserMCPDevToolsTargetInfo(
                targetID: target.targetId,
                type: target.type,
                title: target.title,
                url: target.url)
        }
    }

    func getWindowForTarget(
        targetID: String,
        deadline: ContinuousClock.Instant) async throws -> BrowserMCPDevToolsWindowID
    {
        guard !targetID.isEmpty, targetID.utf8.count <= Self.maximumTargetIDBytes else {
            throw BrowserMCPDevToolsControlError.staleTarget(targetID)
        }
        let request = try self.makeRequest(
            method: "Browser.getWindowForTarget",
            parameters: TargetParameters(targetId: targetID),
            deadline: deadline)
        do {
            let result: WindowResult = try await self.perform(request)
            guard result.windowId >= 0 else {
                throw self.malformedResponse(
                    "Browser.getWindowForTarget returned a negative window identity")
            }
            return BrowserMCPDevToolsWindowID(rawValue: result.windowId)
        } catch let error as BrowserMCPDevToolsControlError where Self.isStaleTargetError(error) {
            throw BrowserMCPDevToolsControlError.staleTarget(targetID)
        }
    }

    func getWindowBounds(
        windowID: BrowserMCPDevToolsWindowID,
        deadline: ContinuousClock.Instant) async throws -> BrowserMCPDevToolsWindowBounds
    {
        guard windowID.rawValue >= 0 else {
            throw BrowserMCPDevToolsControlError.staleWindow(windowID)
        }
        let request = try self.makeRequest(
            method: "Browser.getWindowBounds",
            parameters: WindowParameters(windowId: windowID.rawValue),
            deadline: deadline)
        do {
            let result: BoundsResult = try await self.perform(request)
            guard let state = BrowserMCPDevToolsWindowState(rawValue: result.bounds.windowState),
                  result.bounds.width.map({ $0 >= 0 }) ?? true,
                  result.bounds.height.map({ $0 >= 0 }) ?? true
            else {
                throw self.malformedResponse(
                    "Browser.getWindowBounds returned an invalid bounds record")
            }
            return BrowserMCPDevToolsWindowBounds(
                left: result.bounds.left,
                top: result.bounds.top,
                width: result.bounds.width,
                height: result.bounds.height,
                state: state)
        } catch let error as BrowserMCPDevToolsControlError where Self.isStaleWindowError(error) {
            throw BrowserMCPDevToolsControlError.staleWindow(windowID)
        }
    }

    private func getVersion(deadline: ContinuousClock.Instant) async throws -> BrowserMCPDevToolsVersion {
        let request = try self.makeRequest(
            method: "Browser.getVersion",
            parameters: EmptyParameters(),
            deadline: deadline)
        let result: VersionResult = try await self.perform(request)
        guard result.product.hasPrefix("Chrome/"),
              result.product.count > "Chrome/".count,
              !result.protocolVersion.isEmpty
        else {
            throw self.malformedResponse(
                "Browser.getVersion omitted the Chrome product or protocol version")
        }
        return BrowserMCPDevToolsVersion(
            browserVersion: result.product,
            protocolVersion: result.protocolVersion)
    }

    private func startReceiving() {
        guard self.receiveTask == nil, self.controlState == .open else { return }
        let transport = self.transport
        self.receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let data = try await transport.receive(maximumPayloadBytes: Self.maximumResponsePayloadBytes)
                    guard let self else { return }
                    await self.receive(data)
                } catch is CancellationError {
                    guard let self else { return }
                    await self.transportEnded("the WebSocket closed")
                    return
                } catch let error as BrowserMCPDevToolsControlError {
                    guard let self else { return }
                    await self.transportFailed(error)
                    return
                } catch {
                    guard let self else { return }
                    await self.transportEnded(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func makeRequest(
        method: String,
        parameters: some Encodable,
        deadline: ContinuousClock.Instant) throws -> Request
    {
        try self.requireOpen()
        guard ContinuousClock.now < deadline else {
            throw BrowserMCPDevToolsControlError.timedOut(method: method)
        }
        let id = self.nextRequestID
        guard id < Int.max else {
            self.terminate(
                state: .failed(.malformedResponse("the CDP request identity space was exhausted")),
                pendingError: BrowserMCPDevToolsControlError.malformedResponse(
                    "the CDP request identity space was exhausted"))
            throw BrowserMCPDevToolsControlError.malformedResponse(
                "the CDP request identity space was exhausted")
        }
        self.nextRequestID += 1
        let payload = try JSONEncoder().encode(Command(id: id, method: method, params: parameters))
        guard payload.count <= Self.maximumRequestPayloadBytes else {
            throw BrowserMCPDevToolsControlError.malformedResponse(
                "the \(method) request exceeded 64 KiB")
        }
        return Request(id: id, method: method, payload: payload, deadline: deadline)
    }

    private func perform<Result: Decodable>(_ request: Request) async throws -> Result {
        let data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await self.awaitResponse(to: request)
        } onCancel: { [weak self] in
            Task {
                await self?.fail(.cancelled, pendingError: CancellationError())
            }
        }
        try Task.checkCancellation()
        let response: ResponseEnvelope<Result>
        do {
            response = try JSONDecoder().decode(ResponseEnvelope<Result>.self, from: data)
        } catch {
            let failure = BrowserMCPDevToolsControlError.malformedResponse(
                "\(request.method) returned a response with the wrong shape")
            self.terminate(state: .failed(failure), pendingError: failure)
            throw failure
        }
        guard response.id == request.id else {
            let failure = BrowserMCPDevToolsControlError.malformedResponse(
                "\(request.method) returned the wrong response identity")
            self.terminate(state: .failed(failure), pendingError: failure)
            throw failure
        }
        if let error = response.error {
            guard response.result == nil else {
                let failure = BrowserMCPDevToolsControlError.malformedResponse(
                    "\(request.method) returned both result and error")
                self.terminate(state: .failed(failure), pendingError: failure)
                throw failure
            }
            throw BrowserMCPDevToolsControlError.cdpError(
                method: request.method,
                code: error.code,
                message: error.message)
        }
        guard let result = response.result else {
            let failure = BrowserMCPDevToolsControlError.malformedResponse(
                "\(request.method) returned neither result nor error")
            self.terminate(state: .failed(failure), pendingError: failure)
            throw failure
        }
        return result
    }

    private func awaitResponse(to request: Request) async throws -> Data {
        try self.requireOpen()
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingRequests[request.id] = PendingRequest(
                continuation: continuation)
            let remaining = ContinuousClock.now.duration(to: request.deadline)
            let timeoutTask = Task { [weak self] in
                if remaining > .zero {
                    try? await Task.sleep(for: remaining)
                }
                guard !Task.isCancelled else { return }
                await self?.requestTimedOut(id: request.id, method: request.method)
            }
            self.pendingRequests[request.id]?.timeoutTask = timeoutTask
            Task { [weak self] in
                do {
                    try await self?.transport.send(request.payload)
                } catch is CancellationError {
                    await self?.sendFailed(id: request.id, reason: "the WebSocket send was cancelled")
                } catch {
                    await self?.sendFailed(id: request.id, reason: error.localizedDescription)
                }
            }
        }
    }

    private func receive(_ data: Data) {
        guard self.controlState == .open else { return }
        guard data.count <= Self.maximumResponsePayloadBytes else {
            let failure = BrowserMCPDevToolsControlError.malformedResponse(
                "a WebSocket payload exceeded 1 MiB")
            self.terminate(state: .failed(failure), pendingError: failure)
            return
        }
        let header: MessageHeader
        do {
            header = try JSONDecoder().decode(MessageHeader.self, from: data)
        } catch {
            let failure = BrowserMCPDevToolsControlError.malformedResponse(
                "a WebSocket payload was not a CDP response or event")
            self.terminate(state: .failed(failure), pendingError: failure)
            return
        }
        if let id = header.id {
            guard header.method == nil else {
                let failure = BrowserMCPDevToolsControlError.malformedResponse(
                    "a CDP response also claimed to be an event")
                self.terminate(state: .failed(failure), pendingError: failure)
                return
            }
            guard var pending = self.pendingRequests.removeValue(forKey: id) else {
                let failure = BrowserMCPDevToolsControlError.malformedResponse(
                    "response ID \(id) did not match an outstanding request")
                self.terminate(state: .failed(failure), pendingError: failure)
                return
            }
            pending.timeoutTask?.cancel()
            pending.timeoutTask = nil
            pending.continuation.resume(returning: data)
            return
        }
        guard let method = header.method, !method.isEmpty else {
            let failure = BrowserMCPDevToolsControlError.malformedResponse(
                "an unsolicited WebSocket payload had no CDP event method")
            self.terminate(state: .failed(failure), pendingError: failure)
            return
        }
    }

    private func requestTimedOut(id: Int, method: String) {
        guard self.pendingRequests[id] != nil else { return }
        let failure = BrowserMCPDevToolsControlError.timedOut(method: method)
        self.terminate(state: .failed(failure), pendingError: failure)
    }

    private func sendFailed(id: Int, reason: String) {
        guard self.pendingRequests[id] != nil else { return }
        let failure = BrowserMCPDevToolsControlError.controlDied(reason)
        self.terminate(state: .failed(failure), pendingError: failure)
    }

    private func transportEnded(_ reason: String) {
        guard self.controlState == .open else { return }
        let failure = BrowserMCPDevToolsControlError.controlDied(reason)
        self.terminate(state: .failed(failure), pendingError: failure)
    }

    private func transportFailed(_ failure: BrowserMCPDevToolsControlError) {
        guard self.controlState == .open else { return }
        self.terminate(state: .failed(failure), pendingError: failure)
    }

    private func closeAfterFailedConnect() {
        guard self.controlState == .open else { return }
        self.terminate(state: .closed, pendingError: BrowserMCPDevToolsControlError.closed)
    }

    private func fail(
        _ failure: BrowserMCPDevToolsControlError,
        pendingError: any Error)
    {
        self.terminate(state: .failed(failure), pendingError: pendingError)
    }

    private func terminate(
        state: BrowserMCPDevToolsControlState,
        pendingError: any Error)
    {
        guard self.controlState == .open else { return }
        self.controlState = state
        self.receiveTask?.cancel()
        self.receiveTask = nil
        self.transport.cancel()
        let pending = self.pendingRequests.values
        self.pendingRequests.removeAll()
        for var request in pending {
            request.timeoutTask?.cancel()
            request.timeoutTask = nil
            request.continuation.resume(throwing: pendingError)
        }
    }

    private func requireOpen() throws {
        switch self.controlState {
        case .open:
            return
        case .closed:
            throw BrowserMCPDevToolsControlError.closed
        case let .failed(error):
            throw error
        }
    }

    private func malformedResponse(_ reason: String) -> BrowserMCPDevToolsControlError {
        let failure = BrowserMCPDevToolsControlError.malformedResponse(reason)
        self.terminate(state: .failed(failure), pendingError: failure)
        return failure
    }

    private nonisolated static func isStaleTargetError(_ error: BrowserMCPDevToolsControlError) -> Bool {
        guard case let .cdpError(method, _, message) = error,
              method == "Browser.getWindowForTarget"
        else { return false }
        let normalized = message.lowercased()
        return normalized.contains("no target") ||
            normalized.contains("target not found") ||
            normalized.contains("web contents")
    }

    private nonisolated static func isStaleWindowError(_ error: BrowserMCPDevToolsControlError) -> Bool {
        guard case let .cdpError(method, _, message) = error,
              method == "Browser.getWindowBounds"
        else { return false }
        let normalized = message.lowercased()
        return normalized.contains("window") &&
            (normalized.contains("not found") || normalized.contains("no browser"))
    }

    private nonisolated static func validate(_ url: URL, expectedBrowserID: String) throws {
        guard !expectedBrowserID.isEmpty,
              url.scheme == "ws",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              let host = url.host,
              BrowserMCPDevToolsWebSocketProber.isLoopbackHost(host),
              url.port != nil,
              url.path == "/devtools/browser/\(expectedBrowserID)"
        else {
            throw BrowserMCPDevToolsControlError.invalidEndpoint(
                "expected the exact published loopback browser identity")
        }
    }

    private nonisolated static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

private final class BrowserMCPURLSessionControlTransport: BrowserMCPDevToolsControlTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    deinit {
        self.cancel()
    }

    func send(_ data: Data) async throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw BrowserMCPDevToolsControlError.malformedResponse(
                "a CDP command could not be encoded as UTF-8")
        }
        try await self.task.send(.string(text))
    }

    func receive(maximumPayloadBytes: Int) async throws -> Data {
        let message = try await self.task.receive()
        let data = switch message {
        case let .data(data): data
        case let .string(string): Data(string.utf8)
        @unknown default:
            throw BrowserMCPDevToolsControlError.malformedResponse(
                "Chrome returned an unsupported WebSocket message")
        }
        guard data.count <= maximumPayloadBytes else {
            throw BrowserMCPDevToolsControlError.malformedResponse(
                "a WebSocket payload exceeded the bounded response size")
        }
        return data
    }

    func cancel() {
        self.task.cancel(with: .normalClosure, reason: nil)
    }
}

private final class BrowserMCPDevToolsControlDispatchMarker: @unchecked Sendable {
    private let lock = NSLock()
    private let onDispatch: @Sendable () -> Void
    private var dispatched = false

    init(onDispatch: @escaping @Sendable () -> Void) {
        self.onDispatch = onDispatch
    }

    var didDispatch: Bool {
        self.lock.withLock { self.dispatched }
    }

    func markDispatched() {
        let shouldNotify = self.lock.withLock {
            guard !self.dispatched else { return false }
            self.dispatched = true
            return true
        }
        if shouldNotify {
            self.onDispatch()
        }
    }
}
