import Darwin
import Foundation

/// Owns one accepted descriptor and serializes liveness probes, shutdown, and close so the descriptor cannot be
/// recycled while another thread still treats its numeric value as this connection.
final class PeekabooBridgeConnectionLiveness: @unchecked Sendable {
    typealias PeerProbe = @Sendable (Int32) -> Bool
    typealias DescriptorOperation = @Sendable (Int32) -> Void

    let id = UUID()
    private let lock = NSLock()
    private let peerProbe: PeerProbe
    private let shutdownHandler: DescriptorOperation
    private let closeHandler: DescriptorOperation
    private var transportFileDescriptor: Int32?
    private var probeFileDescriptor: Int32?
    private var connected = true

    init(
        fd: Int32,
        probeFD: Int32? = nil,
        peerProbe: @escaping PeerProbe = PeekabooBridgeSocketIO.peerCanReceiveResponse,
        shutdownHandler: @escaping DescriptorOperation = { fd in _ = Darwin.shutdown(fd, SHUT_RDWR) },
        closeHandler: @escaping DescriptorOperation = { fd in Darwin.close(fd) }) throws
    {
        let resolvedProbeFD: Int32
        if let probeFD {
            resolvedProbeFD = probeFD
        } else {
            resolvedProbeFD = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            guard resolvedProbeFD >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        self.transportFileDescriptor = fd
        self.probeFileDescriptor = resolvedProbeFD
        self.peerProbe = peerProbe
        self.shutdownHandler = shutdownHandler
        self.closeHandler = closeHandler
    }

    func canReceiveResponse() -> Bool {
        self.lock.lock()
        guard self.connected, let fd = self.probeFileDescriptor else {
            self.lock.unlock()
            return false
        }
        let canReceive = self.peerProbe(fd)
        if !canReceive {
            self.connected = false
            self.closeProbeLocked()
        }
        self.lock.unlock()
        return canReceive
    }

    func markDisconnected() {
        self.lock.lock()
        self.connected = false
        self.closeProbeLocked()
        self.lock.unlock()
    }

    func disconnectAndShutdown() {
        self.lock.lock()
        self.connected = false
        self.closeProbeLocked()
        if let fd = self.transportFileDescriptor {
            self.shutdownHandler(fd)
        }
        self.lock.unlock()
    }

    func close() {
        self.lock.lock()
        self.connected = false
        self.closeProbeLocked()
        if let fd = self.transportFileDescriptor {
            self.transportFileDescriptor = nil
            self.closeHandler(fd)
        }
        self.lock.unlock()
    }

    private func closeProbeLocked() {
        if let fd = self.probeFileDescriptor {
            self.probeFileDescriptor = nil
            self.closeHandler(fd)
        }
    }
}

final class PeekabooBridgeTrackedRequest: @unchecked Sendable {
    let id = UUID()
    let startedAt = Date()

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var activationContinuation: CheckedContinuation<Bool, Never>?
    private var cancellationRequested = false
    private var finished = false
    private var installed = false

    func install(task: Task<Void, Never>) {
        self.lock.lock()
        let shouldCancel = self.cancellationRequested || self.finished
        self.installed = true
        if !shouldCancel {
            self.task = task
        }
        let activationContinuation = self.activationContinuation
        self.activationContinuation = nil
        self.lock.unlock()

        activationContinuation?.resume(returning: !shouldCancel)
        if shouldCancel {
            task.cancel()
        }
    }

    func awaitActivation() async -> Bool {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            if self.installed || self.cancellationRequested || self.finished {
                let shouldStart = self.installed && !self.cancellationRequested && !self.finished
                self.lock.unlock()
                continuation.resume(returning: shouldStart)
            } else {
                self.activationContinuation = continuation
                self.lock.unlock()
            }
        }
    }

    func cancel() {
        self.lock.lock()
        self.cancellationRequested = true
        let task = self.task
        let activationContinuation = self.activationContinuation
        self.activationContinuation = nil
        self.lock.unlock()
        activationContinuation?.resume(returning: false)
        task?.cancel()
    }

