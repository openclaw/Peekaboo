import Foundation
import Subprocess
import Testing

struct RootEarlyExitRuntimeTests {
    @Test
    func `root version after JSON flag emits the version envelope`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let result = try await TestChildProcess.runPeekaboo(
            ["--json", "--version"],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(0))
        #expect(result.standardError.isEmpty)
        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let data = try #require(json["data"] as? [String: Any])
        #expect(json["success"] as? Bool == true)
        #expect((data["current"] as? String)?.hasPrefix("Peekaboo ") == true)
    }

    @Test(arguments: ["--help", "-h"])
    func `root help ignores an earlier unknown root option`(helpFlag: String) async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let result = try await TestChildProcess.runPeekaboo(
            ["--junk", helpFlag],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(0))
        #expect(result.standardError.isEmpty)
        #expect(result.standardOutput.contains("Usage"))
        #expect(result.standardOutput.contains("Global Runtime Flags"))
    }

    @Test(arguments: [
        ["--log-level", "debug", "--version"],
        ["--logLevel=debug", "-V"],
        ["--bridge-socket", "/tmp/peekaboo-root-help-missing.sock", "--version"],
        ["--input-strategy", "actionOnly", "--version"],
    ])
    func `root version consumes documented runtime option values`(arguments: [String]) async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let result = try await TestChildProcess.runPeekaboo(arguments, isolateFromRemoteHosts: false)

        #expect(result.status == .exited(0))
        #expect(result.standardError.isEmpty)
        #expect(result.standardOutput.hasPrefix("Peekaboo "))
        #expect(!result.standardOutput.contains("Bridge"))
    }

    @Test(arguments: [
        ["--junk", "click", "--help"],
        ["--unknown=1", "app", "list", "--help"],
    ])
    func `option-leading command help stays command scoped`(arguments: [String]) async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let result = try await TestChildProcess.runPeekaboo(arguments, isolateFromRemoteHosts: false)

        #expect(result.status == .exited(0))
        #expect(result.standardError.isEmpty)
        #expect(result.standardOutput
            .contains("Usage\n  peekaboo \(arguments.contains("click") ? "click" : "app list")"))
        #expect(!result.standardOutput.contains("Core Commands"))
    }
}
