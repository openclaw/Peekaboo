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
    func `Agent help lists current model examples`() async throws {
        let result = try await InProcessCommandRunner.runShared(["agent", "--help"])

        #expect(result.exitStatus == 0)
        #expect(result.combinedOutput.contains("gpt-5.6"))
        #expect(result.combinedOutput.contains("claude-sonnet-5"))
        #expect(result.combinedOutput.contains("Maximum model turns before failing (1-100, default 100)"))
        #expect(result.combinedOutput.contains("Resume the most recent session"))
        #expect(!result.combinedOutput.contains("use with task argument"))
    }
}
