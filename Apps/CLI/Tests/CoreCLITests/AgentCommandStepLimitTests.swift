import Foundation
import PeekabooAgentRuntime
import PeekabooFoundation
import Tachikoma
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

    @Test(arguments: ["--resume", "--resume-session", "--list-sessions"])
    func `Agent rejects session lookup flags when caching is disabled`(_ option: String) throws {
        let arguments = if option == "--resume-session" {
            ["--no-cache", option, "session-id"]
        } else {
            ["--no-cache", option]
        }
        let command = try AgentCommand.parse(arguments)

        #expect(throws: PeekabooError.self) {
            try command.validateSessionOptions()
        }
    }

    @Test
    func `Chat recovers the saved session from step exhaustion`() throws {
        let command = try AgentCommand.parse([])
        let sessionId = UUID().uuidString
        let error = PeekabooAgentService.AgentStepLimitExceededError(maxSteps: 1, sessionId: sessionId)
        let ephemeralError = PeekabooAgentService.AgentStepLimitExceededError(
            maxSteps: 1,
            sessionId: "ephemeral",
            sessionWasPersisted: false
        )

        #expect(command.stepLimitSessionId(from: error) == sessionId)
        #expect(command.stepLimitSessionId(from: ephemeralError) == nil)
        #expect(command.stepLimitSessionId(from: PeekabooError.commandFailed("other")) == nil)
    }

    @Test(arguments: [false, true])
    func `Step limit failure JSON preserves only sanitized progress`(_ persisted: Bool) throws {
        let privateText = "private synthetic draft"
        let call = AgentToolCall(
            id: "typed-call",
            name: "type",
            arguments: [
                "text": AnyAgentToolValue(string: privateText),
                "window_id": AnyAgentToolValue(int: 42),
            ]
        )
        let result = AgentExecutionResult(
            content: privateText,
            messages: [
                ModelMessage(role: .assistant, content: [.text(privateText), .toolCall(call)]),
                ModelMessage(role: .tool, content: [.toolResult(AgentToolResult(
                    toolCallId: call.id,
                    result: AnyAgentToolValue(object: [
                        "success": AnyAgentToolValue(bool: true),
                        "mutation_dispatched": AnyAgentToolValue(bool: true),
                        "output": AnyAgentToolValue(string: privateText),
                    ])
                ))]),
            ],
            metadata: AgentMetadata(
                executionTime: 1,
                toolCallCount: 1,
                modelName: "test",
                startTime: Date(),
                endTime: Date()
            )
        )
        let error = PeekabooAgentService.AgentStepLimitExceededError(
            maxSteps: 1,
            sessionId: "synthetic-session",
            sessionWasPersisted: persisted,
            executionTrace: result.executionTrace()
        )
        let command = try AgentCommand.parse([])
        let response = command.makeStepLimitErrorResponse(error, message: error.localizedDescription)
        let data = try JSONEncoder().encode(response)
        let text = try #require(String(data: data, encoding: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["data"] as? [String: Any])
        let trace = try #require(payload["executionTrace"] as? [String: Any])
        let entries = try #require(trace["entries"] as? [[String: Any]])

        #expect(object["success"] as? Bool == false)
        #expect((object["error"] as? [String: Any])?["code"] as? String == "AGENT_ERROR")
        #expect(payload["maxSteps"] as? Int == 1)
        #expect(payload["sessionId"] as? String == (persisted ? "synthetic-session" : nil))
        #expect(text.contains("synthetic-session") == persisted)
        #expect(!text.contains(privateText))
        #expect(payload["messages"] == nil)
        #expect(payload["content"] == nil)
        #expect(entries.count == 1)
        #expect(entries.first?["id"] as? String == "typed-call")
        #expect(entries.first?["mutationDispatch"] as? String == "dispatched")
        #expect(trace["totalCallCount"] as? Int == 1)
        #expect(trace["truncated"] as? Bool == false)
        #expect(response.data.executionTrace == result.executionTrace())
    }

    @Test(arguments: [1, 100], [false, true])
    func `Step limit guidance prevents blind replay and retains initializer compatibility`(
        _ maxSteps: Int,
        _ persisted: Bool
    ) throws {
        let error = PeekabooAgentService.AgentStepLimitExceededError(
            maxSteps: maxSteps,
            sessionId: "synthetic-session",
            sessionWasPersisted: persisted
        )
        let command = try AgentCommand.parse([])
        let response = command.makeStepLimitErrorResponse(error, message: error.localizedDescription)

        #expect(error.executionTrace == nil)
        #expect(response.data.executionTrace == nil)
        #expect(!response.success)
        #expect(error.localizedDescription.contains("Inspect current app state"))
        #expect(error.localizedDescription.contains("do not blindly repeat actions"))
        #expect(!error.localizedDescription.contains("retry with a larger"))
        #expect(error.localizedDescription.contains("cannot be resumed") == !persisted)
        #expect(error.localizedDescription.contains("can be resumed") == persisted)
        #expect(error.localizedDescription.contains("--max-steps") == (maxSteps < 100))
    }
}
