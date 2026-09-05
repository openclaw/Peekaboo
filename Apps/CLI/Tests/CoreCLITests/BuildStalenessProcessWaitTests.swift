import Darwin
import Foundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized)
struct BuildStalenessProcessWaitTests {
    @Test
    func `normally exiting child keeps its exit status`() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.05; exit 7"]

        try process.run()
        try waitForProcessExit(process, timeoutSeconds: 2)
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

        try waitForProcessExit(process, timeoutSeconds: 0.05)
        #expect(!process.isRunning)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
    }

    @Test
    func `timed out child is killed and wait throws`() throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("peekaboo-build-staleness-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: false)
        let readyFile = scratch.appendingPathComponent("ready")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "trap '' TERM && : > \"$1\" && exec /bin/sleep 30",
            "build-staleness-fixture", readyFile.path,
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

        #expect(throws: ProcessWaitError.timedOut) {
            try waitForProcessExit(process, timeoutSeconds: 0.05)
        }
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)

        errno = 0
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}
