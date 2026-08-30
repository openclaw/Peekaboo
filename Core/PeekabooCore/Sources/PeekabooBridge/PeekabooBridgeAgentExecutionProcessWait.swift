import CryptoKit
import Darwin
import Dispatch
import Foundation
import PeekabooAutomationKit
import Security

struct PeekabooBridgeAgentExecutionTerminal: Sendable {
    let disposition: PeekabooBridgeAgentExecutionProcessDisposition
    let exitCode: Int32?
    let terminationSignal: Int32?
    let terminalObservationEndedAt: Int64
}

struct PeekabooBridgeAgentExecutionProcessCustody: Equatable, Sendable {
    let processIdentity: PeekabooBridgeOperationProcessIdentity
    let processIdentifierVersion: Int32
}

enum PeekabooBridgeAgentExecutionProcessWait {
    static func captureProcessCustody(
        processIdentity: PeekabooBridgeOperationProcessIdentity) throws
        -> PeekabooBridgeAgentExecutionProcessCustody
    {
        let processIdentifier = processIdentity.processIdentifier
        guard let token = self.auditToken(
            processIdentifier: processIdentifier,
            expectedProcessStartIdentity: processIdentity.processStartIdentity),
            audit_token_to_pid(token) == processIdentifier
        else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.executableIdentityChanged
        }
        return .init(
            processIdentity: processIdentity,
            processIdentifierVersion: audit_token_to_pidversion(token))
    }

    static func killSuspendedAndReap(_ processIdentifier: pid_t) {
        _ = Darwin.kill(processIdentifier, SIGKILL)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while ContinuousClock.now < deadline {
            var waitStatus: Int32 = 0
            let result = Darwin.waitpid(processIdentifier, &waitStatus, WNOHANG)
            if result == processIdentifier || (result < 0 && errno == ECHILD) {
                return
            }
            if result < 0, errno != EINTR {
                break
            }
            usleep(1000)
        }
        self.exactReaperQueue.async {
            var backoff: useconds_t = 1000
            while true {
                _ = Darwin.kill(processIdentifier, SIGKILL)
                var waitStatus: Int32 = 0
                let result = Darwin.waitpid(processIdentifier, &waitStatus, WNOHANG)
                if result == processIdentifier || (result < 0 && errno == ECHILD) {
                    return
                }
                usleep(backoff)
                backoff = min(backoff * 2, 100_000)
            }
        }
    }

    static func wait(
        _ processIdentifier: pid_t,
        processCustody: PeekabooBridgeAgentExecutionProcessCustody,
        timeoutMilliseconds: Int,
        pipeControl: PeekabooBridgeAgentExecutionPipeControl,
        terminationGraceMilliseconds: Int) async -> PeekabooBridgeAgentExecutionTerminal
    {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        while true {
            switch self.observeExitWithoutReaping(processIdentifier) {
            case .exited:
                // Closing a capture pipe after its byte budget is exhausted can make the
                // writer terminate with SIGPIPE before this poll observes the overflow.
                // That terminal signal is part of the overflow enforcement, not a clean
                // competing exit. Cancellation and timeout still lose to a completed child.
                let overflowed = pipeControl.didOverflow
                let forced: PeekabooBridgeAgentExecutionProcessDisposition? = overflowed ? .outputOverflow : nil
                return self.reapObserved(
                    processIdentifier,
                    processCustody: processCustody,
                    forced: forced)
            case .failed:
                return self.terminateAfterWaitFailure(
                    processCustody: processCustody)
            case .running:
                break
            }

            let forced: PeekabooBridgeAgentExecutionProcessDisposition? = if Task.isCancelled {
                .cancelled
            } else if pipeControl.didOverflow {
                .outputOverflow
            } else if ContinuousClock.now >= deadline {
                .timedOut
            } else {
                nil
            }
            if let forced {
                return await self.terminateAndReap(
                    processIdentifier,
                    processCustody: processCustody,
                    disposition: forced,
                    graceMilliseconds: terminationGraceMilliseconds)
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return await self.terminateAndReap(
                    processIdentifier,
                    processCustody: processCustody,
                    disposition: .cancelled,
                    graceMilliseconds: terminationGraceMilliseconds)
            }
        }
    }

    private static func terminateAndReap(
        _ processIdentifier: pid_t,
        processCustody: PeekabooBridgeAgentExecutionProcessCustody,
        disposition: PeekabooBridgeAgentExecutionProcessDisposition,
        graceMilliseconds: Int) async -> PeekabooBridgeAgentExecutionTerminal
    {
        _ = Darwin.kill(processIdentifier, SIGTERM)
        let graceDeadline = ContinuousClock.now.advanced(by: .milliseconds(graceMilliseconds))
        while ContinuousClock.now < graceDeadline {
            switch self.observeExitWithoutReaping(processIdentifier) {
            case .exited:
                return self.reapObserved(
                    processIdentifier,
                    processCustody: processCustody,
                    forced: disposition)
            case .failed:
                return self.terminateAfterWaitFailure(
                    processCustody: processCustody)
            case .running:
                break
            }
            await self.uncancellableDelay(milliseconds: 10)
        }
        _ = Darwin.kill(processIdentifier, SIGKILL)
        let killDeadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while ContinuousClock.now < killDeadline {
            _ = Darwin.kill(processIdentifier, SIGKILL)
            switch self.observeExitWithoutReaping(processIdentifier) {
            case .exited:
                return self.reapObserved(
                    processIdentifier,
                    processCustody: processCustody,
                    forced: disposition)
            case .failed:
                return self.terminateAfterWaitFailure(
                    processCustody: processCustody)
            case .running:
                await self.uncancellableDelay(milliseconds: 1)
            }
        }
        return self.terminateAfterWaitFailure(processCustody: processCustody)
    }

    #if DEBUG
    static func terminateAfterWaitFailureForTesting(
        processCustody: PeekabooBridgeAgentExecutionProcessCustody) -> PeekabooBridgeAgentExecutionTerminal
    {
        self.terminateAfterWaitFailure(processCustody: processCustody)
    }

    static func waitFailureSignalsReusedPIDForTesting(
        _ processIdentifier: pid_t,
        processIdentifierVersion: Int32,
        observedProcessIdentifierVersion: Int32) -> Bool
    {
        var signaled = false
        let custody = PeekabooBridgeAgentExecutionProcessCustody(
            processIdentity: .init(
                processIdentifier: processIdentifier,
                processStartIdentity: 100,
                codeSignatureHash: String(repeating: "a", count: 40)),
            processIdentifierVersion: processIdentifierVersion)
        _ = self.terminateAfterWaitFailure(
            processCustody: custody,
            signal: { token, _ in
                if audit_token_to_pidversion(token.pointee) == observedProcessIdentifierVersion {
                    signaled = true
                    return 0
                }
                return -1
            },
            reacquireExitedAnchor: { _ in false },
            reap: { _, _, _ in -1 })
        return signaled
    }

    static func waitFailureUsesAuditTokenForTesting(
        _ processIdentifier: pid_t,
        expectedProcessStartIdentity: UInt64,
        processIdentifierVersion: Int32) -> Bool
    {
        var deliveredExactToken = false
        let custody = PeekabooBridgeAgentExecutionProcessCustody(
            processIdentity: .init(
                processIdentifier: processIdentifier,
                processStartIdentity: expectedProcessStartIdentity,
                codeSignatureHash: String(repeating: "a", count: 40)),
            processIdentifierVersion: processIdentifierVersion)
        _ = self.terminateAfterWaitFailure(
            processCustody: custody,
            signal: { token, signal in
                deliveredExactToken = audit_token_to_pid(token.pointee) == processIdentifier &&
                    audit_token_to_pidversion(token.pointee) == processIdentifierVersion &&
                    signal == SIGKILL
                return 0
            },
            reacquireExitedAnchor: { _ in false },
            reap: { _, _, _ in -1 })
        return deliveredExactToken
    }

    static func retainExactReapForTesting(_ processCustody: PeekabooBridgeAgentExecutionProcessCustody) {
        self.retainExactReap(processCustody)
    }
    #endif

    private enum ExitObservation {
        case running
        case exited
        case failed
    }

    private static func observeExitWithoutReaping(_ processIdentifier: pid_t) -> ExitObservation {
        while true {
            var info = siginfo_t()
            let result = Darwin.waitid(
                P_PID,
                id_t(processIdentifier),
                &info,
                WEXITED | WNOHANG | WNOWAIT)
            if result == 0 {
                return info.si_pid == processIdentifier ? .exited : .running
            }
            if errno == EINTR {
                continue
            }
            return .failed
        }
    }

    private static func reapObserved(
        _ processIdentifier: pid_t,
        processCustody _: PeekabooBridgeAgentExecutionProcessCustody,
        forced: PeekabooBridgeAgentExecutionProcessDisposition?) -> PeekabooBridgeAgentExecutionTerminal
    {
        var waitStatus: Int32 = 0
        while true {
            let result = Darwin.waitpid(processIdentifier, &waitStatus, 0)
            if result == processIdentifier {
                return self.terminal(status: waitStatus, forced: forced)
            }
            if result < 0, errno == EINTR {
                continue
            }
            return .init(
                disposition: .waitFailed,
                exitCode: nil,
                terminationSignal: nil,
                terminalObservationEndedAt: PeekabooBridgeAgentExecutionCoding.nowMilliseconds())
        }
    }

    private static func terminateAfterWaitFailure(
        processCustody: PeekabooBridgeAgentExecutionProcessCustody,
        signal: (UnsafeMutablePointer<audit_token_t>, Int32) -> Int32 = {
            proc_signal_with_audittoken($0, $1)
        },
        reacquireExitedAnchor: (pid_t) -> Bool = {
            PeekabooBridgeAgentExecutionProcessWait.waitForExitedAnchor($0)
        },
        reap: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = { Darwin.waitpid($0, $1, $2) })
        -> PeekabooBridgeAgentExecutionTerminal
    {
        // Once waitid loses the WNOWAIT anchor, a raw numeric PID may already have been recycled.
        // Only the audit-token-bound signal may target the exact generation. Reaping remains
        // forbidden unless the same leader is reacquired as an unreaped WNOWAIT child.
        let processIdentifier = processCustody.processIdentity.processIdentifier
        var token = self.auditToken(processCustody)
        guard signal(&token, SIGKILL) == 0 else {
            return .init(
                disposition: .waitFailed,
                exitCode: nil,
                terminationSignal: nil,
                terminalObservationEndedAt: PeekabooBridgeAgentExecutionCoding.nowMilliseconds())
        }
        guard reacquireExitedAnchor(processIdentifier) else {
            self.retainExactReap(processCustody)
            return .init(
                disposition: .waitFailed,
                exitCode: nil,
                terminationSignal: nil,
                terminalObservationEndedAt: PeekabooBridgeAgentExecutionCoding.nowMilliseconds())
        }
        var waitStatus: Int32 = 0
        while true {
            let result = reap(processIdentifier, &waitStatus, 0)
            if result == processIdentifier {
                break
            }
            if result < 0, errno == EINTR {
                continue
            }
            self.retainExactReap(processCustody)
            break
        }
        return .init(
            disposition: .waitFailed,
            exitCode: nil,
            terminationSignal: nil,
            terminalObservationEndedAt: PeekabooBridgeAgentExecutionCoding.nowMilliseconds())
    }

    private static let exactReaperQueue = DispatchQueue(
        label: "boo.peekaboo.agent-execution-exact-reaper",
        qos: .userInitiated,
        attributes: .concurrent)

    private static func retainExactReap(_ processCustody: PeekabooBridgeAgentExecutionProcessCustody) {
        self.exactReaperQueue.async {
            let processIdentifier = processCustody.processIdentity.processIdentifier
            var backoff: useconds_t = 1000
            while true {
                switch self.observeExitWithoutReaping(processIdentifier) {
                case .exited:
                    // This runner is the child's sole waiter; custody reaches this queue only after
                    // the synchronous waiter stops. WNOWAIT therefore leaves the exact zombie (and
                    // its PID allocation) anchored until this waitpid. A zombie may no longer expose
                    // live proc_pidinfo, so reaping must not depend on rebuilding its token.
                    var waitStatus: Int32 = 0
                    let result = Darwin.waitpid(processIdentifier, &waitStatus, WNOHANG)
                    if result == processIdentifier || (result < 0 && errno == ECHILD) {
                        return
                    }
                case .running:
                    guard let observed = self.auditToken(
                        processIdentifier: processIdentifier,
                        expectedProcessStartIdentity: processCustody.processIdentity.processStartIdentity),
                        audit_token_to_pidversion(observed) == processCustody.processIdentifierVersion
                    else { return }
                    var token = self.auditToken(processCustody)
                    _ = proc_signal_with_audittoken(&token, SIGKILL)
                case .failed:
                    guard let observed = self.auditToken(
                        processIdentifier: processIdentifier,
                        expectedProcessStartIdentity: processCustody.processIdentity.processStartIdentity),
                        audit_token_to_pidversion(observed) == processCustody.processIdentifierVersion
                    else { return }
                    var token = self.auditToken(processCustody)
                    _ = proc_signal_with_audittoken(&token, SIGKILL)
                }
                usleep(backoff)
                backoff = min(backoff * 2, 100_000)
            }
        }
    }

    private struct UniqueProcessIdentity {
        var executableUUID: (UInt64, UInt64) = (0, 0)
        var uniqueIdentifier: UInt64 = 0
        var parentUniqueIdentifier: UInt64 = 0
        var processIdentifierVersion: Int32 = 0
        var originalParentProcessIdentifierVersion: Int32 = 0
        var reserved2: UInt64 = 0
        var reserved3: UInt64 = 0
    }

    private static func auditToken(
        processIdentifier: pid_t,
        expectedProcessStartIdentity: UInt64) -> audit_token_t?
    {
        let uniqueSize = Int32(MemoryLayout<UniqueProcessIdentity>.stride)
        guard uniqueSize == 56 else { return nil }
        var first = UniqueProcessIdentity()
        var second = UniqueProcessIdentity()
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(processIdentifier, 17, 0, &first, uniqueSize) == uniqueSize,
              proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize,
              proc_pidinfo(processIdentifier, 17, 0, &second, uniqueSize) == uniqueSize,
              first.processIdentifierVersion == second.processIdentifierVersion,
              first.uniqueIdentifier == second.uniqueIdentifier,
              bsd.pbi_pid == UInt32(bitPattern: processIdentifier)
        else { return nil }
        let observedStartIdentity = UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)
        guard observedStartIdentity == expectedProcessStartIdentity else { return nil }

        var token = audit_token_t()
        withUnsafeMutableBytes(of: &token) { bytes in
            let values = bytes.bindMemory(to: UInt32.self)
            values[5] = UInt32(bitPattern: processIdentifier)
            values[7] = UInt32(bitPattern: first.processIdentifierVersion)
        }
        guard audit_token_to_pid(token) == processIdentifier,
              audit_token_to_pidversion(token) == first.processIdentifierVersion
        else { return nil }
        return token
    }

    private static func waitForExitedAnchor(
        _ processIdentifier: pid_t,
        maximumScans: Int = 500,
        observe: (pid_t) -> ExitObservation = {
            PeekabooBridgeAgentExecutionProcessWait.observeExitWithoutReaping($0)
        },
        pause: () -> Void = { usleep(1000) }) -> Bool
    {
        for _ in 0..<maximumScans {
            switch observe(processIdentifier) {
            case .exited:
                return true
            case .running:
                pause()
            case .failed:
                return false
            }
        }
        return false
    }

    private static func auditToken(
        _ processCustody: PeekabooBridgeAgentExecutionProcessCustody) -> audit_token_t
    {
        var token = audit_token_t()
        withUnsafeMutableBytes(of: &token) { bytes in
            let values = bytes.bindMemory(to: UInt32.self)
            values[5] = UInt32(bitPattern: processCustody.processIdentity.processIdentifier)
            values[7] = UInt32(bitPattern: processCustody.processIdentifierVersion)
        }
        return token
    }

    private static func terminal(
        status: Int32,
        forced: PeekabooBridgeAgentExecutionProcessDisposition?) -> PeekabooBridgeAgentExecutionTerminal
    {
        let signal = status & 0x7F
        if signal == 0 {
            return .init(
                disposition: forced ?? .exited,
                exitCode: (status >> 8) & 0xFF,
                terminationSignal: nil,
                terminalObservationEndedAt: PeekabooBridgeAgentExecutionCoding.nowMilliseconds())
        }
        if signal != 0x7F {
            return .init(
                disposition: forced ?? .signaled,
                exitCode: nil,
                terminationSignal: signal,
                terminalObservationEndedAt: PeekabooBridgeAgentExecutionCoding.nowMilliseconds())
        }
        return .init(
            disposition: .waitFailed,
            exitCode: nil,
            terminationSignal: nil,
            terminalObservationEndedAt: PeekabooBridgeAgentExecutionCoding.nowMilliseconds())
    }

    private static func uncancellableDelay(milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .milliseconds(milliseconds))
            {
                continuation.resume()
            }
        }
    }
}

// MARK: - Coordination acknowledgement
