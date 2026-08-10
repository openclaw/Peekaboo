import Foundation
import Testing
@testable import PeekabooCLI

#if !PEEKABOO_SKIP_AUTOMATION
private enum SeeCommandPlaygroundTestConfig {
    @preconcurrency
    nonisolated static func enabled() -> Bool {
        ProcessInfo.processInfo.environment["RUN_LOCAL_TESTS"]?.lowercased() == "true"
    }

    @preconcurrency
    nonisolated static func playgroundIdentifier() -> String {
        ProcessInfo.processInfo.environment["PEEKABOO_PLAYGROUND_APP"] ?? "Playground"
    }
}

private enum SeeCommandPlaygroundHarness {
    static func launchArguments(playgroundIdentifier: String) -> [String] {
        [
            "app", "launch", playgroundIdentifier,
            "--new-instance", "--wait-for-window", "--no-remote", "--json",
        ]
    }

    static func run(
        _ arguments: [String],
        allowedExitStatuses: Set<Int32> = [0],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let result = try ExternalCommandRunner.runPeekabooCLI(
            arguments,
            allowedExitCodes: allowedExitStatuses,
            environment: environment
        )
        return result.combinedOutput
    }
}

struct SeeCommandPlaygroundHarnessContractTests {
    @Test
    func `Playground launch uses current v4 syntax`() {
        let arguments = SeeCommandPlaygroundHarness.launchArguments(playgroundIdentifier: "Playground")
        #expect(arguments == [
            "app", "launch", "Playground",
            "--new-instance", "--wait-for-window", "--no-remote", "--json",
        ])
        #expect(!arguments.contains("--name"))
    }

    @Test
    func `Harness command failures throw instead of being swallowed`() {
        #expect(throws: CommandExecutionError.self) {
            _ = try SeeCommandPlaygroundHarness.run(
                ["app", "launch", "Playground"],
                environment: ["PEEKABOO_CLI_PATH": "/usr/bin/false"]
            )
        }
    }
}

@Suite(
    .serialized,
    .tags(.automation),
    .enabled(if: SeeCommandPlaygroundTestConfig.enabled())
)
struct SeeCommandPlaygroundTests {
    @Test
    func `Hidden web-style fields are detected in Playground`() throws {
        struct LaunchData: Codable {
            let pid: Int32
            let process_start_identity: UInt64
        }

        let launchOutput = try SeeCommandPlaygroundHarness.run(
            SeeCommandPlaygroundHarness.launchArguments(
                playgroundIdentifier: SeeCommandPlaygroundTestConfig.playgroundIdentifier()
            )
        )
        let launchData = try #require(launchOutput.data(using: .utf8))
        let launch = try JSONDecoder().decode(CodableJSONResponse<LaunchData>.self, from: launchData)
        let cleanupArguments = [
            "app", "quit", "--pid", String(launch.data.pid),
            "--expected-process-start-identity", String(launch.data.process_start_identity),
            "--force", "--no-remote", "--json",
        ]

        do {
            let output = try SeeCommandPlaygroundHarness.run([
                "see", "--pid", String(launch.data.pid), "--no-remote", "--json",
            ])
            let data = try #require(output.data(using: .utf8))
            let envelope = try JSONDecoder().decode(CodableJSONResponse<SeeResult>.self, from: data)
            let result = envelope.data

            let identifiers = Set(result.ui_elements.compactMap(\.identifier))
            #expect(identifiers.contains("hidden-email-field"))
            #expect(identifiers.contains("hidden-password-field"))

            let roles = Dictionary(grouping: result.ui_elements, by: { $0.identifier ?? "" })
            #expect(roles["hidden-email-field"]?.first?.role == "textField")
            #expect(roles["hidden-password-field"]?.first?.role == "textField")

            #expect(identifiers.contains("permission-allow-button"))
            #expect(identifiers.contains("permission-deny-button"))
            #expect(roles["permission-allow-button"]?.first?.label == "Allow")
            #expect(roles["permission-deny-button"]?.first?.label == "Don't Allow")
        } catch {
            _ = try? SeeCommandPlaygroundHarness.run(cleanupArguments)
            throw error
        }

        _ = try SeeCommandPlaygroundHarness.run(cleanupArguments)
    }
}
#endif
