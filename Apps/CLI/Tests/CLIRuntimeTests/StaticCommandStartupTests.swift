import Foundation
import Subprocess
import Testing

struct StaticCommandStartupTests {
    @Test(arguments: [
        [],
        ["--help"],
        ["help", "app", "list"],
        ["bridge", "receipt", "validate", "--help"],
        ["--version"],
        ["--version", "--json"],
        ["completions", "bash"],
        ["completions", "zsh"],
        ["completions", "fish"],
        ["agent", "Inspect nothing", "--dry-run", "--simple"],
        ["agent", "run", "Inspect nothing", "--dry-run", "--simple"],
        ["agent", "Inspect nothing", "--dry-run", "--json"],
        ["agent", "run", "Inspect nothing", "--dry-run", "--json"],
    ])
    func `static commands do not load malformed configuration`(arguments: [String]) async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-static-startup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        let malformed = Data("{\"static-startup-sentinel\":".utf8)
        try malformed.write(to: config)

        let isPreview = arguments.first == "agent"
        let invocation = arguments + (isPreview ? [
            "--no-desktop-context", "--bridge-socket", directory.appendingPathComponent("missing.sock").path,
        ] : [])
        let result = try await TestChildProcess.runPeekaboo(
            invocation,
            environment: [
                "PEEKABOO_CONFIG_DIR": directory.path,
                "PEEKABOO_CONFIG_DISABLE_MIGRATION": "1",
                "PEEKABOO_CHECK_BUILD_STALENESS": "0",
                "PEEKABOO_DISABLE_AGENT": "0",
            ],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(0))
        #expect(result.standardError.isEmpty)
        #expect(!result.standardOutput.isEmpty)
        #expect(!result.standardOutput.contains("Warning:"))
        #expect(!result.standardOutput.contains("static-startup-sentinel"))
        #expect(try Data(contentsOf: config) == malformed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["config.json"])

        if arguments.contains("--json") {
            let response = try #require(
                JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any]
            )
            #expect(response["success"] as? Bool == true)
            if isPreview {
                let payload = try #require(response["result"] as? [String: Any])
                #expect(payload["dryRun"] as? Bool == true)
                #expect(payload["instruction"] as? String == "Inspect nothing")
                #expect(payload["automaticDesktopContext"] as? Bool == false)
                #expect(payload["modelExecution"] as? String == "skipped")
                #expect((payload["toolCalls"] as? [Any])?.isEmpty == true)
                #expect(payload["sessionId"] is NSNull)
            }
        } else if isPreview {
            #expect(result.standardOutput.contains("Tool calls: 0\nSession saved: no"))
        }
    }
}
