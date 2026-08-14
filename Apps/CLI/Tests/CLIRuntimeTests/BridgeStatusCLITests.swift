import Foundation
import Subprocess
import Testing

struct BridgeStatusCLITests {
    @Test(arguments: ["click", "move"])
    func `malformed coordinates fail before explicit Bridge resolution`(command: String) async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-missing-bridge-\(UUID().uuidString).sock").path
        var arguments = [command, "--at", "not-a-coordinate"]
        if command == "move" {
            arguments.append("--foreground")
        }
        arguments += ["--bridge-socket", socketPath, "--json"]

        let result = try await TestChildProcess.runPeekaboo(
            arguments,
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(1))
        #expect(result.standardError.isEmpty)

        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        let outcome = try #require(json["outcome"] as? [String: Any])
        #expect(json["success"] as? Bool == false)
        #expect(json["effect"] as? String == "refused")
        #expect(error["code"] as? String == "VALIDATION_ERROR")
        #expect(error["message"] as? String == "Invalid coordinates format. Use: x,y")
        #expect(error["mutation_dispatched"] as? Bool == false)
        #expect(error["retry_safe"] as? Bool == true)
        #expect(outcome["dispatch_state"] as? String == "none")
        #expect(outcome["state"] as? String == "refused")
        #expect(!result.standardOutput.contains("BRIDGE_UNAVAILABLE"))
        #expect(!result.standardOutput.contains(socketPath))
        #expect(!result.standardOutput.contains("Runtime host:"))
    }

    @Test
    func `explicit missing Bridge socket fails without local fallback`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-missing-bridge-\(UUID().uuidString).sock").path
        let result = try await TestChildProcess.runPeekaboo(
            [
                "bridge", "status",
                "--bridge-socket", socketPath,
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
        #expect(json["data"] is NSNull)
        #expect(error["code"] as? String == "BRIDGE_UNAVAILABLE")
        #expect((error["message"] as? String)?.contains(socketPath) == true)
        #expect((error["hint"] as? String)?.contains("--no-remote") == true)
        #expect(!result.standardOutput.contains(#""source" : "local""#))
    }

    @Test
    func `explicit missing Bridge socket blocks runtime command local fallback`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-missing-bridge-\(UUID().uuidString).sock").path
        let result = try await TestChildProcess.runPeekaboo(
            [
                "app", "list",
                "--bridge-socket", socketPath,
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
        #expect(json["data"] is NSNull)
        #expect(error["code"] as? String == "BRIDGE_UNAVAILABLE")
        #expect((error["message"] as? String)?.contains(socketPath) == true)
        #expect(!result.standardOutput.contains(#""apps""#))
    }

    @Test
    func `no remote explicitly permits local execution alongside a socket override`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-missing-bridge-\(UUID().uuidString).sock").path
        let result = try await TestChildProcess.runPeekaboo(
            [
                "screen", "list",
                "--bridge-socket", socketPath,
                "--no-remote",
                "--json",
            ],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(0))
        #expect(result.standardError.isEmpty)

        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let data = try #require(json["data"] as? [String: Any])
        #expect(json["success"] as? Bool == true)
        #expect(data["screens"] is [[String: Any]])
        #expect(!result.standardOutput.contains("BRIDGE_UNAVAILABLE"))
    }

    @Test
    func `human explicit missing Bridge socket reports the endpoint on stderr`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-missing-bridge-\(UUID().uuidString).sock").path
        let result = try await TestChildProcess.runPeekaboo(
            [
                "bridge", "status",
                "--bridge-socket", socketPath,
            ],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(1))
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.contains(socketPath))
        #expect(result.standardError.contains("--no-remote"))
        #expect(!result.standardError.contains("Selected: local"))
    }
}