    func markFinished() {
        self.lock.lock()
        self.finished = true
        self.task = nil
        let activationContinuation = self.activationContinuation
        self.activationContinuation = nil
        self.lock.unlock()
        activationContinuation?.resume(returning: false)
    }
}

final class PeekabooBridgeRequestTracker: @unchecked Sendable {
    struct DrainSnapshot: Sendable {
        let count: Int
        let oldestAgeSeconds: TimeInterval
    }

    private let lock = NSLock()
    private let maximumActiveRequestCount: Int
    private var acceptingRequests = true
    private var requests: [UUID: PeekabooBridgeTrackedRequest] = [:]
    private var idleContinuations: [CheckedContinuation<Void, Never>] = []

    init(maximumActiveRequestCount: Int = 32) {
        self.maximumActiveRequestCount = max(1, maximumActiveRequestCount)
    }

    var activeCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.requests.count
    }

    var drainSnapshot: DrainSnapshot {
        self.lock.lock()
        defer { self.lock.unlock() }
        let now = Date()
        let oldestAge = self.requests.values
            .map { now.timeIntervalSince($0.startedAt) }
            .max() ?? 0
        return DrainSnapshot(count: self.requests.count, oldestAgeSeconds: oldestAge)
    }

    func startAccepting() {
        self.lock.lock()
        if self.requests.isEmpty {
            self.acceptingRequests = true
        }
        self.lock.unlock()
    }

    func begin() -> PeekabooBridgeTrackedRequest? {
        self.lock.lock()
        guard self.acceptingRequests,
              self.requests.count < self.maximumActiveRequestCount
        else {
            self.lock.unlock()
            return nil
        }
        let request = PeekabooBridgeTrackedRequest()
        self.requests[request.id] = request
        self.lock.unlock()
        return request
    }

    func finish(_ request: PeekabooBridgeTrackedRequest) {
        request.markFinished()
        self.lock.lock()
        if self.requests[request.id] === request {
            self.requests[request.id] = nil
        }
        let idleContinuations = self.requests.isEmpty ? self.idleContinuations : []
        if self.requests.isEmpty {
            self.idleContinuations.removeAll()
        }
        self.lock.unlock()
        idleContinuations.forEach { $0.resume() }
    }

    func stopAcceptingAndCancelAll() {
        self.lock.lock()
        self.acceptingRequests = false
        let requests = Array(self.requests.values)
        self.lock.unlock()
        requests.forEach { $0.cancel() }
    }

    func waitForIdle() async {
        if self.activeCount == 0 {
            return
        }
        await withCheckedContinuation { continuation in
            self.lock.lock()
            if self.requests.isEmpty {
                self.lock.unlock()
                continuation.resume()
            } else {
                self.idleContinuations.append(continuation)
                self.lock.unlock()
            }
        }
    }
}

/// Synchronous capacity gate for connection, request-body, and refusal-signing lanes.
final class PeekabooBridgeCapacityLimiter: @unchecked Sendable {
    private let lock = NSLock()
    let maximumCount: Int
    private var active = 0
    private var peak = 0

    init(maximumCount: Int) {
        self.maximumCount = max(1, maximumCount)
    }

    var activeCount: Int {
        self.lock.withLock { self.active }
    }

    var peakActiveCount: Int {
        self.lock.withLock { self.peak }
    }

    func begin() -> Bool {
        self.lock.withLock {
            guard self.active < self.maximumCount else { return false }
            self.active += 1
            self.peak = max(self.peak, self.active)
            return true
        }
    }

    func finish() {
        self.lock.withLock {
            precondition(self.active > 0)
            self.active -= 1
        }
    }
}

enum PeekabooBridgeConnectedRequest {
    struct Context: @unchecked Sendable {
        let server: PeekabooBridgeServer
        let peer: PeekabooBridgePeer
        let connection: PeekabooBridgeConnectionLiveness
        let requestTracker: PeekabooBridgeRequestTracker
        let operationReceiptAuthority: PeekabooBridgeOperationReceiptAuthority?
        let operationSessionAuthorizationPin:
            PeekabooBridgeOperationReceiptAuthority.SessionAuthorizationPin?
    }

