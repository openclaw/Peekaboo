import Foundation
import PeekabooFoundation

enum ApplicationMetadataAdmissionError: Error {
    case overloaded
}

/// Bounds retained native metadata work per host process, independently of AX observation lanes.
/// Reservations include dispatched wrappers and survive caller timeout/cancellation until native
/// work and its autorelease cleanup finish. There is no admission queue or shared-result joining.
final class DetachedApplicationMetadataPool: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let processIdentifier: Int32
        let processStartIdentity: UInt64?
    }

    static let shared = DetachedApplicationMetadataPool()

    private let lock = NSLock()
    private var retainedKeys: Set<Key> = []
    private let capacity: Int
    private let queue: DispatchQueue
    private let didComplete: @Sendable (Key) -> Void

    init(
        capacity: Int = 8,
        queue: DispatchQueue = DispatchQueue(
            label: "boo.peekaboo.application-metadata",
            qos: .userInitiated,
            attributes: .concurrent,
            autoreleaseFrequency: .workItem),
        didComplete: @escaping @Sendable (Key) -> Void = { _ in })
    {
        precondition(capacity > 0)
        self.capacity = capacity
        self.queue = queue
        self.didComplete = didComplete
    }

    var retainedOperationCount: Int {
        self.lock.withLock { self.retainedKeys.count }
    }

    func run(
        request: DetachedApplicationMetadataRequest,
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable (DetachedApplicationMetadataRequest) throws -> DetachedApplicationMetadata)
        async throws -> DetachedApplicationMetadata
    {
        try Task.checkCancellation()
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw CaptureError.detectionTimedOut(timeoutSeconds)
        }
        let key = Key(
            processIdentifier: request.processIdentifier,
            processStartIdentity: request.expectedProcessStartIdentity)
        let state = ApplicationMetadataWaitState(timeoutSeconds: timeoutSeconds)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                do {
                    guard try state.admit({ try self.reserve(key, timeoutSeconds: timeoutSeconds) }) else { return }
                } catch {
                    state.resume(with: .failure(error))
                    return
                }

                let timeout = Task.detached {
                    do {
                        try await ContinuousClock().sleep(until: state.deadline)
                        state.resume(with: .failure(CaptureError.detectionTimedOut(timeoutSeconds)))
                    } catch {
                        // Completion or caller cancellation ends only the timer, never the reservation.
                    }
                }
                state.setTimeoutTask(timeout)
                let work = ApplicationMetadataWork(request: request, operation: operation)
                self.queue.async {
                    let result = autoreleasepool {
                        work.perform(if: state.claimWork())
                    }
                    self.complete(key)
                    if let result {
                        state.resume(with: result)
                    }
                }
            }
        } onCancel: {
            state.resume(with: .failure(CancellationError()))
        }
    }

    private func reserve(_ key: Key, timeoutSeconds: TimeInterval) throws {
        try self.lock.withLock {
            guard !self.retainedKeys.contains(key) else {
                throw CaptureError.detectionTimedOut(timeoutSeconds)
            }
            guard self.retainedKeys.count < self.capacity else {
                throw ApplicationMetadataAdmissionError.overloaded
            }
            self.retainedKeys.insert(key)
        }
    }

    private func complete(_ key: Key) {
        self.lock.withLock { _ = self.retainedKeys.remove(key) }
        self.didComplete(key)
    }
}

/// Only the admitted dispatch wrapper accesses this payload. Drop its captures outside locks and
/// inside the autorelease pool, including when a cancelled/expired wrapper skips its operation.
private final class ApplicationMetadataWork: @unchecked Sendable {
    private let request: DetachedApplicationMetadataRequest
    private var operation: (@Sendable (DetachedApplicationMetadataRequest) throws -> DetachedApplicationMetadata)?

    init(
        request: DetachedApplicationMetadataRequest,
        operation: @escaping @Sendable (DetachedApplicationMetadataRequest) throws -> DetachedApplicationMetadata)
    {
        self.request = request
        self.operation = operation
    }

    func perform(if claimed: Bool) -> Result<DetachedApplicationMetadata, any Error>? {
        defer { self.operation = nil }
        guard claimed, let operation = self.operation else { return nil }
        return Result { try operation(self.request) }
    }
}

private final class ApplicationMetadataWaitState: @unchecked Sendable {
    let deadline: ContinuousClock.Instant
    private let timeoutSeconds: TimeInterval
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DetachedApplicationMetadata, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false
    private var started = false

    init(timeoutSeconds: TimeInterval) {
        self.timeoutSeconds = timeoutSeconds
        // Keep Duration conversion representable even for a finite but enormous caller budget.
        let seconds = min(timeoutSeconds, TimeInterval(UInt64.max / 1_000_000_000))
        self.deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    }

    func install(_ continuation: CheckedContinuation<DetachedApplicationMetadata, any Error>) {
        let cancelled = self.lock.withLock {
            guard !self.finished else { return true }
            self.continuation = continuation
            return false
        }
        if cancelled {
            continuation.resume(throwing: CancellationError())
        }
    }

    func admit(_ reserve: () throws -> Void) throws -> Bool {
        try self.lock.withLock {
            guard !self.finished else { return false }
            guard ContinuousClock.now < self.deadline else {
                throw CaptureError.detectionTimedOut(self.timeoutSeconds)
            }
            // Lock order is waiter then pool; completion never takes the waiter lock under the pool lock.
            try reserve()
            return true
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        let finished = self.lock.withLock {
            guard !self.finished else { return true }
            self.timeoutTask = task
            return false
        }
        if finished {
            task.cancel()
        }
    }

    func claimWork() -> Bool {
        let claimed = self.lock.withLock {
            guard !self.finished, !self.started, ContinuousClock.now < self.deadline else { return false }
            self.started = true
            return true
        }
        if !claimed {
            self.resume(with: .failure(CaptureError.detectionTimedOut(self.timeoutSeconds)))
        }
        return claimed
    }

    func resume(with result: Result<DetachedApplicationMetadata, any Error>) {
        let continuation: CheckedContinuation<DetachedApplicationMetadata, any Error>?
        let timeoutTask: Task<Void, Never>?
        self.lock.lock()
        guard !self.finished else {
            self.lock.unlock()
            return
        }
        self.finished = true
        continuation = self.continuation
        timeoutTask = self.timeoutTask
        self.continuation = nil
        self.timeoutTask = nil
        let expired = ContinuousClock.now >= self.deadline
        self.lock.unlock()

        timeoutTask?.cancel()
        // A late native result cannot win merely because the timer has not been scheduled yet.
        if case .failure(is CancellationError) = result {
            continuation?.resume(with: result)
        } else if expired {
            continuation?.resume(throwing: CaptureError.detectionTimedOut(self.timeoutSeconds))
        } else {
            continuation?.resume(with: result)
        }
    }
}
