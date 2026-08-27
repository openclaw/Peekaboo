import Darwin
import Dispatch
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

struct CaptureActionProcessLaunchError: LocalizedError {
    let message: String
    let refusalReason: DesktopActionOutcome.RefusalReason?

    init(
        message: String,
        refusalReason: DesktopActionOutcome.RefusalReason? = nil
    ) {
        self.message = message
        self.refusalReason = refusalReason
    }

    var errorDescription: String? {
        self.message
    }
}

private enum CaptureActionLeaderWaitOutcome {
    case exited
    case abandoned
}

enum CaptureActionProcessDeadline {
    nonisolated static func hasExpired(observedAtNanoseconds: UInt64, deadlineNanoseconds: UInt64) -> Bool {
        observedAtNanoseconds >= deadlineNanoseconds
    }
}

private struct CaptureActionBlockingCompletion: Sendable {
    let completedAtMonotonicNanoseconds: UInt64
    let processGroupCleaned: Bool
    let exitCode: Int32?
    let stdout: String
    let stderr: String
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
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

final class CaptureActionSignalCoordinator: @unchecked Sendable {
    nonisolated static let shared = CaptureActionSignalCoordinator()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "boo.peekaboo.capture-action.signals")
    private nonisolated(unsafe) var callbacks: [UUID: @Sendable (Int32) -> Void] = [:]
    private nonisolated(unsafe) var sources: [any DispatchSourceSignal] = []
    private nonisolated(unsafe) var previousHandlers: [(Int32, sig_t?)] = []
    private nonisolated(unsafe) var activeGeneration: UUID?

    nonisolated func register(_ callback: @escaping @Sendable (Int32) -> Void) -> UUID {
        let identifier = UUID()
        self.lock.lock()
        if self.callbacks.isEmpty {
            self.installSignalSources()
        }
        self.callbacks[identifier] = callback
        self.lock.unlock()
        return identifier
    }

    nonisolated func unregister(_ identifier: UUID) {
        self.lock.lock()
        self.callbacks.removeValue(forKey: identifier)
        guard self.callbacks.isEmpty else {
            self.lock.unlock()
            return
        }
        self.activeGeneration = nil
        self.sources.forEach { $0.cancel() }
        for (signalNumber, previousHandler) in self.previousHandlers {
            signal(signalNumber, previousHandler)
        }
        self.sources.removeAll()
        self.previousHandlers.removeAll()
        self.lock.unlock()
    }

