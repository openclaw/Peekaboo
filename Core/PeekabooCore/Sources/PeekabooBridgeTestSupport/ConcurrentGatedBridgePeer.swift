import Darwin
import Foundation
import PeekabooBridge

/// A concurrent Unix-socket peer whose responses are released explicitly by tests.
///
/// Unlike ``ScriptedBridgePeer``, every accepted connection is drained independently. Tests can therefore await
/// exact request arrival and complete connections in a different order without using scheduling delays.
/// Socket waits suspend so idle peers cannot starve the cooperative executor running the test.
public final class ConcurrentGatedBridgePeer: @unchecked Sendable {
    public struct Request: Sendable {
        public let id: UInt64
        public let data: Data

        public func decode() throws -> PeekabooBridgeRequest {
            try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: self.data)
        }
    }

    public struct ReadCompletion: Sendable {
        public let connectionID: UInt64
        public let byteCount: Int
        public let reachedEOF: Bool
    }

    public enum PeerError: Error {
        case stopped
        case timedOut
        case unknownRequest(UInt64)
    }

    public let socketPath: String

    private let descriptors: DescriptorState
    private let state: State
    private let task: Task<Void, Never>

    public var acceptedConnectionCount: Int {
        get async { await self.state.acceptedConnectionCount }
    }

    /// Complete request payloads in arrival order, retained for failure diagnostics.
    public var requests: [Data] {
        get async { await self.state.requests }
    }

    public init(socketPathPrefix: String = "pb-gated-bridge") throws {
        let socketPath = "/tmp/\(socketPathPrefix)-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try Self.bindAndListen(descriptor: listener, socketPath: socketPath)
        } catch {
            Darwin.close(listener)
            try? FileManager.default.removeItem(atPath: socketPath)
            throw error
        }

        let descriptors = DescriptorState(listener: listener)
        let state = State()
        let task = Task.detached {
            defer {
                descriptors.finish()
                try? FileManager.default.removeItem(atPath: socketPath)
            }

            await withTaskGroup(of: Void.self) { group in
                while let accepted = await Self.acceptConnection(descriptors: descriptors) {
                    await state.recordAcceptedConnection()
                    group.addTask {
                        defer { descriptors.closeClient(id: accepted.id) }
                        Self.disableSigPipe(fd: accepted.descriptor)
                        let read = await Self.readRequest(from: accepted.descriptor)
                        await state.recordReadCompletion(.init(
                            connectionID: accepted.id,
                            byteCount: read.data.count,
                            reachedEOF: read.reachedEOF))
                        guard read.reachedEOF, !read.data.isEmpty, !descriptors.isCancelled else { return }
                        let action = await state.publish(.init(id: accepted.id, data: read.data))
                        guard !descriptors.isCancelled else { return }
                        switch action {
                        case let .respond(responseData):
                            await Self.write(responseData, to: accepted.descriptor)
                        case .close:
                            break
                        }
                    }
                }
                group.cancelAll()
            }
        }

        self.socketPath = socketPath
        self.descriptors = descriptors
        self.state = state
        self.task = task
    }

    deinit {
        self.task.cancel()
        self.cancelDescriptors()
        let state = self.state
        Task { await state.stop() }
    }

    /// Suspends until the next complete request is available.
    public func nextRequest() async throws -> Request {
        guard let request = await self.state.nextRequest() else { throw PeerError.stopped }
        return request
    }

    /// Waits for actual connection drains, including empty reads that never publish a request.
    public func waitForReadCompletions(
        _ count: Int,
        timeout: Duration = .seconds(2)) async throws -> [ReadCompletion]
    {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let progress = await self.state.readProgress()
            if progress.reads.count >= count {
                return progress.reads
            }
            if progress.stopped {
                throw PeerError.stopped
            }
            guard ContinuousClock.now < deadline else { throw PeerError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    public func respond(_ response: PeekabooBridgeResponse, to request: Request) async throws {
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(response)
        guard await self.state.finish(requestID: request.id, action: .respond(data)) else {
            throw PeerError.unknownRequest(request.id)
        }
    }

    public func respondData(_ data: Data, to request: Request) async throws {
        guard await self.state.finish(requestID: request.id, action: .respond(data)) else {
            throw PeerError.unknownRequest(request.id)
        }
    }

    public func close(_ request: Request) async throws {
        guard await self.state.finish(requestID: request.id, action: .close) else {
            throw PeerError.unknownRequest(request.id)
        }
    }

    public func stop() async {
        await self.state.stop()
        self.task.cancel()
        self.cancelDescriptors()
        await self.task.value
        self.descriptors.finish()
    }

    private func cancelDescriptors() {
        self.descriptors.cancel()
    }

    private nonisolated static func acceptConnection(
        descriptors: DescriptorState) async -> (id: UInt64, descriptor: Int32)?
    {
        while let listener = descriptors.listenerForAccept {
            let client = accept(listener, nil, nil)
            if client >= 0 {
                guard Self.makeNonblocking(client) else {
                    Darwin.close(client)
                    return nil
                }
                return descriptors.register(client: client)
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    return nil
                }
                continue
            }
            return nil
        }
        return nil
    }

    private nonisolated static func bindAndListen(descriptor: Int32, socketPath: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
        let copied = socketPath.withCString { source in
            strlcpy(&address.sun_path.0, source, MemoryLayout.size(ofValue: address.sun_path))
        }
        guard copied < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }

        let length = socklen_t(MemoryLayout.size(ofValue: address))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            Darwin.bind(descriptor, UnsafePointer<sockaddr>(OpaquePointer(pointer)), length)
        }
        guard bindResult == 0,
              listen(descriptor, SOMAXCONN) == 0,
              Self.makeNonblocking(descriptor)
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private nonisolated static func makeNonblocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else { return false }
        return fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private nonisolated static func disableSigPipe(fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    }

    private nonisolated static func readRequest(from descriptor: Int32) async -> (data: Data, reachedEOF: Bool) {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    return (result, false)
                }
                continue
            }
            return (result, count == 0)
        }
    }

    private nonisolated static func write(_ data: Data, to descriptor: Int32) async {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    return
                }
            } else {
                return
            }
        }
    }

    private actor State {
        private(set) var acceptedConnectionCount = 0
        private(set) var requests: [Data] = []
        private var readCompletions: [ReadCompletion] = []
        private var queuedRequests: [Request] = []
        private var requestWaiters: [CheckedContinuation<Request?, Never>] = []
        private var responseWaiters: [UInt64: CheckedContinuation<ResponseAction, Never>] = [:]
        private var stopped = false

        func recordAcceptedConnection() {
            self.acceptedConnectionCount += 1
        }

        func recordReadCompletion(_ read: ReadCompletion) {
            self.readCompletions.append(read)
        }

        func readProgress() -> (reads: [ReadCompletion], stopped: Bool) {
            (self.readCompletions, self.stopped)
        }

        func publish(_ request: Request) async -> ResponseAction {
            self.requests.append(request.data)
            return await withCheckedContinuation { continuation in
                guard !self.stopped else {
                    continuation.resume(returning: .close)
                    return
                }
                self.responseWaiters[request.id] = continuation
                if self.requestWaiters.isEmpty {
                    self.queuedRequests.append(request)
                } else {
                    self.requestWaiters.removeFirst().resume(returning: request)
                }
            }
        }

        func nextRequest() async -> Request? {
            guard self.queuedRequests.isEmpty else { return self.queuedRequests.removeFirst() }
            guard !self.stopped else { return nil }
            return await withCheckedContinuation { continuation in
                self.requestWaiters.append(continuation)
            }
        }

        func finish(requestID: UInt64, action: ResponseAction) -> Bool {
            guard let continuation = self.responseWaiters.removeValue(forKey: requestID) else { return false }
            continuation.resume(returning: action)
            return true
        }

        func stop() {
            guard !self.stopped else { return }
            self.stopped = true
            self.queuedRequests.removeAll()
            let requestWaiters = self.requestWaiters
            self.requestWaiters.removeAll()
            requestWaiters.forEach { $0.resume(returning: nil) }
            let responseWaiters = Array(self.responseWaiters.values)
            self.responseWaiters.removeAll()
            responseWaiters.forEach { $0.resume(returning: .close) }
        }
    }

    private enum ResponseAction: Sendable {
        case respond(Data)
        case close
    }

    private final class DescriptorState: @unchecked Sendable {
        private let lock = NSLock()
        private var listener: Int32?
        private var clients: [UInt64: Int32] = [:]
        private var nextID: UInt64 = 1
        private var cancelled = false

        init(listener: Int32) {
            self.listener = listener
        }

        var listenerForAccept: Int32? {
            self.lock.withLock { self.cancelled ? nil : self.listener }
        }

        var isCancelled: Bool {
            self.lock.withLock { self.cancelled }
        }

        func register(client: Int32) -> (id: UInt64, descriptor: Int32)? {
            self.lock.withLock {
                guard !self.cancelled else {
                    _ = shutdown(client, SHUT_RDWR)
                    Darwin.close(client)
                    return nil
                }
                let id = self.nextID
                self.nextID &+= 1
                precondition(self.nextID != 0, "A gated Bridge peer exhausted connection identifiers")
                self.clients[id] = client
                return (id, client)
            }
        }

        func closeClient(id: UInt64) {
            let client = self.lock.withLock { self.clients.removeValue(forKey: id) }
            guard let client else { return }
            _ = shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }

        func cancel() {
            self.lock.withLock {
                guard !self.cancelled else { return }
                self.cancelled = true
                for client in self.clients.values {
                    _ = shutdown(client, SHUT_RDWR)
                }
            }
        }

        func finish() {
            let descriptors = self.lock.withLock { () -> (Int32?, [Int32]) in
                self.cancelled = true
                let listener = self.listener
                self.listener = nil
                let clients = Array(self.clients.values)
                self.clients.removeAll()
                return (listener, clients)
            }
            for client in descriptors.1 {
                _ = shutdown(client, SHUT_RDWR)
                Darwin.close(client)
            }
            if let listener = descriptors.0 {
                _ = shutdown(listener, SHUT_RDWR)
                Darwin.close(listener)
            }
        }
    }
}
