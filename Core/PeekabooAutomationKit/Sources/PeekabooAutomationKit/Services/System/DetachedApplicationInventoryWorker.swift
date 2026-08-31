import Foundation

/// One process-wide slot for synchronous inventory reads. A timed-out native getter retains
/// the slot until it returns; subsequent observations fail without queuing more native work.
final class DetachedApplicationInventoryWorker: @unchecked Sendable {
    static let shared = DetachedApplicationInventoryWorker()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "boo.peekaboo.application-inventory", qos: .userInitiated)
    private var occupied = false

    func run<Value: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () throws -> Value) async throws -> Value
    {
        let state = try ElementDetectionDeadline<Value>(seconds: seconds)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                let timer = Task.detached {
                    do {
                        try await state.waitForDeadline()
                        state.timeOut()
                    } catch {}
                }
                state.setTasks(timeout: timer)
                let admitted = self.lock.withLock {
                    guard !self.occupied else { return false }
                    self.occupied = true
                    return true
                }
                guard admitted else {
                    state.timeOut()
                    return
                }
                self.queue.async {
                    let result: Result<Value, any Error>? = autoreleasepool {
                        guard state.claimWork() else { return nil }
                        return Result { try operation() }
                    }
                    self.lock.withLock { self.occupied = false }
                    if let result {
                        state.complete(with: result)
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}