    private nonisolated func installSignalSources() {
        let generation = UUID()
        self.activeGeneration = generation
        for signalNumber in [SIGINT, SIGTERM] {
            self.previousHandlers.append((signalNumber, signal(signalNumber, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: self.queue)
            source.setEventHandler { [weak self] in
                self?.forward(signalNumber, generation: generation)
            }
            source.resume()
            self.sources.append(source)
        }
    }

    private nonisolated func forward(_ signalNumber: Int32, generation: UUID) {
        self.lock.lock()
        guard self.activeGeneration == generation else {
            self.lock.unlock()
            return
        }
        let callbacks = Array(self.callbacks.values)
        self.lock.unlock()
        callbacks.forEach { $0(signalNumber) }
    }

    #if DEBUG
    nonisolated var activeGenerationForTesting: UUID? {
        self.lock.withLock { self.activeGeneration }
    }

    nonisolated func forwardForTesting(_ signalNumber: Int32, generation: UUID) {
        self.forward(signalNumber, generation: generation)
    }
    #endif
}

private final class CaptureActionSignalForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private let identifier: UUID
    private nonisolated(unsafe) var cancelled = false

    nonisolated init(onSignal: @escaping @Sendable (Int32) -> Void) {
        self.identifier = CaptureActionSignalCoordinator.shared.register(onSignal)
    }

    nonisolated func cancel() {
        self.lock.lock()
        guard !self.cancelled else {
            self.lock.unlock()
            return
        }
        self.cancelled = true
        self.lock.unlock()
        CaptureActionSignalCoordinator.shared.unregister(self.identifier)
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
    private let outputHandlerLock = NSLock()
    private let signalProcessGroup: @Sendable (pid_t, Int32) -> Void
    private let processStartIdentityProvider: @Sendable (pid_t) -> UInt64?
    private let lock = NSLock()
    private nonisolated(unsafe) var processIdentifier: pid_t?
    private nonisolated(unsafe) var processStartIdentity: UInt64?
    private nonisolated(unsafe) var processReleased = false
    private nonisolated(unsafe) var unreleasedCleanupStarted = false
    private nonisolated(unsafe) var preReleaseSignal: Int32?
    private nonisolated(unsafe) var timedOut = false
    private nonisolated(unsafe) var forceStop = false
    private nonisolated(unsafe) var forceStopRequestedAtNs: UInt64?
    private nonisolated(unsafe) var terminationRequestedAtNs: UInt64?
    private nonisolated(unsafe) var terminationKillSent = false
    private nonisolated(unsafe) var didFinishWaiting = false
    private nonisolated(unsafe) var outputFinished = false

    nonisolated init(
        signalProcessGroup: @escaping @Sendable (pid_t, Int32) -> Void,
        processStartIdentityProvider: @escaping @Sendable (pid_t) -> UInt64?
    ) {
        self.signalProcessGroup = signalProcessGroup
        self.processStartIdentityProvider = processStartIdentityProvider
    }

    nonisolated func start(command: [String]) throws {
        guard let executable = command.first else {
            throw CaptureActionProcessLaunchError(message: "Action command cannot be empty")
        }
        self.installOutputHandlers()
        try self.spawn(executable: executable, arguments: command)
    }

    /// Releases the already-attributed child only after signal forwarding is installed.
    /// `POSIX_SPAWN_START_SUSPENDED` prevents command code from running before the
    /// process-generation receipt exists.
    nonisolated func release(before deadlineNs: UInt64) throws -> UInt64 {
        self.lock.lock()
        guard !self.processReleased,
              let pid = self.processIdentifier,
              let expectedStartIdentity = self.processStartIdentity
        else {
            self.lock.unlock()
            throw CaptureActionProcessLaunchError(message: "Action process is not ready for release")
        }
        let wasCancelledBeforeValidation = self.forceStop
        let signalBeforeValidation = self.preReleaseSignal
        self.lock.unlock()

        if wasCancelledBeforeValidation || signalBeforeValidation != nil {
            self.terminateUnreleasedProcess(pid: pid)
            if wasCancelledBeforeValidation {
                throw CancellationError()
            }
            throw CaptureActionProcessLaunchError(
                message: "Action process received signal \(signalBeforeValidation ?? 0) before release"
            )
        }

        guard self.processStartIdentityProvider(pid) == expectedStartIdentity else {
            self.terminateUnreleasedProcess(pid: pid)
            throw CaptureActionProcessLaunchError(
                message: "Action process identity changed before release",
                refusalReason: .runtimeIncompatible
            )
        }
        self.lock.lock()
        guard !self.forceStop,
              self.preReleaseSignal == nil,
              !self.processReleased,
              self.processIdentifier == pid,
              self.processStartIdentity == expectedStartIdentity
        else {
            let wasCancelled = self.forceStop
            let signalNumber = self.preReleaseSignal
            self.lock.unlock()
            self.terminateUnreleasedProcess(pid: pid)
            if wasCancelled {
                throw CancellationError()
            }
            throw CaptureActionProcessLaunchError(
                message: "Action process received signal \(signalNumber ?? 0) before release"
            )
        }
        let startedNs = DispatchTime.now().uptimeNanoseconds
        guard startedNs < deadlineNs else {
            self.lock.unlock()
            self.terminateUnreleasedProcess(pid: pid)
            throw CaptureActionProcessLaunchError(
                message: "Action completion deadline elapsed before process release",
                refusalReason: .invalidRequest
            )
        }
        self.processReleased = true
        self.lock.unlock()
        guard Darwin.kill(pid, SIGCONT) == 0 else {
            let releaseError = errno
            self.terminateUnreleasedProcess(pid: pid, allowingCommittedRelease: true)
            throw CaptureActionProcessLaunchError(
                message: "Could not release action process: \(String(cString: strerror(releaseError)))"
            )
        }
        return startedNs
    }

    nonisolated func terminateUnreleasedIfNeeded() {
        self.lock.lock()
        let pid = self.processIdentifier
        let shouldTerminate = !self.processReleased && !self.didFinishWaiting && pid != nil
        self.lock.unlock()
        if shouldTerminate, let pid {
            self.terminateUnreleasedProcess(pid: pid)
        }
    }

    /// Observes the child exit without reaping it so its PID/PGID cannot be reused before
    /// process-group descendants are drained.
    ///
    /// Uses `WNOHANG` so timeout/cancellation can observe progress. The deadline is
    /// the final abandon time, not the first SIGKILL time.
    ///
    /// This blocking waiter owns timeout and cancellation escalation so cooperative
    /// executor load cannot let a detached SIGKILL overtake SIGTERM. The 500 ms grace
    /// starts when TERM is actually dispatched and remains capped by the one absolute
    /// completion deadline. Cancellation also shrinks that deadline to ~1.6 seconds.
    nonisolated func waitUntilExit(
        timeoutDeadlineNs: UInt64,
        abandonDeadlineNs: UInt64
    ) -> CaptureActionLeaderWaitOutcome {
        guard let pid = self.currentProcessIdentifier() else { return .abandoned }

        while true {
            var information = siginfo_t()
            let result = Darwin.waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
            if result == 0, information.si_pid == pid {
                self.markLeaderExit(
                    observedAtNs: DispatchTime.now().uptimeNanoseconds,
                    timeoutDeadlineNs: timeoutDeadlineNs
                )
                return .exited
            }
            if result == -1 {
                if errno == EINTR {
                    continue
                }
                self.markFinishedWaiting()
                return .abandoned
            }

            let nowNs = DispatchTime.now().uptimeNanoseconds
            let effectiveDeadlineNs = self.effectiveWaitAbandonDeadline(originalNs: abandonDeadlineNs)
            if nowNs >= timeoutDeadlineNs {
                self.requestTimeoutTermination(observedAtNs: nowNs)
            }
            self.sendTerminationKillIfDue(
                observedAtNs: nowNs,
                abandonDeadlineNs: effectiveDeadlineNs
            )
            if nowNs >= effectiveDeadlineNs {
                // Child ignored or survived SIGKILL (or is stuck in uninterruptible sleep).
                // Transfer reaping to an asynchronous poller before unblocking the caller.
                self.startBackgroundReaper(pid: pid)
                self.markFinishedWaiting()
                return .abandoned
            }

            usleep(10000)
        }
    }

    nonisolated func wasTimedOut() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.timedOut
    }

    nonisolated func launchIdentity() -> (processIdentifier: pid_t, processStartIdentity: UInt64)? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let processIdentifier = self.processIdentifier,
              let processStartIdentity = self.processStartIdentity
        else { return nil }
        return (processIdentifier, processStartIdentity)
    }

