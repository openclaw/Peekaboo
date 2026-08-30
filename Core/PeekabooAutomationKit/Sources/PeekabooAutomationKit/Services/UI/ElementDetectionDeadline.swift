import Foundation
import PeekabooFoundation

/// Owns the timer and locked admission boundary for both MainActor and detached detection work.
final class ElementDetectionDeadline<T: Sendable>: @unchecked Sendable {
    private let deadline: ContinuousClock.Instant
    private let seconds: TimeInterval
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var workTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false
    private var started = false

    init(seconds: TimeInterval) throws {
        let enteredAt = ContinuousClock.now
        guard seconds.isFinite, seconds > 0 else {
            throw CaptureError.detectionTimedOut(seconds)
        }
        self.seconds = seconds
        // Retain the old timer's range without rounding Double(UInt64.max) up into a trapping conversion.
        let boundedSeconds = min(seconds, TimeInterval(UInt64.max / 1_000_000_000))
        self.deadline = enteredAt.advanced(by: .seconds(boundedSeconds))
    }

    func waitForDeadline() async throws {
        try await ContinuousClock().sleep(until: self.deadline)
    }

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        self.lock.lock()
        let alreadyFinished = self.finished
        if !alreadyFinished {
            self.continuation = continuation
        }
        self.lock.unlock()

        // Only parent cancellation can finish the owner before continuation installation.
        if alreadyFinished {
            continuation.resume(throwing: CancellationError())
        }
    }

    func setTasks(work: Task<Void, Never>? = nil, timeout: Task<Void, Never>) {
        self.lock.lock()
        if self.finished {
            self.lock.unlock()
            work?.cancel()
            timeout.cancel()
            return
        }
        self.workTask = work
        self.timeoutTask = timeout
        self.lock.unlock()
    }

    func claimWork() -> Bool {
        self.lock.lock()
        guard !self.finished, !self.started else {
            self.lock.unlock()
            return false
        }
        guard ContinuousClock.now < self.deadline else {
            self.lock.unlock()
            self.timeOut()
            return false
        }
        self.started = true
        self.lock.unlock()
        return true
    }

    func complete(with result: Result<T, any Error>) {
        self.finish(with: result, checkingDeadline: true)
    }

    func timeOut() {
        self.finish(with: .failure(CaptureError.detectionTimedOut(self.seconds)), checkingDeadline: false)
    }

    func cancel() {
        self.finish(with: .failure(CancellationError()), checkingDeadline: false)
    }

    private func finish(with result: Result<T, any Error>, checkingDeadline: Bool) {
        let continuation: CheckedContinuation<T, any Error>?
        let workTask: Task<Void, Never>?
        let timeoutTask: Task<Void, Never>?
        let admittedResult: Result<T, any Error>

        self.lock.lock()
        if self.finished {
            self.lock.unlock()
            return
        }
        // Timer scheduling is not the deadline: late values and errors must not win this race.
        admittedResult = checkingDeadline && ContinuousClock.now >= self.deadline
            ? .failure(CaptureError.detectionTimedOut(self.seconds)) : result
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
        continuation?.resume(with: admittedResult)
    }
}
