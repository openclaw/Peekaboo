import Foundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct AgentCommandBasicTests {
    @Test
    func `Agent command exists and has correct configuration`() {
        // Verify the command configuration
        let config = AgentCommand.commandDescription
        #expect(config.commandName == "agent")
        #expect(config.abstract == "Execute complex automation tasks using the Peekaboo agent")
    }

    @Test
    func `Agent help lists subcommands and run options`() async throws {
        let rootResult = try await InProcessCommandRunner.runShared(["agent", "--help"])
        let runResult = try await InProcessCommandRunner.runShared(["agent", "run", "--help"])

        #expect(rootResult.exitStatus == 0)
        #expect(rootResult.combinedOutput.contains("chat      Start an interactive agent chat"))
        #expect(rootResult.combinedOutput.contains("resume    Resume the most recent or a specified session"))
        #expect(rootResult.combinedOutput.contains("run       Run a one-shot automation task"))
        #expect(rootResult.combinedOutput.contains("sessions  List saved agent sessions"))
        #expect(!rootResult.combinedOutput.contains("--realtime"))

        #expect(runResult.exitStatus == 0)
        #expect(runResult.combinedOutput.contains("gpt-5.6"))
        #expect(runResult.combinedOutput.contains("claude-sonnet-5"))
        #expect(runResult.combinedOutput.contains("Maximum model turns before failing (1-100, default 100)"))
        #expect(!runResult.combinedOutput.contains("--realtime"))
        #expect(!runResult.combinedOutput.contains("use with task argument"))
    }

    @Test
    func `Agent rejects the removed realtime flag`() async throws {
        let result = try await InProcessCommandRunner.runShared(["agent", "--realtime"], allowedExitCodes: [1])

        #expect(result.exitStatus != 0)
        #expect(result.combinedOutput.contains("Unknown option --realtime"))
    }
}
