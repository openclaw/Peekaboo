// Standalone proof for fix/daemon-poll-cancellation (PR #203).
// Demonstrates that daemon poll loops using `try? await Task.sleep`
// exit promptly when the task is cancelled, instead of spinning until
// the deadline expires.
//
// This reproduces the exact pattern from DaemonLaunchPolicy.swift:
// three poll loops (socket availability, launch readiness, shutdown)
// each with `try? await Task.sleep(nanoseconds:)` that swallows
// CancellationError.
//
// Usage: swiftc -parse-as-library -o /tmp/prove-daemon scripts/prove-daemon-poll-cancellation.swift && /tmp/prove-daemon

import Foundation

// --- Unfixed pattern: poll loop ignores cancellation ---
func unfixedDaemonPoll(timeoutSec: TimeInterval) async -> (loopCount: Int, elapsed: TimeInterval) {
    var count = 0
    let start = Date()
    let deadline = Date().addingTimeInterval(timeoutSec)

    while Date() < deadline {
        count += 1
        // Simulated daemon check (always returns nil = not ready)
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        // No cancellation check — loop runs until deadline
    }
    return (count, Date().timeIntervalSince(start))
}

// --- Fixed pattern: poll loop checks Task.isCancelled ---
func fixedDaemonPoll(timeoutSec: TimeInterval) async -> (loopCount: Int, elapsed: TimeInterval) {
    var count = 0
    let start = Date()
    let deadline = Date().addingTimeInterval(timeoutSec)

    while Date() < deadline {
        count += 1
        // Simulated daemon check (always returns nil = not ready)
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        guard !Task.isCancelled else { break }
    }
    return (count, Date().timeIntervalSince(start))
}

@main
struct Proof {
    static func main() async {
        print("=== Daemon poll-loop cancellation proof ===")
        print("Reproduces DaemonLaunchPolicy.swift poll pattern")
        print()

        let timeout: TimeInterval = 3.0 // 3-second deadline (matches launchDaemon default)

        // Test 1: Unfixed — loop runs until deadline despite cancellation
        print("Test 1: Unfixed pattern (try? swallows CancellationError)")
        print("  Timeout: \(String(format: "%.0f", timeout))s, cancel after 200ms")
        let unfixedTask = Task {
            await unfixedDaemonPoll(timeoutSec: timeout)
        }
        try? await Task.sleep(nanoseconds: 200_000_000) // cancel after 200ms
        unfixedTask.cancel()
        let unfixed = await unfixedTask.value
        print("  Loops executed: \(unfixed.loopCount)")
        print("  Elapsed: \(String(format: "%.0f", unfixed.elapsed * 1000))ms (ran until \(String(format: "%.0f", timeout))s deadline)")
        print()

        // Test 2: Fixed — loop exits after first sleep post-cancellation
        print("Test 2: Fixed pattern (Task.isCancelled guard after sleep)")
        print("  Timeout: \(String(format: "%.0f", timeout))s, cancel after 200ms")
        let fixedTask = Task {
            await fixedDaemonPoll(timeoutSec: timeout)
        }
        try? await Task.sleep(nanoseconds: 200_000_000) // cancel after 200ms
        fixedTask.cancel()
        let fixed = await fixedTask.value
        print("  Loops executed: \(fixed.loopCount)")
        print("  Elapsed: \(String(format: "%.0f", fixed.elapsed * 1000))ms (exited promptly)")
        print()

        // Verdict
        let unfixedRanFull = unfixed.elapsed > 2.0
        let fixedExitedEarly = fixed.elapsed < 1.0 && fixed.loopCount <= 5
        if unfixedRanFull && fixedExitedEarly {
            print("✅ PASS: Unfixed loop ran \(String(format: "%.1f", unfixed.elapsed))s (full timeout, ignores cancel)")
            print("✅ PASS: Fixed loop ran \(String(format: "%.0f", fixed.elapsed * 1000))ms (exits on cancel)")
            print("✅ The Task.isCancelled guard prevents daemon poll loops from wasting")
            print("   \(String(format: "%.0f", (unfixed.elapsed - fixed.elapsed) * 1000))ms of blocked time after cancellation.")
        } else {
            print("❌ FAIL: unexpected behavior")
            print("  unfixed: \(String(format: "%.1f", unfixed.elapsed))s, fixed: \(String(format: "%.0f", fixed.elapsed * 1000))ms")
        }
    }
}
