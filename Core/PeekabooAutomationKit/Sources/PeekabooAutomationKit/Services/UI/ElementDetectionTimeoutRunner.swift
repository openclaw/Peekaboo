import Foundation
import PeekabooFoundation

@_spi(Testing) public enum ElementDetectionTimeoutRunner {
    public static func run<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T
    {
        guard seconds.isFinite, seconds > 0 else {
            throw CaptureError.detectionTimedOut(seconds)
        }

        let state = ElementDetectionTimeoutState<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)

                let workTask = Task { @MainActor in
                    do {
                        let value = try await operation()
                        state.resume(with: .success(value))
                    } catch {
                        state.resume(with: .failure(error))
                    }
                }

                // The timer must not inherit MainActor. A synchronous MainActor operation can still delay
                // caller resumption, but it cannot publish success merely by starving the deadline task.
                let timeoutTask = Task.detached {
                    do {
                        try await Task.sleep(nanoseconds: self.nanoseconds(for: seconds))
                        state.resume(with: .failure(CaptureError.detectionTimedOut(seconds)))
                    } catch {
                        // Cancellation means work finished or the parent task was cancelled.
                    }
                }

                state.setTasks(work: workTask, timeout: timeoutTask)
            }
        } onCancel: {
            state.resume(with: .failure(CancellationError()))
        }
    }

    /// Runs non-mutating AX work on a per-process serial lane. A timeout resumes the caller immediately;
    /// it never joins an in-flight AX RPC because macOS accessibility calls are not cooperatively cancellable.
    @_spi(Testing) public static func runDetached<T: Sendable>(
        targetProcessIdentifier: Int32,
        targetProcessStartIdentity: UInt64? = nil,
        seconds: TimeInterval,
        maximumPendingOperationCount: Int? = nil,
        operation: @escaping @Sendable () throws -> T) async throws -> T
    {
        guard seconds.isFinite, seconds > 0 else {
            throw CaptureError.detectionTimedOut(seconds)
        }

        let state = DetachedAXOperationState<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)

                let timeoutTask = Task.detached {
                    do {
                        try await Task.sleep(nanoseconds: self.nanoseconds(for: seconds))
                        state.resume(with: .failure(CaptureError.detectionTimedOut(seconds)))
                    } catch {
                        // Cancellation means work finished or the caller was cancelled.
                    }
                }
                state.setTimeoutTask(timeoutTask)

                let processStartIdentity = targetProcessStartIdentity ??
                    SystemIdentityResolver.processStartIdentity(targetProcessIdentifier)
                let enqueued = AXObservationWorkerPool.shared.enqueue(
                    pid: targetProcessIdentifier,
                    processStartIdentity: processStartIdentity,
                    maximumPendingOperationCount: maximumPendingOperationCount)
                {
                    guard state.claimWork() else { return }
                    let result: Result<T, any Error> = autoreleasepool {
                        do {
                            return try .success(operation())
                        } catch {
                            return .failure(error)
                        }
                    }
                    state.resume(with: result)
                }
                if !enqueued {
                    state.resume(with: .failure(CaptureError.detectionTimedOut(seconds)))
                }
            }
        } onCancel: {
            state.resume(with: .failure(CancellationError()))
        }
    }

    private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        UInt64(min(seconds, TimeInterval(UInt64.max) / 1_000_000_000) * 1_000_000_000)
    }

    @_spi(Testing) public static var retainedIdleLaneCount: Int {
        AXObservationWorkerPool.shared.retainedIdleLaneCount
    }
}

private final class AXObservationWorkerPool: @unchecked Sendable {
    private struct Key: Hashable {
        let pid: Int32
        let processStartIdentity: UInt64?
    }

    private final class Lane {
        let queue: DispatchQueue
        var pendingCount = 0
        var lastUsed: UInt64 = 0

        init(key: Key) {
            let generation = key.processStartIdentity.map(String.init) ?? "unknown"
            self.queue = DispatchQueue(
                label: "boo.peekaboo.ax-observation.\(key.pid).\(generation)",
                qos: .userInitiated,
                autoreleaseFrequency: .workItem)
        }
    }

