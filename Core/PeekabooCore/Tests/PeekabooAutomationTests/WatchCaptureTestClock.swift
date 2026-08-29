import Foundation
import PeekabooAutomationKit

final class ControlledWatchCaptureClock: WatchCaptureMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 0
    private var sleepers: [UUID: (deadline: UInt64, continuation: CheckedContinuation<Void, any Error>)] = [:]

    func nowNanoseconds() -> UInt64 {
        self.lock.withLock { self.now }
    }

    var sleepingCount: Int {
        self.lock.withLock { self.sleepers.count }
    }

    func waitUntilSleeping(until deadline: UInt64) async -> Bool {
        for _ in 0..<1000 {
            let registered = self.lock.withLock {
                self.sleepers.count == 1 && self.sleepers.values.first?.deadline == deadline
            }
            if registered {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return false
            }
        }
        return false
    }

    func advance(to nanoseconds: UInt64) {
        let ready = self.lock.withLock {
            precondition(nanoseconds >= self.now)
            self.now = nanoseconds
            let ready = self.sleepers.filter { $0.value.deadline <= nanoseconds }
            for id in ready.keys {
                self.sleepers.removeValue(forKey: id)
            }
            return ready.values.map(\.continuation)
        }
        for continuation in ready {
            continuation.resume()
        }
    }

    func sleep(nanoseconds: UInt64) async throws {
        let id = UUID()
        let deadline = self.nowNanoseconds() + nanoseconds
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.lock.lock()
                if Task.isCancelled {
                    self.lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if self.now >= deadline {
                    self.lock.unlock()
                    continuation.resume()
                } else {
                    self.sleepers[id] = (deadline, continuation)
                    self.lock.unlock()
                }
            }
        } onCancel: {
            let sleeper = self.lock.withLock { self.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}
