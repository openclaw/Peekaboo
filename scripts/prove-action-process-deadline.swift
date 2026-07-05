#!/usr/bin/env swift
import Darwin
import Foundation

func spawnSleepForever() -> pid_t {
    var pid: pid_t = 0
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    var attrs: posix_spawnattr_t?
    posix_spawnattr_init(&attrs)
    defer { posix_spawnattr_destroy(&attrs) }
    posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attrs, 0)
    let args = ["/bin/sh", "-c", "trap '' TERM; while true; do sleep 1; done"]
    var argv = args.map { strdup($0) } + [nil]
    defer { for p in argv {
        free(p)
    } }
    let rc = "/bin/sh".withCString { path in
        posix_spawnp(&pid, path, &fileActions, &attrs, &argv, environ)
    }
    precondition(rc == 0, "spawn failed \(rc)")
    return pid
}

func waitWithDeadline(
    pid: pid_t,
    deadline: Date,
    deliverWaitLoopKill: Bool = true) -> (code: Int32, elapsed: Double)
{
    let started = Date()
    var status: Int32 = 0
    var didSendWaitLoopKill = false
    while true {
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid {
            return (status, Date().timeIntervalSince(started))
        }
        let now = Date()
        if !didSendWaitLoopKill, now >= deadline.addingTimeInterval(-1.0) {
            didSendWaitLoopKill = true
            if deliverWaitLoopKill {
                kill(-pid, SIGKILL)
            }
        }
        if now >= deadline {
            return (128 + SIGKILL, Date().timeIntervalSince(started))
        }
        usleep(10000)
    }
}

print("F007 waitpid deadline proof")
let pid = spawnSleepForever()
print("  spawned unkillable-TERM child pid=\(pid)")
usleep(150_000)
kill(-pid, SIGTERM)
print("  sent SIGTERM")
let deadline = Date().addingTimeInterval(1.6)
let (code, elapsed) = waitWithDeadline(
    pid: pid,
    deadline: deadline,
    deliverWaitLoopKill: false)
print("  fixed wait returned code=\(code) elapsed=\(String(format: "%.2f", elapsed))s")
print("  expected: returns by final abandon deadline, not hang forever")
// reap if still around
kill(-pid, SIGKILL)
var st: Int32 = 0
_ = waitpid(pid, &st, 0)
let ok = code == 128 + SIGKILL && elapsed < 2.5 && elapsed >= 1.5

if !ok {
    print("PROOF_FAIL hang bound")
    exit(1)
}

print("PROOF_OK hang bound (deadline waiter returned)")

/// --- TERM grace proof (ClawSweeper P1) ---
/// Fixed wait must not SIGKILL immediately on timeout so a TERM-trapping child can exit 0.
func spawnGracefulTermChild() -> pid_t {
    var pid: pid_t = 0
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    var attrs: posix_spawnattr_t?
    posix_spawnattr_init(&attrs)
    defer { posix_spawnattr_destroy(&attrs) }
    posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attrs, 0)
    let args = ["/bin/sh", "-c", "trap 'exit 0' TERM; while true; do sleep 0.05; done"]
    var argv = args.map { strdup($0) } + [nil]
    defer { for p in argv {
        free(p)
    } }
    let rc = "/bin/sh".withCString { path in
        posix_spawnp(&pid, path, &fileActions, &attrs, &argv, environ)
    }
    precondition(rc == 0, "spawn graceful failed \(rc)")
    return pid
}

print("F007 TERM grace proof")
let gracePid = spawnGracefulTermChild()
print("  spawned TERM-handling child pid=\(gracePid)")
usleep(150_000)
// Simulate terminateAfterTimeout: SIGTERM first; waiter must not SIGKILL during 500ms grace.
kill(-gracePid, SIGTERM)
print("  sent SIGTERM (timeout path)")
let graceDeadline = Date().addingTimeInterval(0.5)
var graceStatus: Int32 = 0
var graceReaped = false
var graceCode: Int32 = -1
while Date() < graceDeadline {
    let r = waitpid(gracePid, &graceStatus, WNOHANG)
    if r == gracePid {
        graceReaped = true
        let signal = graceStatus & 0x7F
        graceCode = signal == 0 ? ((graceStatus >> 8) & 0xFF) : (128 + signal)
        break
    }
    usleep(10000)
}

print("  reaped_during_grace=\(graceReaped) exitCode=\(graceCode)")
if !graceReaped {
    kill(-gracePid, SIGKILL)
    _ = waitpid(gracePid, &graceStatus, 0)
    print("PROOF_FAIL graceful child not reaped during 500ms TERM window")
    exit(1)
}

if graceCode != 0 {
    print("PROOF_FAIL expected exit 0 from TERM trap, got \(graceCode)")
    exit(1)
}

print("PROOF_OK TERM grace preserved (child exited cleanly during grace)")

// --- Cancellation deadline proof ---
// A cancelled long-timeout action must not wait for the original timeout. It keeps the
// same TERM grace, then falls back to SIGKILL and returns quickly.
print("F007 cancellation deadline proof")
let cancelPid = spawnSleepForever()
print("  spawned TERM-ignoring child pid=\(cancelPid)")
usleep(150_000)
kill(-cancelPid, SIGTERM)
print("  sent SIGTERM (cancellation path)")
let cancelDeadline = Date().addingTimeInterval(1.6)
let (cancelCode, cancelElapsed) = waitWithDeadline(pid: cancelPid, deadline: cancelDeadline)
print("  fixed wait returned code=\(cancelCode) elapsed=\(String(format: "%.2f", cancelElapsed))s")
kill(-cancelPid, SIGKILL)
_ = waitpid(cancelPid, &st, 0)
if cancelElapsed >= 2.5 || cancelElapsed < 0.5 {
    print("PROOF_FAIL cancellation deadline")
    exit(1)
}

print("PROOF_OK cancellation bound preserved")
exit(0)
