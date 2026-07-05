import Darwin
import Foundation
import Testing
@testable import PeekabooCLI

struct CaptureActionProcessRunnerTests {
    @Test
    func `runner escalates timeout for TERM ignoring child`() async throws {
        let started = Date()
        let result = try await CaptureActionProcessRunner.run(
            command: ["/bin/sh", "-c", "trap '' TERM; while true; do sleep 0.2; done"],
            timeoutSeconds: 0.1
        )

        #expect(result.timedOut == true)
        #expect(result.exitCode != 0)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test
    func `runner preserves TERM grace so graceful children can exit`() async throws {
        // Child traps TERM, writes a marker, and exits 0 within the 500 ms grace window.
        // waitUntilExit must not SIGKILL immediately when timedOut becomes true, or the
        // trap never runs and we observe a SIGKILL exit status instead.
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-action-term-grace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let marker = root.appendingPathComponent("graceful-exit")
        let ready = root.appendingPathComponent("ready")
        let started = Date()
        let result = try await CaptureActionProcessRunner.run(
            command: [
                "/usr/bin/perl",
                "-e",
                Self.gracefulTermHandlerScript,
                marker.path,
                ready.path,
            ],
            timeoutSeconds: 0.5
        )

        let elapsed = Date().timeIntervalSince(started)
        #expect(FileManager.default.fileExists(atPath: ready.path) == true)
        #expect(result.timedOut == true)
        #expect(result.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path) == true)
        // timeout + TERM handling should finish well under hard deadline; grace is 500ms
        #expect(elapsed < 2)
        #expect(elapsed >= 0.5)
    }

    @Test
    func `cancellation preserves TERM grace so graceful children can exit`() async throws {
        // Same grace contract as timeout: cancel sends SIGTERM, then 500 ms before SIGKILL.
        // waitUntilExit must not SIGKILL immediately on forceStop.
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-action-cancel-grace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let marker = root.appendingPathComponent("cancel-graceful-exit")
        let ready = root.appendingPathComponent("ready")
        let task = Task {
            try await CaptureActionProcessRunner.run(
                command: [
                    "/usr/bin/perl",
                    "-e",
                    Self.gracefulTermHandlerScript,
                    marker.path,
                    ready.path,
                ],
                timeoutSeconds: 5
            )
        }

        try await Self.waitUntilFileExists(ready)
        task.cancel()
        let result = try? await task.value

        // Allow the 500 ms cancellation TERM grace to complete.
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(FileManager.default.fileExists(atPath: marker.path) == true)
        if let result {
            #expect(result.exitCode == 0)
            #expect(result.timedOut == false)
        }
    }

    @Test
    func `cancellation returns quickly for TERM ignoring child with long timeout`() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-action-cancel-ignore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ready = root.appendingPathComponent("ready")
        let started = Date()
        let task = Task {
            try await CaptureActionProcessRunner.run(
                command: [
                    "/bin/sh",
                    "-c",
                    "trap '' TERM; touch \"$1\"; while true; do sleep 1; done",
                    "sh",
                    ready.path
                ],
                timeoutSeconds: 30
            )
        }

        try await Self.waitUntilFileExists(ready)
        task.cancel()
        let result = try await task.value
        let elapsed = Date().timeIntervalSince(started)

        #expect(result.timedOut == false)
        #expect(result.exitCode != 0)
        #expect(elapsed < 2.5)
    }

    @Test
    func `runner abandons deadline then eventually reaps child when signal delivery fails`() async throws {
        let ignoredSignals = IgnoredProcessGroupSignals()
        let started = Date()
        let result = try await CaptureActionProcessRunner.run(
            command: ["/bin/sleep", "30"],
            timeoutSeconds: 0.1,
            signalProcessGroup: { pid, signal in
                ignoredSignals.record(pid: pid, signal: signal)
            }
        )

        let elapsed = Date().timeIntervalSince(started)
        #expect(result.timedOut == true)
        #expect(result.exitCode == 128 + SIGKILL)
        #expect(elapsed < 3)
        #expect(elapsed >= 2)
        #expect(ignoredSignals.signals.contains(SIGTERM))
        #expect(ignoredSignals.signals.contains(SIGKILL))

        let pid = try #require(ignoredSignals.processIdentifier)
        _ = Darwin.kill(-pid, SIGKILL)
        try await Self.waitUntilProcessIsGone(pid)
    }

    @Test
    func `runner drains output while retaining bounded text`() async throws {
        let result = try await CaptureActionProcessRunner.run(
            command: ["/bin/sh", "-c", "yes x | head -c 70000; yes e | head -c 70000 >&2"],
            timeoutSeconds: 5
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.utf8.count == 64 * 1024)
        #expect(result.stderr.utf8.count == 64 * 1024)
        #expect(result.stdoutTruncated == true)
        #expect(result.stderrTruncated == true)
    }

    @Test
    func `runner returns when background child inherits output pipes`() async throws {
        let started = Date()
        let result = try await CaptureActionProcessRunner.run(
            command: ["/bin/sh", "-c", "sleep 2 &"],
            timeoutSeconds: 5
        )

        #expect(result.exitCode == 0)
        #expect(result.timedOut == false)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test
    func `timeout kills descendant processes`() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-action-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let marker = root.appendingPathComponent("descendant-survived")
        let result = try await CaptureActionProcessRunner.run(
            command: [
                "/bin/sh",
                "-c",
                "trap '' TERM; (trap '' TERM; sleep 1; touch \"$1\") & wait",
                "sh",
                marker.path,
            ],
            timeoutSeconds: 0.1
        )

        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(result.timedOut == true)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }

    @Test
    func `cancellation kills descendant processes`() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-action-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let marker = root.appendingPathComponent("descendant-survived")
        let task = Task {
            try await CaptureActionProcessRunner.run(
                command: [
                    "/bin/sh",
                    "-c",
                    "(trap '' TERM; sleep 1; touch \"$1\") & wait",
                    "sh",
                    marker.path,
                ],
                timeoutSeconds: 5
            )
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        _ = try? await task.value

        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }

    private static func waitUntilFileExists(_ url: URL, timeoutSeconds: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for \(url.path)")
    }

    private static func waitUntilProcessIsGone(_ pid: pid_t, timeoutSeconds: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for process \(pid) to be reaped")
    }

    private static let gracefulTermHandlerScript = """
    my ($marker, $ready) = @ARGV;
    $SIG{TERM} = sub {
        open(my $fh, '>', $marker) or die "marker: $!";
        print $fh "ok\\n";
        close($fh);
        exit 0;
    };
    open(my $fh, '>', $ready) or die "ready: $!";
    print $fh "ready\\n";
    close($fh);
    sleep 30;
    """
}

private final class IgnoredProcessGroupSignals: @unchecked Sendable {
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var recordedProcessIdentifier: pid_t?
    private nonisolated(unsafe) var recordedSignals: [Int32] = []

    nonisolated var processIdentifier: pid_t? {
        self.lock.withLock { self.recordedProcessIdentifier }
    }

    nonisolated var signals: [Int32] {
        self.lock.withLock { self.recordedSignals }
    }

    nonisolated func record(pid: pid_t, signal: Int32) {
        self.lock.withLock {
            self.recordedProcessIdentifier = pid
            self.recordedSignals.append(signal)
        }
    }
}
