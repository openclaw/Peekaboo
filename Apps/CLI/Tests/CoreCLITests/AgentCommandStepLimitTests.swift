import Foundation
import PeekabooAgentRuntime
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct AgentCommandStepLimitTests {
    @Test(arguments: [1, 100])
    func `Agent accepts supported step limits`(_ maxSteps: Int) throws {
        var command = try AgentCommand.parse([])
        command.maxSteps = maxSteps

        #expect(try command.validatedMaxStepCount() == maxSteps)
    }

    @Test(arguments: [-1, 0, 101])
    func `Agent rejects unsupported step limits`(_ maxSteps: Int) throws {
        var command = try AgentCommand.parse([])
        command.maxSteps = maxSteps

        let error = #expect(throws: PeekabooError.self) {
            try command.validatedMaxStepCount()
        }

        if case let .invalidInput(message) = error {
            #expect(message.contains("between 1 and 100"))
            #expect(message.contains("received \(maxSteps)"))
        } else {
            Issue.record("Expected invalidInput error")
        }
    }

    @Test
    func `Agent defaults to maximum supported step limit`() throws {
        let command = try AgentCommand.parse([])

        #expect(try command.validatedMaxStepCount() == 100)
    }

    @Test
    func `Chat recovers the saved session from step exhaustion`() throws {
        let command = try AgentCommand.parse([])
        let sessionId = UUID().uuidString
        let error = PeekabooAgentService.AgentStepLimitExceededError(maxSteps: 1, sessionId: sessionId)

        #expect(command.stepLimitSessionId(from: error) == sessionId)
        #expect(command.stepLimitSessionId(from: PeekabooError.commandFailed("other")) == nil)
    }
}