    static let shared = AXObservationWorkerPool()
    private static let maximumIdleLaneCount = 64

    private let lock = NSLock()
    private var lanes: [Key: Lane] = [:]
    private var useCounter: UInt64 = 0

    func enqueue(
        pid: Int32,
        processStartIdentity: UInt64?,
        maximumPendingOperationCount: Int?,
        operation: @escaping @Sendable () -> Void)
        -> Bool
    {
        let key = Key(pid: pid, processStartIdentity: processStartIdentity)
        let lane: Lane? = self.lock.withLock {
            self.useCounter &+= 1
            let lane = self.lanes[key] ?? Lane(key: key)
            if let maximumPendingOperationCount,
               lane.pendingCount >= max(1, maximumPendingOperationCount)
            {
                return nil
            }
            lane.pendingCount += 1
            lane.lastUsed = self.useCounter
            self.lanes[key] = lane
            self.evictIdleLanesIfNeeded(keeping: key)
            return lane
        }
        guard let lane else { return false }
        lane.queue.async {
            defer { self.complete(key: key) }
            operation()
        }
        return true
    }

    var retainedIdleLaneCount: Int {
        self.lock.withLock {
            self.lanes.values.count(where: { $0.pendingCount == 0 })
        }
    }

    private func complete(key: Key) {
        self.lock.withLock {
            guard let lane = self.lanes[key] else { return }
            lane.pendingCount = max(0, lane.pendingCount - 1)
            self.useCounter &+= 1
            lane.lastUsed = self.useCounter
            self.evictIdleLanesIfNeeded(keeping: nil)
        }
    }

    private func evictIdleLanesIfNeeded(keeping retainedKey: Key?) {
        let idle = self.lanes
            .filter { key, lane in lane.pendingCount == 0 && key != retainedKey }
            .sorted { $0.value.lastUsed < $1.value.lastUsed }
        let excess = max(0, idle.count - Self.maximumIdleLaneCount)
        for (key, _) in idle.prefix(excess) {
            self.lanes.removeValue(forKey: key)
        }
    }
}

private final class DetachedAXOperationState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false
    private var started = false

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        self.lock.lock()
        let alreadyFinished = self.finished
        if !alreadyFinished {
            self.continuation = continuation
        }
        self.lock.unlock()

        if alreadyFinished {
            continuation.resume(throwing: CancellationError())
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        self.lock.lock()
        if self.finished {
            self.lock.unlock()
            task.cancel()
            return
        }
        self.timeoutTask = task
        self.lock.unlock()
    }

    func claimWork() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.finished, !self.started else { return false }
        self.started = true
        return true
    }

    func resume(with result: Result<T, any Error>) {
        let continuation: CheckedContinuation<T, any Error>?
        let timeoutTask: Task<Void, Never>?

        self.lock.lock()
        if self.finished {
            self.lock.unlock()
            return
        }
        self.finished = true
        continuation = self.continuation
        timeoutTask = self.timeoutTask
        self.continuation = nil
        self.timeoutTask = nil
        self.lock.unlock()

        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

private final class ElementDetectionTimeoutState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var workTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        self.lock.lock()
        let shouldResumeCancellation = self.finished
        if !shouldResumeCancellation {
            self.continuation = continuation
        }
        self.lock.unlock()

        if shouldResumeCancellation {
            continuation.resume(throwing: CancellationError())
        }
    }

    func setTasks(work: Task<Void, Never>, timeout: Task<Void, Never>) {
        self.lock.lock()
        defer { self.lock.unlock() }

        if self.finished {
            work.cancel()
            timeout.cancel()
        } else {
            self.workTask = work
            self.timeoutTask = timeout
        }
    }

    func resume(with result: Result<T, any Error>) {
        let continuation: CheckedContinuation<T, any Error>?
        let workTask: Task<Void, Never>?
        let timeoutTask: Task<Void, Never>?

        self.lock.lock()
        if self.finished {
            self.lock.unlock()
            return
        }
        self.finished = true
        continuation = self.continuation
        workTask = self.workTask
        timeoutTask = self.timeoutTask
        self.continuation = nil
        self.workTask = nil
        self.timeoutTask = nil
        self.lock.unlock()

        workTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}