    /// Final abandon deadline used by the wait loop. On cancellation, shrink to
    /// cancelTime + 0.5s TERM grace + 1.0s SIGKILL reap grace (+ margin).
    private nonisolated func effectiveWaitAbandonDeadline(originalNs: UInt64) -> UInt64 {
        self.lock.lock()
        let forceStop = self.forceStop
        let requestedAtNs = self.forceStopRequestedAtNs
        self.lock.unlock()
        guard forceStop, let requestedAtNs else { return originalNs }
        let (cancelRelativeNs, overflow) = requestedAtNs.addingReportingOverflow(1_600_000_000)
        return min(originalNs, overflow ? UInt64.max : cancelRelativeNs)
    }

    nonisolated func finishOutput() -> (stdout: (String, Bool), stderr: (String, Bool)) {
        let stdoutHandle = self.stdoutPipe.fileHandleForReading
        let stderrHandle = self.stderrPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        self.outputHandlerLock.withLock {
            self.outputFinished = true
        }
        self.drainAvailableNonBlocking(from: stdoutHandle, into: self.stdoutOutput)
        self.drainAvailableNonBlocking(from: stderrHandle, into: self.stderrOutput)
        stdoutHandle.closeFile()
        stderrHandle.closeFile()
        return (self.stdoutOutput.finish(), self.stderrOutput.finish())
    }

