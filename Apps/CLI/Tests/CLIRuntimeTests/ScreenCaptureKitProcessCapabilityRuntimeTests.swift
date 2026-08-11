import Darwin
import Foundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct ScreenCaptureKitProcessCapabilityRuntimeTests {
    @Test
    func `live current CLI subprocess publishes a valid held capability marker`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-process-capability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let process = Process()
        process.executableURL = try TestChildProcess.peekabooBinaryURL()
        process.arguments = [
            "daemon", "run",
            "--mode", "manual",
            "--bridge-socket", directory.appendingPathComponent("bridge.sock").path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { Self.stop(process) }

        let processStartIdentity = try await self.waitForProcessCapability(process)
        let conflicts = try ScreenCaptureKitOwnerLease.liveUncoordinatedProcesses(
            excluding: .current()
        )

        #expect(!conflicts.contains(where: {
            $0.processIdentifier == process.processIdentifier &&
                $0.processStartIdentity == processStartIdentity
        }))

        Self.stop(process)
        try ScreenCaptureKitOwnerLease.removeStaleProcessCapabilityMarkers()
    }

    private func waitForProcessCapability(_ process: Process) async throws -> UInt64 {
        for _ in 0..<100 {
            guard process.isRunning else {
                throw RuntimeError("Peekaboo marker fixture exited before registration")
            }
            if let identity = SystemIdentityResolver.processStartIdentity(process.processIdentifier) {
                let marker = ScreenCaptureKitOwnerLease.processCapabilityMarkerURL(
                    processIdentifier: process.processIdentifier,
                    processStartIdentity: identity
                )
                if FileManager.default.fileExists(atPath: marker.path) {
                    return identity
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RuntimeError("Peekaboo marker fixture did not publish its process capability")
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<100 where process.isRunning {
            usleep(10000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}
