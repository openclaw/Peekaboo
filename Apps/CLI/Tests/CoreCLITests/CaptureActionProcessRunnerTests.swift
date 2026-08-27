import Darwin
import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooCLI

@Suite(.serialized)
struct CaptureActionProcessRunnerTests {
    @Test
    func `stale signal source generation cannot reach a replacement runner`() throws {
        let coordinator = CaptureActionSignalCoordinator()
        let oldRecorder = CaptureActionSignalRecorder()
        let oldRegistration = coordinator.register { oldRecorder.record($0) }
        let oldGeneration = try #require(coordinator.activeGenerationForTesting)
        coordinator.unregister(oldRegistration)

        let replacementRecorder = CaptureActionSignalRecorder()
        let replacementRegistration = coordinator.register { replacementRecorder.record($0) }
        defer { coordinator.unregister(replacementRegistration) }
        let replacementGeneration = try #require(coordinator.activeGenerationForTesting)
        #expect(replacementGeneration != oldGeneration)

        coordinator.forwardForTesting(SIGTERM, generation: oldGeneration)
        #expect(replacementRecorder.signals.isEmpty)
        coordinator.forwardForTesting(SIGTERM, generation: replacementGeneration)
        #expect(replacementRecorder.signals == [SIGTERM])
    }

