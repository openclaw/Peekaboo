import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import Testing
@testable import PeekabooCLI

struct DaemonLaunchPolicyTests {
    @Test
    func `daemon readiness reserves both ScreenCaptureKit preparation boundaries`() {
        #expect(
            PeekabooBridgeServer.defaultScreenCaptureKitOwnershipPreparationTimeoutSeconds >=
                ScreenCaptureKitOwnerLease.defaultProcessCapabilityPreparationTimeoutSeconds + 1
        )
        #expect(
            DaemonLaunchPolicy.defaultLaunchTimeoutSeconds >=
                PeekabooBridgeServer.defaultScreenCaptureKitOwnershipPreparationTimeoutSeconds + 1
        )
        #expect(DaemonLaunchPolicy.defaultLaunchTimeoutSeconds < 12)
    }

    /// Shell snippet that writes the child's PID via an atomic rename, so the PID file
    /// never exists in a created-but-not-yet-written state.
    private static func writePIDCommand(to pidURL: URL) -> String {
        "echo $$ > \(pidURL.path).tmp; mv \(pidURL.path).tmp \(pidURL.path)"
    }

    /// Polls until the PID file contains a parsable positive PID; returns nil on deadline.
    private static func waitForPID(at pidURL: URL, timeout: TimeInterval = 5) async throws -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: pidURL, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = pid_t(trimmed), pid > 0 {
                    return pid
                }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    @Test
    func `daemon executable resolution prefers the canonical bundle executable`() {
        let bundleExecutable = URL(fileURLWithPath: "/opt/peekaboo/bin/peekaboo")
        let resolved = DaemonLaunchPolicy.daemonExecutableURL(
            bundleExecutableURL: bundleExecutable,
            arguments: ["peekaboo"],
            environment: ["PATH": "/usr/bin"]
        )

        #expect(resolved == bundleExecutable.standardizedFileURL)
    }

    @Test
    func `daemon executable resolution searches PATH for a bare argv zero`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-daemon-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("peekaboo")
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        #expect(chmod(executable.path, S_IRUSR | S_IWUSR | S_IXUSR) == 0)

        let resolved = DaemonLaunchPolicy.daemonExecutableURL(
            bundleExecutableURL: nil,
            arguments: ["peekaboo"],
            environment: ["PATH": directory.path],
            currentDirectoryURL: FileManager.default.temporaryDirectory
        )

        #expect(resolved == executable.standardizedFileURL)
    }

    @Test
    func `daemon launch reports a process launch failure`() async {
        let executable = URL(fileURLWithPath: "/tmp/missing-peekaboo-\(UUID().uuidString)")

        do {
            _ = try await DaemonLaunchPolicy.launchDaemon(
                socketPath: "/tmp/peekaboo-daemon-missing-\(UUID().uuidString).sock",
                arguments: [],
                timeout: 0.2,
                executableURL: executable,
                logHandle: .nullDevice
            )
            Issue.record("Expected the daemon launch to fail")
        } catch let error as DaemonLaunchPolicy.DaemonLaunchError {
            guard case let .launchFailed(failedExecutable, _) = error else {
                Issue.record("Expected a launch failure, got \(error)")
                return
            }
            #expect(failedExecutable == executable)
            #expect(error.localizedDescription.contains(executable.path))
        } catch {
            Issue.record("Unexpected daemon launch error: \(error)")
        }
    }

    @Test
    func `daemon launch reports an early child exit`() async {
        let executable = URL(fileURLWithPath: "/usr/bin/false")

        do {
            _ = try await DaemonLaunchPolicy.launchDaemon(
                socketPath: "/tmp/peekaboo-daemon-exit-\(UUID().uuidString).sock",
                arguments: [],
                timeout: 1,
                executableURL: executable,
                logHandle: .nullDevice
            )
            Issue.record("Expected the daemon child to exit")
        } catch let error as DaemonLaunchPolicy.DaemonLaunchError {
            guard case let .exited(failedExecutable, status, logURL) = error else {
                Issue.record("Expected an early-exit failure, got \(error)")
                return
            }
            #expect(failedExecutable == executable)
            #expect(status != 0)
            #expect(error.localizedDescription.contains(logURL.path))
        } catch {
            Issue.record("Unexpected daemon launch error: \(error)")
        }
    }

    @Test
    func `daemon launch reports a readiness timeout`() async {
        let executable = URL(fileURLWithPath: "/bin/sleep")

        do {
            _ = try await DaemonLaunchPolicy.launchDaemon(
                socketPath: "/tmp/peekaboo-daemon-timeout-\(UUID().uuidString).sock",
                arguments: ["2"],
                timeout: 0.05,
                executableURL: executable,
                logHandle: .nullDevice
            )
            Issue.record("Expected daemon readiness to time out")
        } catch let error as DaemonLaunchPolicy.DaemonLaunchError {
            guard case let .timedOut(timeout, logURL) = error else {
                Issue.record("Expected a readiness timeout, got \(error)")
                return
            }
            #expect(timeout == 0.05)
            #expect(error.localizedDescription.contains(logURL.path))
        } catch {
            Issue.record("Unexpected daemon launch error: \(error)")
        }
    }

    @Test
    func `on demand daemon launch removes request scoped capture engine environment`() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-daemon-engine-env-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let command = "printf '%s' \"${PEEKABOO_CAPTURE_ENGINE-unset}\" > \(outputURL.path); exec /bin/sleep 30"
        let environment = DaemonLaunchPolicy.onDemandDaemonEnvironment([
            "PATH": "/usr/bin:/bin",
            "PEEKABOO_CAPTURE_ENGINE": "modern",
        ])

        do {
            _ = try await DaemonLaunchPolicy.launchDaemon(
                socketPath: "/tmp/peekaboo-daemon-engine-env-\(UUID().uuidString).sock",
                arguments: ["-c", command],
                timeout: 0.2,
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                logHandle: .nullDevice,
                environment: environment
            )
            Issue.record("Expected daemon readiness to time out")
        } catch let error as DaemonLaunchPolicy.DaemonLaunchError {
            guard case .timedOut = error else {
                Issue.record("Expected a readiness timeout, got \(error)")
                return
            }
        }

        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "unset")
    }

    @Test(.timeLimit(.minutes(1)))
    func `daemon timeout bounds termination for a TERM ignoring child`() async throws {
        let pidURL = URL(fileURLWithPath: "/tmp/peekaboo-daemon-term-\(UUID().uuidString).pid")
        var childPID: pid_t?
        defer {
            if let childPID, kill(childPID, 0) == 0 {
                kill(childPID, SIGKILL)
            }
            unlink(pidURL.path)
            unlink(pidURL.path + ".tmp")
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            _ = try await DaemonLaunchPolicy.launchDaemon(
                socketPath: "/tmp/peekaboo-daemon-term-\(UUID().uuidString).sock",
                arguments: ["-c", "trap '' TERM; \(Self.writePIDCommand(to: pidURL)); exec /bin/sleep 30"],
                // Give the child one scheduler slice to install its TERM trap and publish the PID.
                // A 50 ms readiness deadline can expire before a loaded hosted runner schedules it.
                timeout: 1,
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                logHandle: .nullDevice
            )
            Issue.record("Expected daemon readiness to time out")
        } catch let error as DaemonLaunchPolicy.DaemonLaunchError {
            guard case .timedOut = error else {
                Issue.record("Expected a readiness timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected daemon launch error: \(error)")
        }

        #expect(clock.now - startedAt < .seconds(4))
        childPID = try await Self.waitForPID(at: pidURL)
        let stoppedPID = try #require(childPID)
        #expect(kill(stoppedPID, 0) == -1)
        #expect(errno == ESRCH)
        childPID = nil
    }

    @Test
    func `canceling daemon launch terminates and reaps the child`() async throws {
        let pidURL = URL(fileURLWithPath: "/tmp/peekaboo-daemon-cancel-\(UUID().uuidString).pid")
        var childPID: pid_t?
        defer {
            if let childPID, kill(childPID, 0) == 0 {
                kill(childPID, SIGKILL)
            }
            unlink(pidURL.path)
            unlink(pidURL.path + ".tmp")
        }

        let launchTask = Task {
            try await DaemonLaunchPolicy.launchDaemon(
                socketPath: "/tmp/peekaboo-daemon-cancel-\(UUID().uuidString).sock",
                arguments: ["-c", "\(Self.writePIDCommand(to: pidURL)); exec /bin/sleep 30"],
                timeout: 10,
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                logHandle: .nullDevice
            )
        }
        guard let stoppedPID = try await Self.waitForPID(at: pidURL) else {
            launchTask.cancel()
            _ = await launchTask.result
            Issue.record("Daemon child did not write a parsable PID")
            return
        }
        childPID = stoppedPID
        launchTask.cancel()

        switch await launchTask.result {
        case .success:
            Issue.record("Expected daemon launch cancellation")
        case let .failure(error):
            #expect(error is CancellationError)
        }
        #expect(kill(stoppedPID, 0) == -1)
        #expect(errno == ESRCH)
        childPID = nil
    }
}
