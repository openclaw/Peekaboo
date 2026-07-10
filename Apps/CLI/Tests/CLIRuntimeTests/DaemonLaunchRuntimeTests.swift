import Darwin
import Foundation
import Subprocess
import Testing

/// These tests spawn the real peekaboo binary and its daemon. CI runners
/// cannot host the daemon (the child times out and is SIGKILLed after
/// minutes), so they run only alongside the automation suites.
private enum DaemonRuntimeTestEnvironment {
    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PEEKABOO_INCLUDE_AUTOMATION_TESTS"]?.lowercased() == "true"
    }
}

@Suite(.serialized, .enabled(if: DaemonRuntimeTestEnvironment.isEnabled))
struct DaemonLaunchRuntimeTests {
    @Test
    func `bare argv zero starts and stops the production daemon from an empty directory`() async throws {
        let identifier = String(UUID().uuidString.prefix(8)).lowercased()
        let root = URL(fileURLWithPath: "/tmp/pb-daemon-\(identifier)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("work", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let socketPath = "/tmp/pb-\(identifier).sock"
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        #expect(chmod(root.path, S_IRWXU) == 0)

        var daemonPID: pid_t?
        defer {
            if let daemonPID, kill(daemonPID, 0) == 0 {
                kill(daemonPID, SIGKILL)
            }
            unlink(socketPath)
            unlink("\(socketPath).lock")
            try? FileManager.default.removeItem(at: root)
        }

        let environment = [
            "PEEKABOO_CONFIG_DIR": configDirectory.path,
            "PEEKABOO_CONFIG_DISABLE_MIGRATION": "1",
            "PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS": "1",
        ]
        do {
            let start = try await TestChildProcess.runPeekaboo(
                [
                    "daemon", "start",
                    "--bridge-socket", socketPath,
                    "--wait-seconds", "5",
                ],
                environment: environment,
                executablePathOverride: "peekaboo",
                workingDirectory: workingDirectory
            )
            #expect(start.status == .exited(0), Comment(rawValue: start.standardError))
            let parsedStartPID = Self.daemonPID(in: start.standardOutput)
            daemonPID = parsedStartPID
            let startPID = try #require(parsedStartPID)
            #expect(kill(startPID, 0) == 0)

            let status = try await TestChildProcess.runPeekaboo(
                ["daemon", "status", "--bridge-socket", socketPath],
                environment: environment,
                workingDirectory: workingDirectory
            )
            #expect(status.status == .exited(0), Comment(rawValue: status.standardError))
            #expect(status.standardOutput.contains("Mode: manual"))
            let observedPID = try #require(Self.daemonPID(in: status.standardOutput))
            #expect(observedPID == startPID)

            #expect(FileManager.default.fileExists(atPath: configDirectory
                    .appendingPathComponent("daemon.log").path))

            let stop = try await TestChildProcess.runPeekaboo(
                Self.stopArguments(socketPath: socketPath),
                environment: environment,
                workingDirectory: workingDirectory
            )
            #expect(stop.status == .exited(0), Comment(rawValue: stop.standardError))

            let exitDeadline = Date().addingTimeInterval(2)
            while let daemonPID, kill(daemonPID, 0) == 0, Date() < exitDeadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let processIsGone = kill(startPID, 0) == -1 && errno == ESRCH
            #expect(processIsGone)
            #expect(!FileManager.default.fileExists(atPath: socketPath))
            if processIsGone {
                daemonPID = nil
            }
        } catch {
            _ = try? await TestChildProcess.runPeekaboo(
                Self.stopArguments(socketPath: socketPath),
                environment: environment,
                workingDirectory: workingDirectory
            )
            if let daemonPID, kill(daemonPID, 0) == 0 {
                kill(daemonPID, SIGKILL)
            }
            daemonPID = nil
            throw error
        }
    }

    private static func daemonPID(in output: String) -> pid_t? {
        output.split(separator: "\n")
            .first { $0.hasPrefix("PID: ") }
            .flatMap { pid_t($0.dropFirst("PID: ".count)) }
    }

    private static func stopArguments(socketPath: String) -> [String] {
        [
            "daemon", "stop",
            "--bridge-socket", socketPath,
            "--wait-seconds", "5",
        ]
    }
}