    nonisolated func completeBlockingLifecycle(
        timeoutDeadlineNs: UInt64,
        abandonDeadlineNs: UInt64
    ) -> CaptureActionBlockingCompletion {
        let waitOutcome = self.waitUntilExit(
            timeoutDeadlineNs: timeoutDeadlineNs,
            abandonDeadlineNs: abandonDeadlineNs
        )
        let effectiveAbandonDeadlineNs = self.effectiveWaitAbandonDeadline(originalNs: abandonDeadlineNs)
        let processGroupCleaned: Bool
        let exitCode: Int32?
        switch waitOutcome {
        case .exited:
            processGroupCleaned = self.terminateRemainingProcessGroup(
                abandonDeadlineNs: effectiveAbandonDeadlineNs
            )
            exitCode = self.reapObservedLeader()
        case .abandoned:
            processGroupCleaned = false
            exitCode = nil
        }
        let output = self.finishOutput()
        return CaptureActionBlockingCompletion(
            completedAtMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            processGroupCleaned: processGroupCleaned,
            exitCode: exitCode,
            stdout: output.stdout.0,
            stderr: output.stderr.0,
            stdoutTruncated: output.stdout.1,
            stderrTruncated: output.stderr.1
        )
    }

    /// A successful direct child is not a complete action while members of its process group
    /// remain able to mutate the capture directory. Drain the group before returning so the
    /// caller's later artifact validation is a real post-action boundary. This deliberately
    /// owns one process group, not a hostile-process sandbox for children that call `setsid`.
    nonisolated func terminateRemainingProcessGroup(abandonDeadlineNs: UInt64) -> Bool {
        guard let pid = self.currentProcessIdentifier() else { return false }
        if let remaining = self.processGroupMembersExcludingLeader(pid: pid), remaining.isEmpty {
            return true
        }

        // Timeout/cancellation already spent their bounded TERM/KILL grace in the wait path.
        // Reassert KILL and verify briefly without extending that hard ceiling by another cycle.
        if self.terminationWasRequested() {
            self.killProcessGroup(pid: pid, signal: SIGKILL)
            return self.waitForProcessGroupExit(pid: pid, deadlineNs: abandonDeadlineNs)
        }

        self.killProcessGroup(pid: pid, signal: SIGTERM)
        let termGraceNs = UInt64(CaptureActionProcessRunner.processGroupTerminationGraceSeconds * 1_000_000_000)
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let (unboundedTermDeadlineNs, overflowed) = nowNs.addingReportingOverflow(termGraceNs)
        let termDeadlineNs = min(overflowed ? UInt64.max : unboundedTermDeadlineNs, abandonDeadlineNs)
        if self.waitForProcessGroupExit(pid: pid, deadlineNs: termDeadlineNs) {
            return true
        }

        guard DispatchTime.now().uptimeNanoseconds < abandonDeadlineNs else { return false }
        self.killProcessGroup(pid: pid, signal: SIGKILL)
        return self.waitForProcessGroupExit(pid: pid, deadlineNs: abandonDeadlineNs)
    }

