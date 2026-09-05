import Darwin
import Foundation

enum ProcessWaitError: Error {
    case timedOut
}

/// Wait for a launched `Process` with a hard deadline.
///
/// Foundation's `waitUntilExit()` can block forever if the child wedges.
nonisolated func waitForProcessExit(
    _ process: Process,
    timeoutSeconds: TimeInterval
) throws {
    final class LeaveOnce: @unchecked Sendable {
        private let lock = NSLock()
        private let group = DispatchGroup()
        private var left = false

        init() {
            self.group.enter()
        }

        func leave() {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.left else { return }
            self.left = true
            self.group.leave()
        }

        func wait(timeoutSeconds: TimeInterval) -> DispatchTimeoutResult {
            self.group.wait(timeout: .now() + timeoutSeconds)
        }
    }

    let once = LeaveOnce()
    process.terminationHandler = { _ in
        once.leave()
    }
    // Cover the race where the child exits before the handler is installed.
    if !process.isRunning {
        once.leave()
    }

    let waitResult = once.wait(timeoutSeconds: timeoutSeconds)
    guard waitResult == .timedOut else {
        return
    }

    // Child can exit after the group wait times out and before cleanup.
    // Process.terminate() on an already-exited task can raise; match daemon cleanup.
    if process.isRunning {
        process.terminate()
        let grace = once.wait(timeoutSeconds: 1.0)
        if grace == .timedOut, process.isRunning {
            let pid = process.processIdentifier
            if pid > 0 {
                kill(pid, SIGKILL)
            }
            _ = once.wait(timeoutSeconds: 1.0)
        }
    }

    throw ProcessWaitError.timedOut
}
