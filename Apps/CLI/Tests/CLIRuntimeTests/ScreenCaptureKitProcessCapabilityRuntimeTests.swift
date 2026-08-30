import Darwin
import Foundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct ScreenCaptureKitProcessCapabilityRuntimeTests {
    @Test
    func `live current CLI subprocess publishes a valid held capability marker`() async throws {
        let identifier = String(UUID().uuidString.prefix(8)).lowercased()
        let directory = URL(fileURLWithPath: "/tmp/pb-cap-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("bridge.sock").path

        let process = Process()
        process.executableURL = try TestChildProcess.peekabooBinaryURL()
        process.arguments = [
            "daemon", "run",
            "--mode", "manual",
            "--bridge-socket", socketPath,
        ]
        process.standardOutput = FileHandle.nullDevice
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        defer { Self.stop(process) }

        let processStartIdentity = try await self.waitForProcessCapability(
            process,
            socketPath: socketPath,
            standardError: standardError
        )
        let conflicts = try ScreenCaptureKitOwnerLease.liveUncoordinatedProcesses(
            excluding: .current()
        )

        #expect(!conflicts.contains(where: {
            $0.processIdentifier == process.processIdentifier &&
                $0.processStartIdentity == processStartIdentity
        }))

        let exitedAfterSIGTERM = Self.stop(process)
        #expect(exitedAfterSIGTERM)
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: "\(socketPath).lock")).isEmpty)
        try ScreenCaptureKitOwnerLease.removeStaleProcessCapabilityMarkers()
    }

    private func waitForProcessCapability(
        _ process: Process,
        socketPath: String,
        standardError: Pipe
    ) async throws -> UInt64 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            guard process.isRunning else {
                let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
                let details = (String(bytes: errorData, encoding: .utf8) ??
                    "Invalid UTF-8 stderr (base64): \(errorData.base64EncodedString())")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = details.isEmpty ? "" : ": \(details)"
                throw RuntimeError("Peekaboo marker fixture exited before registration\(suffix)")
            }
            if let identity = SystemIdentityResolver.processStartIdentity(process.processIdentifier) {
                let marker = ScreenCaptureKitOwnerLease.processCapabilityMarkerURL(
                    processIdentifier: process.processIdentifier,
                    processStartIdentity: identity
                )
                if FileManager.default.fileExists(atPath: marker.path),
                   FileManager.default.fileExists(atPath: socketPath),
                   FileManager.default.fileExists(atPath: "\(socketPath).lock") {
                    return identity
                }
            }
            try await clock.sleep(for: .milliseconds(10))
        }
        throw RuntimeError("Peekaboo marker fixture did not publish its process capability and Bridge readiness")
    }

    @discardableResult
    private static func stop(_ process: Process) -> Bool {
        guard process.isRunning else { return true }
        process.terminate()
        let gracefulDeadline = DispatchTime.now() + .seconds(5)
        while process.isRunning, DispatchTime.now() < gracefulDeadline {
            usleep(10000)
        }
        let exitedAfterSIGTERM = !process.isRunning
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return exitedAfterSIGTERM
    }
}