    private nonisolated func terminationWasRequested() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.timedOut || self.forceStop
    }

    nonisolated func terminateProcessGroupForCancellation() {
        self.lock.lock()
        guard !self.didFinishWaiting else {
            self.lock.unlock()
            return
        }
        self.forceStop = true
        let requestedAtNs = DispatchTime.now().uptimeNanoseconds
        self.forceStopRequestedAtNs = self.forceStopRequestedAtNs ?? requestedAtNs
        let pid = self.processIdentifier
        let processReleased = self.processReleased
        guard processReleased, let pid else {
            self.lock.unlock()
            return
        }
        if self.terminationRequestedAtNs == nil {
            self.terminationRequestedAtNs = requestedAtNs
            self.killProcessGroup(pid: pid, signal: SIGTERM)
        }
        self.lock.unlock()
    }

    nonisolated func forwardSignalToProcessGroup(_ signalNumber: Int32) {
        self.lock.lock()
        guard !self.didFinishWaiting, let pid = self.processIdentifier else {
            if !self.didFinishWaiting, !self.processReleased {
                self.preReleaseSignal = self.preReleaseSignal ?? signalNumber
            }
            self.lock.unlock()
            return
        }
        guard self.processReleased else {
            self.preReleaseSignal = self.preReleaseSignal ?? signalNumber
            self.lock.unlock()
            return
        }
        self.killProcessGroup(pid: pid, signal: signalNumber)
        self.lock.unlock()
    }

    nonisolated func reapObservedLeader() -> Int32? {
        guard let pid = self.currentProcessIdentifier() else { return nil }
        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(pid, &status, 0)
            if result == pid {
                return Self.exitCode(fromWaitStatus: status)
            }
            if result == -1, errno == EINTR {
                continue
            }
            return nil
        }
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

        var defaultSignals = sigset_t()
        try Self.check(sigemptyset(&defaultSignals), "initialize child default signals")
        try Self.check(sigaddset(&defaultSignals, SIGINT), "add child SIGINT default")
        try Self.check(sigaddset(&defaultSignals, SIGTERM), "add child SIGTERM default")
        try Self.check(
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            "set child default signals"
        )
        var emptySignalMask = sigset_t()
        try Self.check(sigemptyset(&emptySignalMask), "initialize child signal mask")
        try Self.check(posix_spawnattr_setsigmask(&attributes, &emptySignalMask), "clear child signal mask")
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        )
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

        guard let processStartIdentity = self.processStartIdentityProvider(pid) else {
            self.terminateUnreleasedProcess(pid: pid)
            throw CaptureActionProcessLaunchError(
                message: "Action process identity was unavailable before release",
                refusalReason: .runtimeIncompatible
            )
        }
        self.lock.lock()
        self.processStartIdentity = processStartIdentity
        self.lock.unlock()
    }

    private nonisolated func terminateUnreleasedProcess(
        pid: pid_t,
        allowingCommittedRelease: Bool = false
    ) {
        self.lock.lock()
        guard !self.unreleasedCleanupStarted,
              allowingCommittedRelease || !self.processReleased
        else {
            self.lock.unlock()
            return
        }
        self.unreleasedCleanupStarted = true
        self.lock.unlock()
        self.killProcessGroup(pid: pid, signal: SIGKILL)
        _ = Darwin.kill(pid, SIGKILL)
        var waitStatus: Int32 = 0
        while true {
            let result = Darwin.waitpid(pid, &waitStatus, 0)
            if result == pid || (result == -1 && errno != EINTR) {
                break
            }
        }
        self.markFinishedWaiting()
    }

    private nonisolated func installOutputHandlers() {
        self.stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, stdoutOutput] handle in
            self?.consumeAvailableOutput(from: handle, into: stdoutOutput)
        }
        self.stderrPipe.fileHandleForReading.readabilityHandler = { [weak self, stderrOutput] handle in
            self?.consumeAvailableOutput(from: handle, into: stderrOutput)
        }
    }

    private nonisolated func consumeAvailableOutput(from handle: FileHandle, into output: BoundedPipeOutput) {
        self.outputHandlerLock.withLock {
            guard !self.outputFinished else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                output.append(chunk)
            }
        }
    }

    private nonisolated func requestTimeoutTermination(observedAtNs: UInt64) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.forceStop,
              !self.timedOut,
              let pid = self.processIdentifier,
              self.processReleased,
              !self.didFinishWaiting
        else { return }
        self.timedOut = true
        self.terminationRequestedAtNs = observedAtNs
        self.killProcessGroup(pid: pid, signal: SIGTERM)
    }

    private nonisolated func sendTerminationKillIfDue(
        observedAtNs: UInt64,
        abandonDeadlineNs: UInt64
    ) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.terminationKillSent,
              let requestedAtNs = self.terminationRequestedAtNs,
              let pid = self.processIdentifier,
              self.processReleased,
              !self.didFinishWaiting
        else { return }
        let graceNs = UInt64(CaptureActionProcessRunner.processGroupTerminationGraceSeconds * 1_000_000_000)
        let (unboundedKillDeadlineNs, overflowed) = requestedAtNs.addingReportingOverflow(graceNs)
        let killDeadlineNs = min(overflowed ? UInt64.max : unboundedKillDeadlineNs, abandonDeadlineNs)
        guard observedAtNs >= killDeadlineNs else { return }
        self.terminationKillSent = true
        self.killProcessGroup(pid: pid, signal: SIGKILL)
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

    private nonisolated func markLeaderExit(observedAtNs: UInt64, timeoutDeadlineNs: UInt64) {
        self.lock.lock()
        if CaptureActionProcessDeadline.hasExpired(
            observedAtNanoseconds: observedAtNs,
            deadlineNanoseconds: timeoutDeadlineNs
        ) {
            self.timedOut = true
        }
        self.didFinishWaiting = true
        self.lock.unlock()
    }

    private nonisolated func killProcessGroup(pid: pid_t, signal: Int32) {
        self.signalProcessGroup(pid, signal)
    }

    private nonisolated func waitForProcessGroupExit(pid: pid_t, deadlineNs: UInt64) -> Bool {
        repeat {
            guard let members = self.processGroupMembersExcludingLeader(pid: pid) else {
                return false
            }
            if members.isEmpty {
                return true
            }
            usleep(10000)
        } while DispatchTime.now().uptimeNanoseconds < deadlineNs
        return self.processGroupMembersExcludingLeader(pid: pid)?.isEmpty == true
    }

    private nonisolated func processGroupMembersExcludingLeader(pid: pid_t) -> [pid_t]? {
        let requiredBytes = proc_listpids(
            UInt32(PROC_PGRP_ONLY),
            UInt32(pid),
            nil,
            0
        )
        guard requiredBytes > 0 else { return nil }
        var capacity = max(32, Int(requiredBytes) / MemoryLayout<pid_t>.size + 32)
        for _ in 0..<6 {
            var identifiers = [pid_t](repeating: 0, count: capacity)
            let bufferBytes = identifiers.count * MemoryLayout<pid_t>.size
            let returnedBytes = proc_listpids(
                UInt32(PROC_PGRP_ONLY),
                UInt32(pid),
                &identifiers,
                Int32(bufferBytes)
            )
            guard returnedBytes > 0 else { return nil }
            if Int(returnedBytes) < bufferBytes {
                let count = Int(returnedBytes) / MemoryLayout<pid_t>.size
                return identifiers.prefix(count).filter { $0 > 0 && $0 != pid }
            }
            let returnedCount = Int(returnedBytes) / MemoryLayout<pid_t>.size
            let (doubled, overflow) = capacity.multipliedReportingOverflow(by: 2)
            guard !overflow else { return nil }
            capacity = max(doubled, returnedCount + 32)
        }
        return nil
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
    nonisolated static let processGroupTerminationGraceSeconds: TimeInterval = 0.5
    nonisolated static let processGroupKillGraceSeconds: TimeInterval = 1.0
    nonisolated static let processGroupDeadlineMarginSeconds: TimeInterval = 0.5
    nonisolated static let completionReserveSeconds =
        CaptureActionProcessRunner.processGroupTerminationGraceSeconds +
        CaptureActionProcessRunner.processGroupKillGraceSeconds +
        CaptureActionProcessRunner.processGroupDeadlineMarginSeconds

    private nonisolated static let leaderWaitQueue = DispatchQueue(
        label: "boo.peekaboo.capture-action.wait",
        qos: .userInitiated,
        attributes: .concurrent
    )

    nonisolated static func run(
        command: [String],
        timeoutSeconds: TimeInterval,
        completionDeadlineNanoseconds: UInt64? = nil,
        onLaunch: @escaping @Sendable (UInt64) -> Void = { _ in }
    ) async throws -> CaptureActionProcessResult {
        try await self.run(
            command: command,
            timeoutSeconds: timeoutSeconds,
            completionDeadlineNanoseconds: completionDeadlineNanoseconds,
            onLaunch: onLaunch,
            signalProcessGroup: { pid, signal in
                _ = Darwin.kill(-pid, signal)
            },
            processStartIdentity: { SystemIdentityResolver.processStartIdentity($0) }
        )
    }

    nonisolated static func run(
        command: [String],
        timeoutSeconds: TimeInterval,
        completionDeadlineNanoseconds: UInt64? = nil,
        onLaunch: @escaping @Sendable (UInt64) -> Void = { _ in },
        signalProcessGroup: @escaping @Sendable (pid_t, Int32) -> Void,
        processStartIdentity: @escaping @Sendable (pid_t) -> UInt64? = {
            SystemIdentityResolver.processStartIdentity($0)
        },
        blockingWaitStartDelayNanoseconds: UInt64 = 0,
        blockTerminationSignalsBeforeSpawnForTesting: Bool = false,
        completionResumeDelayNanoseconds: UInt64 = 0
    ) async throws -> CaptureActionProcessResult {
        guard timeoutSeconds.isFinite,
              timeoutSeconds >= 0,
              timeoutSeconds <= Double(UInt64.max) / 1_000_000_000.0
        else {
            throw CaptureActionProcessLaunchError(
                message: "Action timeout cannot be represented as a monotonic deadline",
                refusalReason: .invalidRequest
            )
        }
        // Start the budget before suspended spawn/identity work and cap every later TERM/KILL wait
        // to the caller's one completion deadline; no cleanup phase receives a fresh escape window.
        let invokedNs = DispatchTime.now().uptimeNanoseconds
        let timeoutNs = UInt64((timeoutSeconds * 1_000_000_000.0).rounded(.down))
        let reserveNs = UInt64(self.completionReserveSeconds * 1_000_000_000.0)
        let (configuredTimeoutDeadlineNs, timeoutOverflow) = invokedNs.addingReportingOverflow(timeoutNs)
        let (derivedCompletionDeadlineNs, completionOverflow) =
            (timeoutOverflow ? UInt64.max : configuredTimeoutDeadlineNs).addingReportingOverflow(reserveNs)
        let effectiveCompletionDeadlineNs = completionDeadlineNanoseconds ??
            (completionOverflow ? UInt64.max : derivedCompletionDeadlineNs)
        guard effectiveCompletionDeadlineNs > reserveNs else {
            throw CaptureActionProcessLaunchError(
                message: "Action completion deadline leaves no process cleanup budget",
                refusalReason: .invalidRequest
            )
        }
        let latestTimeoutDeadlineNs = effectiveCompletionDeadlineNs - reserveNs
        let effectiveTimeoutDeadlineNs = min(
            timeoutOverflow ? UInt64.max : configuredTimeoutDeadlineNs,
            latestTimeoutDeadlineNs
        )
        guard invokedNs < effectiveTimeoutDeadlineNs else {
            throw CaptureActionProcessLaunchError(
                message: "Action completion deadline elapsed before process preparation",
                refusalReason: .invalidRequest
            )
        }

        let box = CaptureActionProcessBox(
            signalProcessGroup: signalProcessGroup,
            processStartIdentityProvider: processStartIdentity
        )
        let signalForwarder = CaptureActionSignalForwarder { signalNumber in
            box.forwardSignalToProcessGroup(signalNumber)
        }
        defer { signalForwarder.cancel() }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try self.startProcessBox(
                box,
                command: command,
                blockTerminationSignalsForTesting: blockTerminationSignalsBeforeSpawnForTesting
            )
            defer { box.terminateUnreleasedIfNeeded() }
            try Task.checkCancellation()
            let startedNs = try box.release(before: effectiveTimeoutDeadlineNs)
            onLaunch(startedNs)

            let completion = await self.completeBlockingLifecycle(
                box: box,
                timeoutDeadlineNs: effectiveTimeoutDeadlineNs,
                abandonDeadlineNs: effectiveCompletionDeadlineNs,
                startDelayNanoseconds: blockingWaitStartDelayNanoseconds,
                resumeDelayNanoseconds: completionResumeDelayNanoseconds
            )
            let completedNs = completion.completedAtMonotonicNanoseconds
            let durationMs = Int(completedNs >= startedNs ? (completedNs - startedNs) / 1_000_000 : 0)
            let launchIdentity = box.launchIdentity()

            guard completedNs <= effectiveCompletionDeadlineNs,
                  completion.processGroupCleaned,
                  let exitCode = completion.exitCode,
                  let launchIdentity
            else {
                throw CaptureActionProcessLaunchError(
                    message: "Action process group could not be fully terminated"
                )
            }

            let effectiveTimeoutSeconds = Double(effectiveTimeoutDeadlineNs - invokedNs) / 1_000_000_000.0
            return CaptureActionProcessResult(
                command: command,
                processIdentifier: launchIdentity.processIdentifier,
                processStartIdentity: launchIdentity.processStartIdentity,
                exitCode: exitCode,
                timedOut: box.wasTimedOut(),
                processGroupCleaned: completion.processGroupCleaned,
                timeoutSeconds: effectiveTimeoutSeconds,
                durationMs: durationMs,
                stdout: completion.stdout,
                stderr: completion.stderr,
                stdoutTruncated: completion.stdoutTruncated,
                stderrTruncated: completion.stderrTruncated,
                completedAtMonotonicNanoseconds: completedNs
            )
        } onCancel: {
            box.terminateProcessGroupForCancellation()
        }
    }

    private nonisolated static func completeBlockingLifecycle(
        box: CaptureActionProcessBox,
        timeoutDeadlineNs: UInt64,
        abandonDeadlineNs: UInt64,
        startDelayNanoseconds: UInt64,
        resumeDelayNanoseconds: UInt64
    ) async -> CaptureActionBlockingCompletion {
        await withCheckedContinuation { continuation in
            self.leaderWaitQueue.async {
                if startDelayNanoseconds > 0 {
                    usleep(useconds_t(min(startDelayNanoseconds / 1000, UInt64(useconds_t.max))))
                }
                let completion = box.completeBlockingLifecycle(
                    timeoutDeadlineNs: timeoutDeadlineNs,
                    abandonDeadlineNs: abandonDeadlineNs
                )
                if resumeDelayNanoseconds > 0 {
                    usleep(useconds_t(min(resumeDelayNanoseconds / 1000, UInt64(useconds_t.max))))
                }
                continuation.resume(returning: completion)
            }
        }
    }

    private nonisolated static func startProcessBox(
        _ box: CaptureActionProcessBox,
        command: [String],
        blockTerminationSignalsForTesting: Bool
    ) throws {
        guard blockTerminationSignalsForTesting else {
            try box.start(command: command)
            return
        }

        var blockedSignals = sigset_t()
        var previousSignals = sigset_t()
        try self.checkPOSIX(sigemptyset(&blockedSignals), "initialize test signal mask")
        try self.checkPOSIX(sigaddset(&blockedSignals, SIGINT), "add test SIGINT mask")
        try self.checkPOSIX(sigaddset(&blockedSignals, SIGTERM), "add test SIGTERM mask")
        try self.checkPOSIX(
            pthread_sigmask(SIG_BLOCK, &blockedSignals, &previousSignals),
            "block parent termination signals for testing"
        )
        defer { _ = pthread_sigmask(SIG_SETMASK, &previousSignals, nil) }
        try box.start(command: command)
    }

    private nonisolated static func checkPOSIX(_ code: Int32, _ operation: String) throws {
        guard code == 0 else {
            throw CaptureActionProcessLaunchError(
                message: "\(operation) failed: \(String(cString: strerror(code)))"
            )
        }
    }
}
