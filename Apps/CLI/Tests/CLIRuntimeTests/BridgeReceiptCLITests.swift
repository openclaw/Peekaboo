import Foundation
import Subprocess
import Testing

struct BridgeReceiptCLITests {
    @Test
    func `incomplete private bundle reports schema failure before socket access`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-receipt-runtime-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("bundle.json")
        try Data(#"{"operationAttestation":{}}"#.utf8).write(to: bundle)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.path)
        let missingSocket = directory.appendingPathComponent("missing.sock").path

        let result = try await TestChildProcess.runPeekaboo(
            [
                "bridge", "receipt", "validate",
                "--bundle", bundle.path,
                "--bridge-socket", missingSocket,
                "--trusted-host-team-id", "TEAMID",
                "--json",
            ],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(1))
        #expect(result.standardError.isEmpty)
        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "VALIDATION_ERROR")
        #expect((error["message"] as? String)?.contains("invalid protocol 1.29 schema") == true)
        #expect((error["hint"] as? String)?.contains("original owner-private bundle") == true)
        #expect(!result.standardOutput.contains(missingSocket))
    }

    @Test
    func `custom socket trust omission reports exact remedy before bundle or socket access`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }
        let missingBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-receipt-\(UUID().uuidString).json").path
        let missingSocket = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-bridge-\(UUID().uuidString).sock").path

        let result = try await TestChildProcess.runPeekaboo(
            [
                "bridge", "receipt", "validate",
                "--bundle", missingBundle,
                "--bridge-socket", missingSocket,
                "--json",
            ],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(1))
        #expect(result.standardError.isEmpty)
        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "INVALID_ARGUMENT")
        #expect((error["message"] as? String)?.contains("Custom Bridge sockets require") == true)
        #expect((error["hint"] as? String)?.contains("--trusted-host-team-id TEAMID") == true)
        #expect(!result.standardOutput.contains(missingBundle))
        #expect(!result.standardOutput.contains(missingSocket))
    }

    @Test
    func `receipt validation reports bundle file errors before contacting the exact socket`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }
        let missingBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-receipt-\(UUID().uuidString).json").path
        let missingSocket = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-bridge-\(UUID().uuidString).sock").path

        let result = try await TestChildProcess.runPeekaboo(
            [
                "bridge", "receipt", "validate",
                "--bundle", missingBundle,
                "--bridge-socket", missingSocket,
                "--trusted-host-team-id", "TEAMID",
                "--json",
            ],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(1))
        #expect(result.standardError.isEmpty)
        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(json["success"] as? Bool == false)
        #expect(error["code"] as? String == "FILE_IO_ERROR")
        #expect((error["message"] as? String)?.contains("file does not exist") == true)
        #expect(!result.standardOutput.contains(missingSocket))
    }
}
