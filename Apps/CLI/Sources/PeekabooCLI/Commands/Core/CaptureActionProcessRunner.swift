import Darwin
import Dispatch
import Foundation

private struct CaptureActionProcessLaunchError: LocalizedError {
    let message: String

    var errorDescription: String? {
        self.message
    }
}

private final class BoundedPipeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var data = Data()
    private nonisolated(unsafe) var truncated = false

    nonisolated func append(_ chunk: Data) {
        let maxOutputBytes = 64 * 1024
        self.lock.lock()
        defer { self.lock.unlock() }

        guard self.data.count < maxOutputBytes else {
            self.truncated = true
            return
        }

        let remaining = maxOutputBytes - self.data.count
        if chunk.count <= remaining {
            self.data.append(chunk)
        } else {
            self.data.append(contentsOf: chunk.prefix(remaining))
            self.truncated = true
        }
    }

    nonisolated func finish() -> (String, Bool) {
        self.lock.lock()
        defer { self.lock.unlock() }
        return (String(bytes: self.data, encoding: .utf8) ?? "", self.truncated)
    }
}

private final class CaptureActionSignalForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "boo.peekaboo.capture-action.signals")
    private nonisolated(unsafe) var sources: [any DispatchSourceSignal] = []
    private nonisolated(unsafe) var previousHandlers: [(Int32, sig_t?)] = []
    private nonisolated(unsafe) var cancelled = false

    nonisolated init(onSignal: @escaping @Sendable (Int32) -> Void) {
        for signalNumber in [SIGINT, SIGTERM] {
            self.previousHandlers.append((signalNumber, signal(signalNumber, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: self.queue)
            source.setEventHandler {
                onSignal(signalNumber)
            }
            source.resume()
            self.sources.append(source)
        }
    }

    nonisolated func cancel() {
        self.lock.lock()
        guard !self.cancelled else {
            self.lock.unlock()
            return
        }
        self.cancelled = true
        let sources = self.sources
        let previousHandlers = self.previousHandlers
        self.sources.removeAll()
        self.previousHandlers.removeAll()
        self.lock.unlock()

        for source in sources {
            source.cancel()
        }
        for (signalNumber, previousHandler) in previousHandlers {
            signal(signalNumber, previousHandler)
        }
    }

    deinit {
        self.cancel()
    }
}

private final class CaptureActionProcessBox: @unchecked Sendable {
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutOutput = BoundedPipeOutput()
    private let stderrOutput = BoundedPipeOutput()
    private let signalProcessGroup: @Sendable (pid_t, Int32) -> Void
    private let lock = NSLock()
    private nonisolated(unsafe) var processIdentifier: pid_t?
    private nonisolated(unsafe) var timedOut = false
    private nonisolated(unsafe) var forceStop = false
    private nonisolated(unsafe) var forceStopRequestedAt: Date?
    private nonisolated(unsafe) var didFinishWaiting = false

    nonisolated init(signalProcessGroup: @escaping @Sendable (pid_t, Int32) -> Void) {
        self.signalProcessGroup = signalProcessGroup
    }

    nonisolated func start(command: [String]) throws {
        guard let executable = command.first else {
            throw CaptureActionProcessLaunchError(message: "Action command cannot be empty")
        }
        self.installOutputHandlers()
        try self.spawn(executable: executable, arguments: command)
    }

    /// Reaps the child without blocking forever.
    ///
    /// Uses `WNOHANG` so timeout/cancellation can observe progress. The deadline is
    /// the final abandon time, not the first SIGKILL time.
    ///
    /// Timeout and cancellation send `SIGTERM` and schedule `SIGKILL` after 500 ms
    /// (`terminateAfterTimeout` / `terminateProcessGroupForCancellation`). The wait
    /// loop must not race that grace. For cancellation, the final deadline is also
    /// capped to cancelTime + ~1.6s so a long configured timeout cannot leave the
    /// caller blocked near the original deadline if the child survives signals.
    nonisolated func waitUntilExit(deadline: Date) -> Int32 {
        guard let pid = self.currentProcessIdentifier() else { return -1 }

        var status: Int32 = 0
        var didSendWaitLoopKill = false
        while true {
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid {
                self.markFinishedWaiting()
                return Self.exitCode(fromWaitStatus: status)
            }
            if result == -1 {
                if errno == EINTR {
                    continue
                }
                self.markFinishedWaiting()
                return -1
            }

            let now = Date()
            // Preserve TERM grace. The timeout/cancellation tasks send the normal SIGKILL
            // after 500 ms; this is only a redundant last-chance kill before giving up.
            let effectiveDeadline = self.effectiveWaitAbandonDeadline(original: deadline)
            let waitLoopKillDeadline = effectiveDeadline.addingTimeInterval(-1.0)
            if !didSendWaitLoopKill, now >= waitLoopKillDeadline {
                didSendWaitLoopKill = true
                self.killProcessGroup(pid: pid, signal: SIGKILL)
            }
            if now >= effectiveDeadline {
                // Child ignored or survived SIGKILL (or is stuck in uninterruptible sleep).
                // Transfer reaping to an asynchronous poller before unblocking the caller.
                self.startBackgroundReaper(pid: pid)
                self.markFinishedWaiting()
                return 128 + SIGKILL
            }

            usleep(10000)
        }
    }

    nonisolated func terminateAfterTimeout(seconds: TimeInterval) async {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
            return
        }
        guard self.requestTimeoutTermination() else { return }
        do {
            try await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            return
        }
        self.killTimedOutProcessGroup()
    }

    nonisolated func wasTimedOut() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.timedOut
    }

    /// Final abandon deadline used by the wait loop. On cancellation, shrink to
    /// cancelTime + 0.5s TERM grace + 1.0s SIGKILL reap grace (+ margin).
    private nonisolated func effectiveWaitAbandonDeadline(original: Date) -> Date {
        self.lock.lock()
        let forceStop = self.forceStop
        let requestedAt = self.forceStopRequestedAt
        self.lock.unlock()
        guard forceStop, let requestedAt else { return original }
        let cancelRelative = requestedAt.addingTimeInterval(1.6)
        return min(original, cancelRelative)
    }

    nonisolated func finishOutput() -> (stdout: (String, Bool), stderr: (String, Bool)) {
        let stdoutHandle = self.stdoutPipe.fileHandleForReading
        let stderrHandle = self.stderrPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        self.drainAvailableNonBlocking(from: stdoutHandle, into: self.stdoutOutput)
        self.drainAvailableNonBlocking(from: stderrHandle, into: self.stderrOutput)
        stdoutHandle.closeFile()
        stderrHandle.closeFile()
        return (self.stdoutOutput.finish(), self.stderrOutput.finish())
    }

    nonisolated func killTimedOutProcessGroup() {
        guard self.wasTimedOut(), let pid = self.currentProcessIdentifier() else { return }
        self.killProcessGroup(pid: pid, signal: SIGKILL)
    }

    nonisolated func terminateProcessGroupForCancellation() {
        self.lock.lock()
        self.forceStop = true
        if self.forceStopRequestedAt == nil {
            self.forceStopRequestedAt = Date()
        }
        let pid = self.processIdentifier
        self.lock.unlock()
        guard let pid else { return }
        self.killProcessGroup(pid: pid, signal: SIGTERM)
        Task.detached {
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            self.killProcessGroup(pid: pid, signal: SIGKILL)
        }
    }

    nonisolated func forwardSignalToProcessGroup(_ signalNumber: Int32) {
        guard let pid = self.currentProcessIdentifier() else { return }
        self.killProcessGroup(pid: pid, signal: signalNumber)
    }

    private nonisolated func spawn(executable: String, arguments: [String]) throws {
        let stdoutRead = self.stdoutPipe.fileHandleForReading.fileDescriptor
        let stdoutWrite = self.stdoutPipe.fileHandleForWriting.fileDescriptor
        let stderrRead = self.stderrPipe.fileHandleForReading.fileDescriptor
        let stderrWrite = self.stderrPipe.fileHandleForWriting.fileDescriptor

        var fileActions: posix_spawn_file_actions_t?
        try Self.check(posix_spawn_file_actions_init(&fileActions), "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try Self.check(posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO), "dup stdout")
        try Self.check(posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO), "dup stderr")
        try Self.check(posix_spawn_file_actions_addclose(&fileActions, stdoutRead), "close child stdout read")
        try Self.check(posix_spawn_file_actions_addclose(&fileActions, stderrRead), "close child stderr read")
        if stdoutWrite != STDOUT_FILENO {
            try Self.check(posix_spawn_file_actions_addclose(&fileActions, stdoutWrite), "close child stdout write")
        }
        if stderrWrite != STDERR_FILENO {
            try Self.check(posix_spawn_file_actions_addclose(&fileActions, stderrWrite), "close child stderr write")
        }

        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawnattr_init(&attributes), "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }

        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        try Self.check(posix_spawnattr_setflags(&attributes, flags), "set spawn flags")
        try Self.check(posix_spawnattr_setpgroup(&attributes, 0), "set process group")

        var argv = Self.makeCStringArray(arguments)
        defer { Self.freeCStringArray(argv) }

        let environment = ProcessInfo.processInfo.environment.map { key, value in "\(key)=\(value)" }
        var envp = Self.makeCStringArray(environment)
        defer { Self.freeCStringArray(envp) }

        var pid: pid_t = 0
        let spawnResult = executable.withCString { executablePath in
            posix_spawnp(&pid, executablePath, &fileActions, &attributes, &argv, &envp)
        }
        self.stdoutPipe.fileHandleForWriting.closeFile()
        self.stderrPipe.fileHandleForWriting.closeFile()
        try Self.check(spawnResult, "posix_spawnp")

        self.lock.lock()
        self.processIdentifier = pid
        self.lock.unlock()
    }

    private nonisolated func installOutputHandlers() {
        self.stdoutPipe.fileHandleForReading.readabilityHandler = { [stdoutOutput] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutOutput.append(chunk)
            }
        }
        self.stderrPipe.fileHandleForReading.readabilityHandler = { [stderrOutput] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrOutput.append(chunk)
            }
        }
    }

    private nonisolated func requestTimeoutTermination() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let pid = self.processIdentifier, !self.didFinishWaiting else { return false }
        self.timedOut = true
        self.killProcessGroup(pid: pid, signal: SIGTERM)
        return true
    }

    private nonisolated func currentProcessIdentifier() -> pid_t? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.processIdentifier
    }

    private nonisolated func markFinishedWaiting() {
        self.lock.lock()
        self.didFinishWaiting = true
        self.lock.unlock()
    }

    private nonisolated func killProcessGroup(pid: pid_t, signal: Int32) {
        self.signalProcessGroup(pid, signal)
    }

    private nonisolated func startBackgroundReaper(pid: pid_t) {
        Task.detached(priority: .utility) {
            var status: Int32 = 0
            while true {
                let result = Darwin.waitpid(pid, &status, WNOHANG)
                if result == pid {
                    return
                }
                if result == -1 {
                    if errno == EINTR {
                        continue
                    }
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private nonisolated func drainAvailableNonBlocking(from handle: FileHandle, into output: BoundedPipeOutput) {
        let outputReadChunkBytes = 4096
        let fileDescriptor = handle.fileDescriptor
        let flags = fcntl(fileDescriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }

        var buffer = [UInt8](repeating: 0, count: outputReadChunkBytes)
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, outputReadChunkBytes)
            if count > 0 {
                output.append(Data(buffer.prefix(count)))
            } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                break
            }
        }
    }

    private nonisolated static func makeCStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        return pointers
    }

    private nonisolated static func freeCStringArray(_ pointers: [UnsafeMutablePointer<CChar>?]) {
        for pointer in pointers {
            free(pointer)
        }
    }

    private nonisolated static func check(_ code: Int32, _ operation: String) throws {
        guard code != 0 else { return }
        throw CaptureActionProcessLaunchError(
            message: "\(operation) failed: \(String(cString: strerror(code)))"
        )
    }

    private nonisolated static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        if signal == 0 {
            return (status >> 8) & 0xFF
        }
        if signal != 0x7F {
            return 128 + signal
        }
        return status
    }
}

