import Foundation
import Testing

struct CaptureEngineRoutingCLITests {
    @Test(arguments: ["live", "action"], ["cli-cli", "cli-env", "env-cli", "env-env"])
    func `Live capture engine refuses missing explicit host before setup`(
        command: String,
        sources: String
    ) async throws {
        try await self.assertRefusalBeforeSetup(command: command, sources: sources, inputPolicy: false)
    }

    @Test(arguments: ["live", "action"], ["cli-cli", "cli-env", "env-cli", "env-env"])
    func `Capture engine input policy conflict refuses before target output or child setup`(
        command: String,
        sources: String
    ) async throws {
        try await self.assertRefusalBeforeSetup(command: command, sources: sources, inputPolicy: true)
    }

    private func assertRefusalBeforeSetup(command: String, sources: String, inputPolicy: Bool) async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-engine-missing-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("must-not-create", isDirectory: true)
        let childMarker = root.appendingPathComponent("child-must-not-run")
        let socket = root.appendingPathComponent("missing.sock").path
        var environment = ["PEEKABOO_CAPTURE_ENGINE": "", "PEEKABOO_BRIDGE_SOCKET": ""]
        var arguments = [
            "capture", command, "--mode", "window", "--pid", "2147483647",
            "--capture-focus", "foreground", "--path", output.path, "--json",
        ]
        if sources.hasPrefix("cli-") {
            arguments += ["--capture-engine", "cg"]
        } else {
            environment["PEEKABOO_CAPTURE_ENGINE"] = "cg"
        }
        if sources.hasSuffix("-cli") {
            arguments += ["--bridge-socket", socket]
        } else {
            environment["PEEKABOO_BRIDGE_SOCKET"] = socket
        }
        if inputPolicy {
            arguments += ["--input-strategy", "synthOnly"]
        }
        if command == "action" {
            arguments += ["--", "/usr/bin/touch", childMarker.path]
        }

        let result = try await TestChildProcess.runPeekaboo(
            arguments,
            environment: environment,
            isolateFromRemoteHosts: false
        )
        #expect(result.status == .exited(1))
        #expect(result.standardError.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: childMarker.path))
        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(json["success"] as? Bool == false)
        #expect(error["code"] as? String == (inputPolicy ? "BRIDGE_UNAVAILABLE" : "VALIDATION_ERROR"))
        let expectedMessage = inputPolicy ? "input strategy policy" : "desktopObservationInlinePixels"
        #expect((error["message"] as? String)?.contains(expectedMessage) == true)
        if inputPolicy {
            #expect((error["hint"] as? String)?.contains("--no-remote") == true)
        } else {
            #expect((error["message"] as? String)?.contains("--no-remote") == true)
        }
        _ = try #require(json["debug_logs"] as? [String])
        if command == "action" {
            #expect(json["effect"] as? String == "refused")
            #expect(error["mutation_dispatched"] as? Bool == false)
            #expect(error["retry_safe"] as? Bool == true)
        }
    }

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
