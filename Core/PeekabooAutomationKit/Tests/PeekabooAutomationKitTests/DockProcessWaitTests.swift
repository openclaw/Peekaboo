import Darwin
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct DockProcessWaitTests {
    @Test
    func `normally exiting child returns its exit status`() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.05; exit 7"]

        try process.run()
        try DockService.waitForProcessExit(process, timeoutSeconds: 2)

        #expect(!process.isRunning)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 7)
    }

    @Test(arguments: [0.0, 0.1])
    func `timed out child is killed and reaped`(startupDelay: Double) throws {
        let process = Process()
        let readiness = Pipe()
        defer { try? readiness.fileHandleForReading.close() }
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep \(startupDelay); trap '' TERM; printf r; exec /bin/sleep 30"]
        process.standardOutput = readiness

        try process.run()
        let pid = process.processIdentifier
        defer {
            if process.isRunning {
                _ = kill(pid, SIGKILL)
                process.waitUntilExit()
            }
        }
        try readiness.fileHandleForWriting.close()

        // Process.run() does not guarantee that the child has installed its TERM handler.
        var descriptor = pollfd(fd: readiness.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        try #require(poll(&descriptor, 1, 10000) == 1)
        try #require(readiness.fileHandleForReading.read(upToCount: 1) == Data("r".utf8))
        let startedAt = Date()

        #expect(throws: PeekabooError.self) {
            try DockService.waitForProcessExit(process, timeoutSeconds: 0.05)
        }

        #expect(Date().timeIntervalSince(startedAt) < 2)
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)

        errno = 0
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}
