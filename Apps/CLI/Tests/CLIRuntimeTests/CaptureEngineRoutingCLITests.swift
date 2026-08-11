import Foundation
import Testing

struct CaptureEngineRoutingCLITests {
    @Test
    func `Unknown capture engine is structured and never dispatches`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-invalid-engine-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try await TestChildProcess.runPeekaboo([
            "see",
            "--mode", "screen",
            "--no-elements",
            "--path", output.path,
            "--capture-engine", "warp-drive",
            "--json",
        ])

        #expect(result.status == .exited(1))
        #expect(result.standardError.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.path))

        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(json["success"] as? Bool == false)
        #expect(error["code"] as? String == "INVALID_ARGUMENT")
        #expect((error["message"] as? String)?.contains("capture-engine") == true)
        #expect((error["message"] as? String)?.contains("warp-drive") == true)
    }

    @Test
    func `Unknown ambient capture engine is structured and never dispatches`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-invalid-ambient-engine-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try await TestChildProcess.runPeekaboo(
            [
                "see",
                "--mode", "screen",
                "--no-elements",
                "--path", output.path,
                "--json",
            ],
            environment: ["PEEKABOO_CAPTURE_ENGINE": "warp-drive"]
        )

        #expect(result.status == .exited(1))
        #expect(result.standardError.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.path))

        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(json["success"] as? Bool == false)
        #expect(error["code"] as? String == "VALIDATION_ERROR")
        #expect((error["message"] as? String)?.contains("warp-drive") == true)
    }

    @Test
    func `Explicit capture engine refuses missing Bridge without local dispatch`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-engine-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent("must-not-exist.png")
        let missingSocket = directory.appendingPathComponent("missing.sock")
        let result = try await TestChildProcess.runPeekaboo(
            [
                "see",
                "--mode", "screen",
                "--no-elements",
                "--path", output.path,
                "--capture-engine", "cg",
                "--bridge-socket", missingSocket.path,
                "--json",
            ],
            isolateFromRemoteHosts: false
        )
        #expect(result.status == .exited(1))
        #expect(result.standardError.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.path))

        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(json["success"] as? Bool == false)
        #expect(error["code"] as? String == "VALIDATION_ERROR")
        #expect((error["message"] as? String)?.contains("could not be delivered") == true)
        #expect((error["message"] as? String)?.contains("--no-remote") == true)
    }
}