    private enum Result: Sendable {
        case response(Data)
        case disconnected

        var responseData: Data? {
            switch self {
            case let .response(data): data
            case .disconnected: nil
            }
        }
    }

    /// Resolves the connection exactly once without joining a cancelled request worker.
    ///
    /// AX and ScreenCaptureKit calls are not guaranteed to cooperate with task cancellation. A structured task-group
    /// race therefore cannot return when a client disconnects: the group still joins the stuck request child. This
    /// state lets the socket owner return immediately while cancellation propagates to cooperative request layers.
    private final class CompletionRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        private var result: Result?
        private var requestTask: Task<Void, Never>?
        private var disconnectTask: Task<Void, Never>?

        /// Returns false when cancellation or disconnect won before the continuation was installed.
        func install(_ continuation: CheckedContinuation<Data?, Never>) -> Bool {
            self.lock.lock()
            if let result = self.result {
                self.lock.unlock()
                continuation.resume(returning: result.responseData)
                return false
            }
            self.continuation = continuation
            self.lock.unlock()
            return true
        }

        func setTasks(request: Task<Void, Never>, disconnect: Task<Void, Never>) {
            self.lock.lock()
            let alreadyFinished = self.result != nil
            if !alreadyFinished {
                self.requestTask = request
                self.disconnectTask = disconnect
            }
            self.lock.unlock()

            if alreadyFinished {
                request.cancel()
                disconnect.cancel()
            }
        }

        func finish(_ result: Result) {
            let continuation: CheckedContinuation<Data?, Never>?
            let requestTask: Task<Void, Never>?
            let disconnectTask: Task<Void, Never>?

            self.lock.lock()
            guard self.result == nil else {
                self.lock.unlock()
                return
            }
            self.result = result
            continuation = self.continuation
            requestTask = self.requestTask
            disconnectTask = self.disconnectTask
            self.continuation = nil
            self.requestTask = nil
            self.disconnectTask = nil
            self.lock.unlock()

            requestTask?.cancel()
            disconnectTask?.cancel()
            continuation?.resume(returning: result.responseData)
        }
    }

    static func handle(
        request: PeekabooBridgeRequest,
        trackedRequest: PeekabooBridgeTrackedRequest,
        context: Context) async -> Data?
    {
        let race = CompletionRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard race.install(continuation) else {
                    context.operationSessionAuthorizationPin?.release()
                    context.requestTracker.finish(trackedRequest)
                    return
                }

                let requestTask = Task {
                    guard await trackedRequest.awaitActivation() else {
                        context.operationSessionAuthorizationPin?.release()
                        context.requestTracker.finish(trackedRequest)
                        return
                    }
                    defer { context.operationSessionAuthorizationPin?.release() }
                    let connectionProbe: @Sendable () -> Bool = {
                        context.connection.canReceiveResponse()
                    }
                    let operation: @Sendable () async -> Data = {
                        await context.server.handleDecoded(request, peer: context.peer)
                    }
                    let response = await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(
                        context.operationReceiptAuthority)
                    {
                        await PeekabooBridgeRequestContext.$clientConnectionProbe.withValue(
                            connectionProbe,
                            operation: operation)
                    }
                    context.requestTracker.finish(trackedRequest)
                    race.finish(.response(response))
                }
                trackedRequest.install(task: requestTask)
                let disconnectTask = Task.detached {
                    while !Task.isCancelled {
                        guard context.connection.canReceiveResponse() else {
                            context.connection.markDisconnected()
                            race.finish(.disconnected)
                            return
                        }
                        do {
                            try await Task.sleep(for: .milliseconds(10))
                        } catch {
                            return
                        }
                    }
                }
                race.setTasks(request: requestTask, disconnect: disconnectTask)
            }
        } onCancel: {
            context.connection.markDisconnected()
            trackedRequest.cancel()
            race.finish(.disconnected)
        }
    }
}
