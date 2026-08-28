import Darwin
import Foundation
import PeekabooBridge

/// A deterministic Unix-socket peer for Bridge client transport tests.
///
/// Each connection script drains and records exactly one request before running its steps. Scripts are served in
/// order, which makes protocol fallback and multi-request negotiation tests reproducible without bespoke peers.
public final class ScriptedBridgePeer: @unchecked Sendable {
    public enum Step: Sendable {
        /// Sleeps, then continues with the remaining steps for this connection.
        case delay(seconds: TimeInterval)
        /// Sleeps without responding, then closes this connection.
        case idle(seconds: TimeInterval)
        /// Encodes and writes one Bridge response.
        case respond(PeekabooBridgeResponse)
        /// Writes raw bytes, for malformed-response and wire-compatibility tests.
        case respondData(Data)
        /// Closes this connection immediately without a response.
        case close
    }

    public let socketPath: String

    private let descriptors: DescriptorState
    private let state: State
    private let task: Task<Void, Never>

    public var requests: [Data] {
        get async { await self.state.requests }
    }

    public var acceptedConnectionCount: Int {
        get async { await self.state.acceptedConnectionCount }
    }

    public convenience init(
        responses: [PeekabooBridgeResponse],
        socketPathPrefix: String = "pb-scripted-bridge") throws
    {
        try self.init(
            scripts: responses.map { [.respond($0)] },
            socketPathPrefix: socketPathPrefix)
    }

    public convenience init(
        steps: [Step],
        socketPathPrefix: String = "pb-scripted-bridge") throws
    {
        try self.init(scripts: [steps], socketPathPrefix: socketPathPrefix)
    }

    public init(
        scripts: [[Step]],
        socketPathPrefix: String = "pb-scripted-bridge") throws
    {
        precondition(!scripts.isEmpty, "A scripted Bridge peer requires at least one connection script")
        precondition(
            scripts.allSatisfy { !$0.isEmpty },
            "Every scripted Bridge connection requires at least one step")

        let socketPath = "/tmp/\(socketPathPrefix)-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try Self.validate(scripts: scripts)
            try Self.bindAndListen(
                descriptor: listener,
                socketPath: socketPath,
                backlog: scripts.count)
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

            for script in scripts {
                var client: Int32
                while true {
                    guard let listener = descriptors.listenerForAccept else { return }
                    client = accept(listener, nil, nil)
                    if client >= 0 {
                        break
                    }
                    if errno == EINTR {
                        continue
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        do {
                            try await Task.sleep(for: .milliseconds(1))
                        } catch {
                            return
                        }
                        continue
                    }
                    return
                }
                guard Self.makeNonblocking(client) else {
                    Darwin.close(client)
                    return
                }
                guard descriptors.register(client: client) else { return }
                await state.recordAcceptedConnection()
                defer { descriptors.closeActiveClient(client) }

                var noSigPipe: Int32 = 1
                _ = setsockopt(
                    client,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    &noSigPipe,
                    socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
                let request = await Self.readRequest(from: client)
                await state.record(request)
                guard !descriptors.isCancelled else { return }

                var shouldClose = false
                for step in script where !shouldClose {
                    switch step {
                    case let .delay(seconds):
                        do {
                            try await Task.sleep(for: .seconds(seconds))
                        } catch {
                            shouldClose = true
                        }
                    case let .idle(seconds):
                        try? await Task.sleep(for: .seconds(seconds))
                        shouldClose = true
                    case let .respond(response):
                        guard let data = try? JSONEncoder.peekabooBridgeEncoder().encode(response) else {
                            shouldClose = true
                            continue
                        }
                        await Self.write(data, to: client)
                    case let .respondData(data):
                        await Self.write(data, to: client)
                    case .close:
                        shouldClose = true
                    }
                }
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
    }

    public func waitUntilFinished() async {
        await self.task.value
        self.descriptors.finish()
    }

    public func stop() async {
        self.task.cancel()
        self.cancelDescriptors()
        await self.task.value
        self.descriptors.finish()
    }

    private func cancelDescriptors() {
        guard self.descriptors.cancel() else { return }
        Self.wakeListener(at: self.socketPath)
    }

    private nonisolated static func bindAndListen(
        descriptor: Int32,
        socketPath: String,
        backlog: Int) throws
    {
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
              listen(descriptor, Int32(backlog)) == 0,
              Self.makeNonblocking(descriptor)
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private nonisolated static func wakeListener(at socketPath: String) {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
        let copied = socketPath.withCString { source in
            strlcpy(&address.sun_path.0, source, MemoryLayout.size(ofValue: address.sun_path))
        }
        guard copied < MemoryLayout.size(ofValue: address.sun_path) else { return }

        let length = socklen_t(MemoryLayout.size(ofValue: address))
        _ = withUnsafePointer(to: &address) { pointer in
            Darwin.connect(descriptor, UnsafePointer<sockaddr>(OpaquePointer(pointer)), length)
        }
    }

    private nonisolated static func validate(scripts: [[Step]]) throws {
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        for script in scripts {
            for step in script {
                if case let .respond(response) = step {
                    _ = try encoder.encode(response)
                }
            }
        }
    }

    private nonisolated static func readRequest(from descriptor: Int32) async -> Data {
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
                    return result
                }
                continue
            }
            return result
        }
    }

    private nonisolated static func write(_ data: Data, to descriptor: Int32) async {
        guard !data.isEmpty else { return }
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

    private nonisolated static func makeNonblocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else { return false }
        return fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private actor State {
        private(set) var requests: [Data] = []
        private(set) var acceptedConnectionCount = 0

        func recordAcceptedConnection() {
            self.acceptedConnectionCount += 1
        }

        func record(_ request: Data) {
            self.requests.append(request)
        }
    }

    private final class DescriptorState: @unchecked Sendable {
        private let lock = NSLock()
        private var listener: Int32?
        private var activeClient: Int32?
        private var cancelled = false

        init(listener: Int32) {
            self.listener = listener
        }

        var listenerForAccept: Int32? {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.cancelled ? nil : self.listener
        }

        var isCancelled: Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.cancelled
        }

        func register(client: Int32) -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.cancelled else {
                _ = shutdown(client, SHUT_RDWR)
                Darwin.close(client)
                return false
            }
            precondition(self.activeClient == nil, "A scripted Bridge peer serves one connection at a time")
            self.activeClient = client
            return true
        }

        func closeActiveClient(_ client: Int32) {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.activeClient == client else { return }
            self.activeClient = nil
            Darwin.close(client)
        }

        func cancel() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.cancelled else { return false }
            self.cancelled = true
            if let activeClient {
                _ = shutdown(activeClient, SHUT_RDWR)
            }
            return self.listener != nil
        }

        func finish() {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.cancelled = true
            if let activeClient = self.activeClient {
                self.activeClient = nil
                _ = shutdown(activeClient, SHUT_RDWR)
                Darwin.close(activeClient)
            }
            if let listener = self.listener {
                self.listener = nil
                _ = shutdown(listener, SHUT_RDWR)
                Darwin.close(listener)
            }
        }
    }
}
