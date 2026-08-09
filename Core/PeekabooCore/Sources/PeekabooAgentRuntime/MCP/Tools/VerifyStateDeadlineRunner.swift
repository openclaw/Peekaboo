import Foundation

enum VerifyStateDeadlineError: Error {
    case timedOut
}

enum VerifyStateDeadlineRunner {
    static func run<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        let state = VerifyStateDeadlineState<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                // The operation may enter noncooperative native code. Keep it off MainActor
                // so the detached timer and UI/server heartbeat can deliver the hard timeout.
                let work = Task.detached {
                    do {
                        try await state.resume(.success(operation()))
                    } catch {
                        state.resume(.failure(error))
                    }
                }
                // Do not inherit MainActor isolation: a native AX call can be temporarily
                // noncooperative, but the wall-clock deadline must still fire independently.
                let timeout = Task.detached {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                        state.resume(.failure(VerifyStateDeadlineError.timedOut))
                    } catch {
                        // Work completion or parent cancellation cancels this timer.
                    }
                }
                state.setTasks(work: work, timeout: timeout)
            }
        } onCancel: {
            state.resume(.failure(CancellationError()))
        }
    }
}

private final class VerifyStateDeadlineState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var work: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var completed = false

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        self.lock.withLock {
            if self.completed {
                continuation.resume(throwing: CancellationError())
            } else {
                self.continuation = continuation
            }
        }
    }

    func setTasks(work: Task<Void, Never>, timeout: Task<Void, Never>) {
        self.lock.withLock {
            if self.completed {
                work.cancel()
                timeout.cancel()
            } else {
                self.work = work
                self.timeout = timeout
            }
        }
    }

    func resume(_ result: Result<T, any Error>) {
        let completion: (CheckedContinuation<T, any Error>?, Task<Void, Never>?, Task<Void, Never>?) =
            self.lock.withLock {
                guard !self.completed else { return (nil, nil, nil) }
                self.completed = true
                let completion = (self.continuation, self.work, self.timeout)
                self.continuation = nil
                self.work = nil
                self.timeout = nil
                return completion
            }
        completion.1?.cancel()
        completion.2?.cancel()
        completion.0?.resume(with: result)
    }
}

actor VerifyStatePollProgress {
    struct Snapshot: Sendable {
        let sampleCount: Int
        let stableCount: Int
        let lastSample: VerifyStateSample?
    }

    private var sampleCount = 0
    private var stableCount = 0
    private var lastSample: VerifyStateSample?

    func record(_ sample: VerifyStateSample) {
        self.sampleCount += 1
        self.lastSample = sample
    }

    func updateStableCount(_ stableCount: Int) {
        self.stableCount = stableCount
    }

    func snapshot() -> Snapshot {
        Snapshot(
            sampleCount: self.sampleCount,
            stableCount: self.stableCount,
            lastSample: self.lastSample)
    }
}

struct VerifyStatePollTiming: Sendable {
    let clock: ContinuousClock
    let startedAt: ContinuousClock.Instant
    let deadline: ContinuousClock.Instant
}

struct VerifyStateResponseContext: Sendable {
    let sampleCount: Int
    let stableCount: Int
    let elapsedSeconds: TimeInterval
    let identityTracker: VerifyStateTargetIdentityTracker
}