    @Test
    func `deadline boundary expires at equality`() {
        #expect(!CaptureActionProcessDeadline.hasExpired(
            observedAtNanoseconds: 99,
            deadlineNanoseconds: 100
        ))
        #expect(CaptureActionProcessDeadline.hasExpired(
            observedAtNanoseconds: 100,
            deadlineNanoseconds: 100
        ))
        #expect(CaptureActionProcessDeadline.hasExpired(
            observedAtNanoseconds: 101,
            deadlineNanoseconds: 100
        ))
    }

    @Test
    func `blocking waiter owns timeout when its start is delayed`() async throws {
        let result = try await CaptureActionProcessRunner.run(
            command: ["/bin/sleep", "30"],
            timeoutSeconds: 0.05,
            signalProcessGroup: { pid, signal in
                _ = Darwin.kill(-pid, signal)
            },
            blockingWaitStartDelayNanoseconds: 1_000_000_000
        )

        #expect(result.exitCode == 128 + SIGTERM)
        #expect(result.timedOut)
        #expect(result.processGroupCleaned)
        #expect(!result.succeeded)
    }

    @Test
    func `absolute completion deadline charges suspended startup before release`() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-action-startup-deadline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("child-ran")
        let launchRecorder = CaptureActionLaunchRecorder()
        let completionDeadlineNs = DispatchTime.now().uptimeNanoseconds + 2_200_000_000

        let thrown = await #expect(throws: (any Error).self) {
            _ = try await CaptureActionProcessRunner.run(
                command: ["/usr/bin/touch", marker.path],
                timeoutSeconds: 5,
                completionDeadlineNanoseconds: completionDeadlineNs,
                onLaunch: { _ in launchRecorder.record() },
                signalProcessGroup: { pid, signal in
                    _ = Darwin.kill(-pid, signal)
                },
                processStartIdentity: { pid in
                    usleep(300_000)
                    return SystemIdentityResolver.processStartIdentity(pid)
                }
            )
        }

        #expect(try #require(thrown).localizedDescription.contains("before process release"))
        #expect(!launchRecorder.wasRecorded)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func `result reports the effective absolute timeout budget`() async throws {
        let completionDeadlineNs = DispatchTime.now().uptimeNanoseconds + 2_300_000_000
        let result = try await CaptureActionProcessRunner.run(
            command: ["/usr/bin/true"],
            timeoutSeconds: 5,
            completionDeadlineNanoseconds: completionDeadlineNs
        )

        #expect(result.succeeded)
        #expect(result.timeoutSeconds > 0.1)
        #expect(result.timeoutSeconds <= 0.3)
    }

    @Test
    func `runner completion boundary excludes continuation delay`() async throws {
        let result = try await CaptureActionProcessRunner.run(
            command: ["/usr/bin/true"],
            timeoutSeconds: 2,
            signalProcessGroup: { pid, signal in
                _ = Darwin.kill(-pid, signal)
            },
            completionResumeDelayNanoseconds: 500_000_000
        )

        #expect(result.succeeded)
        #expect(result.durationMs < 250)
    }

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
    func `spawn restores default TERM handling after coordinator installation`() async throws {
        let result = try await CaptureActionProcessRunner.run(
            command: ["/bin/sleep", "30"],
            timeoutSeconds: 0.1,
            signalProcessGroup: { pid, signal in
                _ = Darwin.kill(-pid, signal)
            },
            blockTerminationSignalsBeforeSpawnForTesting: true
        )

        #expect(result.timedOut)
        #expect(result.exitCode == 128 + SIGTERM)
        #expect(result.processGroupCleaned)
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
            timeoutSeconds: 0.5,
            signalProcessGroup: { pid, signal in
                _ = Darwin.kill(-pid, signal)
            },
            blockingWaitStartDelayNanoseconds: 1_000_000_000
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
        do {
            _ = try await CaptureActionProcessRunner.run(
                command: ["/bin/sleep", "30"],
                timeoutSeconds: 0.1,
                signalProcessGroup: { pid, signal in
                    ignoredSignals.record(pid: pid, signal: signal)
                }
            )
            Issue.record("Expected process-group cleanup failure")
        } catch {
            #expect(error.localizedDescription == "Action process group could not be fully terminated")
        }

        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 3)
        #expect(elapsed >= 2)
        #expect(ignoredSignals.signals.contains(SIGTERM))
        #expect(ignoredSignals.signals.contains(SIGKILL))

        let pid = try #require(ignoredSignals.processIdentifier)
        _ = Darwin.kill(-pid, SIGKILL)
        try await Self.waitUntilProcessIsGone(pid)
    }

    @Test
    func `late leader exit cannot grant descendants a fresh drain deadline`() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-action-shared-drain-deadline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let descendantPIDFile = root.appendingPathComponent("descendant-pid")
        let ignoredSignals = IgnoredProcessGroupSignals()
        let started = Date()
        let completionDeadlineNs = DispatchTime.now().uptimeNanoseconds + 2_300_000_000

        let thrown = await #expect(throws: (any Error).self) {
            _ = try await CaptureActionProcessRunner.run(
                command: [
                    "/usr/bin/perl",
                    "-e",
                    "if (fork() == 0) { open(my $p, '>', $ARGV[0]) or die $!; " +
                        "print $p \"$$\\n\"; close($p); sleep 30; exit 0; } " +
                        "select undef, undef, undef, 2.1; exit 0;",
                    descendantPIDFile.path,
                ],
                timeoutSeconds: 10,
                completionDeadlineNanoseconds: completionDeadlineNs,
                signalProcessGroup: { pid, signal in
                    ignoredSignals.record(pid: pid, signal: signal)
                }
            )
        }

        let elapsed = Date().timeIntervalSince(started)
        #expect(try #require(thrown).localizedDescription == "Action process group could not be fully terminated")
        #expect(elapsed >= 2.1)
        #expect(elapsed < 2.8)
        let descendantPID = try #require(pid_t(
            String(contentsOf: descendantPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        _ = Darwin.kill(descendantPID, SIGKILL)
        try await Self.waitUntilProcessIsGone(descendantPID)
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
    func `fast child output retains its final bytes`() async throws {
        for index in 0..<50 {
            let expected = "capture-output-\(index)-tail"
            let result = try await CaptureActionProcessRunner.run(
                command: ["/usr/bin/printf", "%s", expected],
                timeoutSeconds: 2
            )
            #expect(result.stdout == expected)
            #expect(!result.stdoutTruncated)
        }
    }

    @Test
    func `runner terminates a background child that inherits output pipes`() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-action-pipe-child-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        let release = root.appendingPathComponent("release")
        let marker = root.appendingPathComponent("survived")
        let result = try await CaptureActionProcessRunner.run(
            command: [
                "/usr/bin/perl",
                "-e",
                "if (fork() == 0) { open(my $ready, '>', $ARGV[0]) or die $!; close($ready); " +
                    "while (!-e $ARGV[1]) { select undef, undef, undef, 0.01; } " +
                    "open(my $marker, '>', $ARGV[2]) or die $!; close($marker); exit 0; } " +
                    "while (!-e $ARGV[0]) { select undef, undef, undef, 0.01; } exit 0;",
                ready.path,
                release.path,
                marker.path,
            ],
            timeoutSeconds: 5
        )

        #expect(result.exitCode == 0)
        #expect(result.timedOut == false)
        #expect(result.processGroupCleaned == true)
        try Data().write(to: release)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func `normal child exit cleans descendants before returning`() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-action-normal-exit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ready = root.appendingPathComponent("descendant-ready")
        let release = root.appendingPathComponent("release-descendant")
        let marker = root.appendingPathComponent("descendant-survived")
        let result = try await CaptureActionProcessRunner.run(
            command: [
                "/usr/bin/perl",
                "-e",
                "use POSIX (); if (fork() == 0) { $SIG{TERM} = 'IGNORE'; " +
                    "open(my $ready, '>', $ARGV[0]) or die $!; " +
                    "print $ready \"$$ \" . POSIX::getpgrp() . \"\\n\"; close($ready); " +
                    "while (!-e $ARGV[1]) { select undef, undef, undef, 0.01; } " +
                    "open(my $marker, '>', $ARGV[2]) or die $!; close($marker); exit 0; } " +
                    "while (!-e $ARGV[0]) { select undef, undef, undef, 0.01; } exit 0;",
                ready.path,
                release.path,
                marker.path,
            ],
            timeoutSeconds: 5
        )

        #expect(result.exitCode == 0)
        #expect(result.processGroupCleaned == true)
        try Data().write(to: release)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
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

        let ready = root.appendingPathComponent("descendant-ready")
        let release = root.appendingPathComponent("release-descendant")
        let marker = root.appendingPathComponent("descendant-survived")
        let task = Task {
            try await CaptureActionProcessRunner.run(
                command: [
                    "/usr/bin/perl",
                    "-e",
                    "if (fork() == 0) { $SIG{TERM} = 'IGNORE'; " +
                        "open(my $ready, '>', $ARGV[0]) or die $!; close($ready); " +
                        "while (!-e $ARGV[1]) { select undef, undef, undef, 0.01; } " +
                        "open(my $marker, '>', $ARGV[2]) or die $!; close($marker); exit 0; } wait;",
                    ready.path,
                    release.path,
                    marker.path,
                ],
                timeoutSeconds: 5
            )
        }

        try await Self.waitUntilFileExists(ready)
        task.cancel()
        _ = try? await task.value

        try Data().write(to: release)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }

    @Test
    func `missing process identity refuses before child release`() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-action-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("child-ran")

        let thrown = await #expect(throws: (any Error).self) {
            _ = try await CaptureActionProcessRunner.run(
                command: ["/usr/bin/touch", marker.path],
                timeoutSeconds: 1,
                signalProcessGroup: { pid, signal in
                    _ = Darwin.kill(-pid, signal)
                },
                processStartIdentity: { _ in nil }
            )
        }

        #expect(try #require(thrown).localizedDescription ==
            "Action process identity was unavailable before release")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func `cancellation during identity capture refuses before child release`() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-action-pre-release-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("child-ran")
        let identityGate = BlockingProcessIdentityProvider()
        let launchRecorder = CaptureActionLaunchRecorder()
        let task = Task.detached {
            try await CaptureActionProcessRunner.run(
                command: ["/usr/bin/touch", marker.path],
                timeoutSeconds: 5,
                onLaunch: { _ in launchRecorder.record() },
                signalProcessGroup: { pid, signal in
                    _ = Darwin.kill(-pid, signal)
                },
                processStartIdentity: { identityGate.resolve(processIdentifier: $0) }
            )
        }

        try await identityGate.waitUntilEntered()
        task.cancel()
        identityGate.release()
        let thrown = await #expect(throws: (any Error).self) {
            _ = try await task.value
        }

        #expect(try #require(thrown) is CancellationError)
        #expect(!launchRecorder.wasRecorded)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        if let processIdentifier = identityGate.processIdentifier {
            try await Self.waitUntilProcessIsGone(processIdentifier)
        } else {
            Issue.record("Identity provider did not observe the suspended child")
        }
    }

    @Test
    func `concurrent runners do not starve cancellation or timeout cleanup`() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-action-concurrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runnerCount = 12
        let cancellationCount = runnerCount / 2
        let readyFiles = (0..<runnerCount).map { root.appendingPathComponent("ready-\($0)") }
        let lateMarkers = (0..<runnerCount).map { root.appendingPathComponent("late-\($0)") }
        let tasks = zip(readyFiles.indices, zip(readyFiles, lateMarkers)).map { item in
            let (index, pair) = item
            let (ready, marker) = pair
            return Task {
                try await CaptureActionProcessRunner.run(
                    command: [
                        "/usr/bin/perl",
                        "-e",
                        "if (fork() == 0) { $SIG{TERM} = 'IGNORE'; " +
                            "open(my $r, '>', $ARGV[0]) or die $!; close($r); sleep 10; " +
                            "open(my $m, '>', $ARGV[1]) or die $!; close($m); exit 0; } wait;",
                        ready.path,
                        marker.path,
                    ],
                    timeoutSeconds: index < cancellationCount ? 30 : 0.75
                )
            }
        }

        for ready in readyFiles {
            try await Self.waitUntilFileExists(ready, timeoutSeconds: 5)
        }
        let cancellationStarted = ContinuousClock.now
        tasks.prefix(cancellationCount).forEach { $0.cancel() }
        var results: [CaptureActionProcessResult] = []
        for task in tasks {
            if let result = try? await task.value {
                results.append(result)
            }
        }
        let elapsed = cancellationStarted.duration(to: .now)

        #expect(elapsed < .seconds(3))
        #expect(results.count == runnerCount)
        #expect(results.prefix(cancellationCount).allSatisfy { !$0.timedOut })
        #expect(results.suffix(runnerCount - cancellationCount).allSatisfy { result in
            result.timedOut && result.durationMs < 2500
        })
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(lateMarkers.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
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

private final nonisolated class CaptureActionLaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = false

    var wasRecorded: Bool {
        self.lock.withLock { self.recorded }
    }

    func record() {
        self.lock.withLock { self.recorded = true }
    }
}

private final nonisolated class CaptureActionSignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSignals: [Int32] = []

    var signals: [Int32] {
        self.lock.withLock { self.recordedSignals }
    }

    func record(_ signalNumber: Int32) {
        self.lock.withLock { self.recordedSignals.append(signalNumber) }
    }
}

private final nonisolated class BlockingProcessIdentityProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var capturedProcessIdentifier: pid_t?

    var processIdentifier: pid_t? {
        self.lock.withLock { self.capturedProcessIdentifier }
    }

    func resolve(processIdentifier: pid_t) -> UInt64? {
        self.lock.withLock {
            self.capturedProcessIdentifier = processIdentifier
            self.entered = true
        }
        self.releaseSemaphore.wait()
        return SystemIdentityResolver.processStartIdentity(processIdentifier)
    }

    func release() {
        self.releaseSemaphore.signal()
    }

    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if self.lock.withLock({ self.entered }) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for suspended process identity capture")
    }
}
