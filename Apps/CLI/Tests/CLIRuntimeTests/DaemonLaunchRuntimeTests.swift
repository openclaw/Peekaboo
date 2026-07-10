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
    @Test(.timeLimit(.minutes(1)))
    func `bare argv zero reaches the production daemon launch path`() async throws {
        let identifier = String(UUID().uuidString.prefix(8)).lowercased()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-daemon-\(identifier)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("work", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let socketPath = "/tmp/pb-\(identifier).sock"
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
            try? FileManager.default.removeItem(at: root)
        }

        let result = try await TestChildProcess.runPeekaboo(
            [
                "daemon", "start",
                "--bridge-socket", socketPath,
                "--wait-seconds", "0",
            ],
            environment: [
                "PATH": "/usr/bin:/bin",
                "PEEKABOO_CONFIG_DIR": configDirectory.path,
                "PEEKABOO_CONFIG_DISABLE_MIGRATION": "1",
            ],
            executablePathOverride: "peekaboo",
            workingDirectory: workingDirectory,
            timeout: .seconds(10)
        )

        #expect(result.status == .exited(1), Comment(rawValue: result.standardError))
        let reachedChild = result.standardError.contains("did not become ready within 0s")
            || result.standardError.contains("exited before becoming ready")
        #expect(reachedChild, Comment(rawValue: result.standardError))
        #expect(!result.standardError.contains("Could not launch the Peekaboo daemon"))
        #expect(!result.standardError.contains(
            workingDirectory.appendingPathComponent("peekaboo").path
        ))
    }
}
