import Darwin
import Foundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized)
struct TerminalTitleProcessTests {
    @Test
    func `normally exiting child returns its exit status`() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.05; exit 7"]

        try process.run()
        try waitForTerminalTitleProcessExit(process, timeoutSeconds: 2)

        #expect(!process.isRunning)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 7)
    }

    @Test
    func `already exited child is not terminated again`() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]

        try process.run()
        process.waitUntilExit()
        #expect(!process.isRunning)

        try waitForTerminalTitleProcessExit(process, timeoutSeconds: 0.05)
        #expect(!process.isRunning)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
    }

    @Test
    func `timed out child is killed and reaped`() throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("peekaboo-terminal-title-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: false)
        let readyFile = scratch.appendingPathComponent("ready")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "trap '' TERM && : > \"$1\" && exec /bin/sleep 30",
            "terminal-title-fixture", readyFile.path,
        ]

        try process.run()
        let pid = process.processIdentifier
        defer {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
            process.waitUntilExit()
        }

        // The timeout must start after the child ignores TERM, even when shell startup is slow.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !fileManager.fileExists(atPath: readyFile.path), process.isRunning, clock.now < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        try #require(fileManager.fileExists(atPath: readyFile.path), "Child did not become ready to ignore TERM")

        #expect(throws: TerminalTitleProcessWaitError.self) {
            try waitForTerminalTitleProcessExit(process, timeoutSeconds: 0.05)
        }

        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)

        errno = 0
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    func `updateTerminalTitle reaps a wedged vt on PATH`() throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("peekaboo-vt-title-\(UUID().uuidString)", isDirectory: true)
        let bin = scratch.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let pidFile = scratch.appendingPathComponent("vt.pid")
        let vt = bin.appendingPathComponent("vt")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$$" > "$PEEKABOO_VT_PID_FILE"
        trap '' TERM
        exec /bin/sleep 30
        """
        try script.write(to: vt, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vt.path)

        let previousPath = getenv("PATH").map { String(cString: $0) }
        let previousPidFile = getenv("PEEKABOO_VT_PID_FILE").map { String(cString: $0) }
        setenv("PATH", "\(bin.path):\(previousPath ?? "/usr/bin:/bin")", 1)
        setenv("PEEKABOO_VT_PID_FILE", pidFile.path, 1)
        defer {
            if let previousPath {
                setenv("PATH", previousPath, 1)
            } else {
                unsetenv("PATH")
            }
            if let previousPidFile {
                setenv("PEEKABOO_VT_PID_FILE", previousPidFile, 1)
            } else {
                unsetenv("PEEKABOO_VT_PID_FILE")
            }
        }

        updateTerminalTitle("peekaboo-vt-title-timeout")

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))
        errno = 0
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}
