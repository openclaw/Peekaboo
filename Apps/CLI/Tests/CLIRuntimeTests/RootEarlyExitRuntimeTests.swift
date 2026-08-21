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
        #expect(self.helpEntryCount("- --bridge-socket <path>", in: result.standardOutput) == 1)
    }

    @Test
    func `leaf and nested help do not duplicate runtime flags`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let cases = [
            (["click", "--help"], "peekaboo click"),
            (["app", "list", "--help"], "peekaboo app list"),
            (["bridge", "receipt", "validate", "--help"], "peekaboo bridge receipt validate"),
        ]
        for (arguments, usage) in cases {
            let result = try await TestChildProcess.runPeekaboo(arguments, isolateFromRemoteHosts: false)

            #expect(result.status == .exited(0))
            #expect(result.standardError.isEmpty)
            #expect(result.standardOutput.contains("Usage\n  \(usage)"))
            #expect(!result.standardOutput.contains("Global Runtime Flags"))
            #expect(self.helpEntryCount("--bridge-socket <bridge-socket>", in: result.standardOutput) == 1)
            #expect(self.helpEntryCount("--input-strategy <input-strategy>", in: result.standardOutput) == 1)
            #expect(self.helpEntryCount("--no-remote", in: result.standardOutput) == 1)
            #expect(self.helpEntryCount("--json, -j", in: result.standardOutput) == 1)
            #expect(self.helpEntryCount("-v, --verbose", in: result.standardOutput) == 1)
        }
    }

    @Test
    func `default-subcommand parent help surfaces accepted leaf flags once`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let cases: [([String], [String])] = [
            (["agent", "--help"], ["--model <model>", "--allow-foreground", "--dry-run"]),
            (["permissions", "--help"], ["--all-sources"]),
            (["tools", "--help"], ["--no-sort"]),
        ]
        for (arguments, leafFlags) in cases {
            let result = try await TestChildProcess.runPeekaboo(arguments, isolateFromRemoteHosts: false)

            #expect(result.status == .exited(0))
            #expect(result.standardError.isEmpty)
            #expect(!result.standardOutput.contains("Global Runtime Flags"))
            for flag in leafFlags {
                #expect(self.helpEntryCount(flag, in: result.standardOutput) == 1)
            }
            #expect(self.helpEntryCount("--bridge-socket <bridge-socket>", in: result.standardOutput) == 1)
            #expect(self.helpEntryCount("--no-remote", in: result.standardOutput) == 1)
        }
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
        ["--junk", "app", "--help"],
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
        let expectedPath = if arguments.contains("click") {
            "click"
        } else if arguments.contains("list") {
            "app list"
        } else {
            "app"
        }
        #expect(result.standardOutput.contains("Usage\n  peekaboo \(expectedPath)"))
        #expect(!result.standardOutput.contains("Core Commands"))
    }

    @Test(arguments: [
        ["--log-level", "--help"],
        ["--logLevel", "--help"],
        ["--bridge-socket", "--help"],
        ["--bridgeSocket", "--help"],
        ["--input-strategy", "--help"],
        ["--inputStrategy", "--help"],
    ])
    func `missing runtime option value does not become root help`(arguments: [String]) async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let result = try await TestChildProcess.runPeekaboo(arguments, isolateFromRemoteHosts: false)

        #expect(result.status == .exited(1))
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.contains("Runtime flags must follow the leaf command"))
    }

    @Test(arguments: ["--log-level=--help", "--logLevel=--help"])
    func `attached help token remains a runtime option value`(argument: String) async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let result = try await TestChildProcess.runPeekaboo([argument], isolateFromRemoteHosts: false)

        #expect(result.status == .exited(1))
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.contains("Unknown command '\(argument)'"))
    }

    @Test(arguments: ["--json", "-j", "--json-output", "--jsonOutput"])
    func `JSON flags after double dash stay ordinary child arguments`(jsonFlag: String) async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let result = try await TestChildProcess.runPeekaboo(
            ["--junk", "--", jsonFlag],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(1))
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.contains("Error: Unknown command '--junk'"))
        #expect(!result.standardError.contains("\"success\""))
    }

    private func helpEntryCount(_ option: String, in help: String) -> Int {
        help.split(separator: "\n").count { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix(option)
        }
    }
}
