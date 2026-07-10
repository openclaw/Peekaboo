import Darwin
import Foundation
import Testing
@testable import PeekabooCLI

struct DaemonLaunchPolicyTests {
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

    @Test(.timeLimit(.minutes(1)))
    func `daemon timeout bounds termination for a TERM ignoring child`() async throws {
        let pidURL = URL(fileURLWithPath: "/tmp/peekaboo-daemon-term-\(UUID().uuidString).pid")
        var childPID: pid_t?
        defer {
            if let childPID, kill(childPID, 0) == 0 {
                kill(childPID, SIGKILL)
            }
            unlink(pidURL.path)
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            _ = try await DaemonLaunchPolicy.launchDaemon(
                socketPath: "/tmp/peekaboo-daemon-term-\(UUID().uuidString).sock",
                arguments: ["-c", "trap '' TERM; echo $$ > \(pidURL.path); exec /bin/sleep 30"],
                timeout: 0.05,
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

        #expect(clock.now - startedAt < .seconds(3))
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        childPID = pid_t(pidText)
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
        }

        let launchTask = Task {
            try await DaemonLaunchPolicy.launchDaemon(
                socketPath: "/tmp/peekaboo-daemon-cancel-\(UUID().uuidString).sock",
                arguments: ["-c", "echo $$ > \(pidURL.path); exec /bin/sleep 30"],
                timeout: 10,
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                logHandle: .nullDevice
            )
        }
        let pidDeadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: pidURL.path), Date() < pidDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard FileManager.default.fileExists(atPath: pidURL.path) else {
            launchTask.cancel()
            _ = await launchTask.result
            Issue.record("Daemon child did not write its PID")
            return
        }

        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPID = pid_t(pidText)
        childPID = parsedPID
        let stoppedPID = try #require(parsedPID)
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
