import Foundation
import PeekabooFoundation

@_spi(Testing) public enum ElementDetectionTimeoutRunner {
    public static func run<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T
    {
        let state = try ElementDetectionDeadline<T>(seconds: seconds)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)

                let workTask = Task { @MainActor in
                    guard state.claimWork() else { return }
                    do {
                        let value = try await operation()
                        state.complete(with: .success(value))
                    } catch {
                        state.complete(with: .failure(error))
                    }
                }

                // The timer must not inherit MainActor. A synchronous MainActor operation can still delay
                // caller resumption, but it cannot publish success merely by starving the deadline task.
                let timeoutTask = Task.detached {
                    do {
                        try await state.waitForDeadline()
                        state.timeOut()
                    } catch {
                        // Cancellation means work finished or the parent task was cancelled.
                    }
                }

                state.setTasks(work: workTask, timeout: timeoutTask)
            }
        } onCancel: {
            state.cancel()
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
        let state = try ElementDetectionDeadline<T>(seconds: seconds)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)

                let timeoutTask = Task.detached {
                    do {
                        try await state.waitForDeadline()
                        state.timeOut()
                    } catch {
                        // Cancellation means work finished or the caller was cancelled.
                    }
                }
                state.setTasks(timeout: timeoutTask)

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
                    state.complete(with: result)
                }
                if !enqueued {
                    state.timeOut()
                }
            }
        } onCancel: {
            state.cancel()
        }
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
