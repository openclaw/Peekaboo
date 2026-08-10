import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

#if !PEEKABOO_SKIP_AUTOMATION
@Suite(.tags(.automation), .enabled(if: CLITestEnvironment.runAutomationRead))
struct HelpCommandTests {
    @Test
    func `No arguments shows help`() async throws {
        let output = try await runPeekaboo([]).stdout

        // Verify help content is shown
        #expect(output.contains("Usage"))
        #expect(output.contains("peekaboo <command>"))
        #expect(output.contains("Core Commands"))
        #expect(output.contains("see"))
        #expect(output.contains("screen"))
        #expect(output.contains("press"))
        #expect(output.contains("action"))
        #expect(output.contains("agent"))
        #expect(output.contains("Global Runtime Flags"))
        #expect(output.contains("--json/-j"))
        #expect(!output.contains("\n  image "))
        #expect(!output.contains("\n  hotkey "))
        #expect(!output.contains("\n  perform-action "))
    }

    @Test
    func `--help flag shows help`() async throws {
        let output = try await runPeekaboo(["--help"]).stdout

        // Should show same help as no arguments
        #expect(output.contains("Usage"))
        #expect(output.contains("peekaboo <command>"))
    }

    @Test
    func `help subcommand for each tool`() async throws {
        let subcommands = [
            "screen",
            "config",
            "permissions",
            "see",
            "click",
            "type",
            "scroll",
            "press",
            "action",
            "drag",
            "move",
            "clean",
            "window",
            "menu",
            "app",
            "dock",
            "dialog",
            "agent",
        ]

        for subcommand in subcommands {
            let output = try await runPeekaboo(["help", subcommand]).stdout

            // Each subcommand help should contain a usage card + global flags.
            #expect(output.contains("Usage"), "Help for \(subcommand) should contain Usage")
            #expect(
                output.contains("peekaboo \(subcommand)"),
                "Help for \(subcommand) should contain usage line"
            )
            #expect(
                output.contains("Global Runtime Flags"),
                "Help for \(subcommand) should mention global runtime flags"
            )
            #expect(output.contains("--json"), "Help for \(subcommand) should include JSON flag")

            // Should not show agent execution output
            #expect(!output.contains("[info] Peekaboo Agent"), "Help for \(subcommand) should not invoke agent")
            #expect(!output.contains("📋 Task:"), "Help for \(subcommand) should not show task execution")
        }
    }

    @Test
    func `help with invalid subcommand`() async throws {
        // This should show an error, not invoke the agent
        let result = try await runPeekaboo(["help", "nonexistent"])

        #expect(result.exitStatus != 0)
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        #expect(output.contains("Error:") || output.contains("Unknown subcommand"))
        #expect(!output.contains("[info] Peekaboo Agent"))
    }

    @Test
    func `Runtime validation errors retain their JSON error class`() async throws {
        let result = try await runPeekaboo(["completions", "nushell", "--json"])

        #expect(result.exitStatus == 1)
        #expect(result.stderr.isEmpty)
        let data = try #require(result.stdout.data(using: .utf8))
        let payload = try JSONDecoder().decode(JSONResponse.self, from: data)
        #expect(payload.success == false)
        #expect(payload.error?.code == ErrorCode.VALIDATION_ERROR.rawValue)
        #expect(payload.error?.message.contains("Unsupported shell 'nushell'") == true)
    }

    @Test
    func `Removed command errors include migration advice in text and JSON`() async throws {
        let textResult = try await runPeekaboo(["hotkey"])
        #expect(textResult.exitStatus == 1)
        #expect(textResult.stderr.contains("peekaboo press"))

        let jsonResult = try await runPeekaboo(["image", "--json"])
        #expect(jsonResult.exitStatus == 1)
        #expect(jsonResult.stderr.isEmpty)
        let data = try #require(jsonResult.stdout.data(using: .utf8))
        let payload = try JSONDecoder().decode(JSONResponse.self, from: data)
        #expect(payload.error?.code == ErrorCode.INVALID_ARGUMENT.rawValue)
        #expect(payload.error?.message.contains("Command 'peekaboo image' was removed in v4") == true)
        #expect(payload.error?.hint?.contains("peekaboo see --no-elements") == true)
    }

    @Test
    func `Removed option JSON errors include exact replacement`() async throws {
        let result = try await runPeekaboo(["click", "--coords", "10,20", "--json"])

        #expect(result.exitStatus == 1)
        #expect(result.stderr.isEmpty)
        let data = try #require(result.stdout.data(using: .utf8))
        let payload = try JSONDecoder().decode(JSONResponse.self, from: data)
        #expect(payload.error?.code == ErrorCode.INVALID_ARGUMENT.rawValue)
        #expect(payload.error?.message.contains("Option '--coords' was removed in v4") == true)
        #expect(payload.error?.hint?.contains("--at") == true)
    }

    @Test
    func `Help tells users where runtime flags belong`() async throws {
        let rootHelp = try await runPeekaboo(["--help"])
        #expect(rootHelp.stdout.contains("[runtime flags]"))
        #expect(rootHelp.stdout.contains("Place these after the leaf command"))

        let pressHelp = try await runPeekaboo(["press", "--help"])
        #expect(pressHelp.stdout.contains("peekaboo press [<chord> ...]"))
    }

    @Test
    func `Subcommand --help flag`() async throws {
        // Test that each subcommand's --help flag works
        let subcommands = ["screen", "config", "agent", "see", "click", "press", "action"]

        for subcommand in subcommands {
            let output = try await runPeekaboo([subcommand, "--help"]).stdout

            #expect(output.contains("Usage"), "\(subcommand) --help should show usage")
            #expect(output.contains("Global Runtime Flags"), "\(subcommand) --help should mention global flags")
            #expect(!output.contains("[info] Peekaboo Agent"), "\(subcommand) --help should not invoke agent")
        }
    }

    @Test
    func `Lifecycle and maximize help describe exact background contracts`() async throws {
        let launchHelp = try await runPeekaboo(["app", "launch", "--help"]).stdout
        #expect(launchHelp.contains("--wait-for-window"))
        #expect(launchHelp.contains("exact WindowServer window"))

        let maximizeHelp = try await runPeekaboo(["window", "maximize", "--help"]).stdout
        #expect(maximizeHelp.contains("without entering full screen"))
        #expect(!maximizeHelp.contains("Maximize a window (full screen)"))
    }

    @Test
    func `V4 inventory and interaction help omit removed CLI forms`() async throws {
        let helpPaths = [
            ["app", "list", "--help"],
            ["window", "list", "--help"],
            ["screen", "list", "--help"],
            ["see", "--help"],
            ["click", "--help"],
            ["drag", "--help"],
        ]
        let removedForms = [
            "peekaboo image",
            "peekaboo list apps",
            "peekaboo list windows",
            "peekaboo hotkey",
            "peekaboo inspect-ui",
            "peekaboo perform-action",
            "peekaboo swipe",
            "--coords",
            "--from-coords",
            "--to-coords",
        ]

        for path in helpPaths {
            let output = try await runPeekaboo(path).stdout
            for removed in removedForms {
                #expect(!output.contains(removed), "\(path.joined(separator: " ")) help contains \(removed)")
            }
        }
    }

    // MARK: - Helper Methods

    private func runPeekaboo(_ arguments: [String]) async throws -> CommandRunResult {
        try await InProcessCommandRunner.runWithSharedServices(arguments)
    }
}
#endif