enum CaptureActionProcessRunner {
    nonisolated static func run(
        command: [String],
        timeoutSeconds: TimeInterval
    ) async throws -> CaptureActionProcessResult {
        try await self.run(
            command: command,
            timeoutSeconds: timeoutSeconds,
            signalProcessGroup: { pid, signal in
                _ = Darwin.kill(-pid, signal)
            }
        )
    }

    nonisolated static func run(
        command: [String],
        timeoutSeconds: TimeInterval,
        signalProcessGroup: @escaping @Sendable (pid_t, Int32) -> Void
    ) async throws -> CaptureActionProcessResult {
        let box = CaptureActionProcessBox(signalProcessGroup: signalProcessGroup)
        let started = Date()
        try box.start(command: command)
        let signalForwarder = CaptureActionSignalForwarder { signalNumber in
            box.forwardSignalToProcessGroup(signalNumber)
        }
        defer { signalForwarder.cancel() }

        return await withTaskCancellationHandler {
            // Hard ceiling: configured timeout + TERM grace (0.5s) + SIGKILL grace (1s) + margin.
            // Prevents indefinite hang if the child survives kill attempts.
            let deadline = Date().addingTimeInterval(timeoutSeconds + 2.0)
            let waitTask = Task.detached { box.waitUntilExit(deadline: deadline) }
            let timeoutTask = Task.detached { await box.terminateAfterTimeout(seconds: timeoutSeconds) }

            let exitCode = await waitTask.value
            box.killTimedOutProcessGroup()
            timeoutTask.cancel()
            try? await Task.sleep(nanoseconds: 50_000_000)
            let output = box.finishOutput()
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)

            return CaptureActionProcessResult(
                command: command,
                exitCode: exitCode,
                timedOut: box.wasTimedOut(),
                timeoutSeconds: timeoutSeconds,
                durationMs: durationMs,
                stdout: output.stdout.0,
                stderr: output.stderr.0,
                stdoutTruncated: output.stdout.1,
                stderrTruncated: output.stderr.1
            )
        } onCancel: {
            box.terminateProcessGroupForCancellation()
        }
    }
}
