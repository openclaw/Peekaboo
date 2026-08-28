import Foundation
import OSLog
import PeekabooAgentRuntime
import Tachikoma
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct AgentCommandAutomationEventTests {
    @Test
    @MainActor
    func `Agent completion event omits task result and model content`() async throws {
        let taskText = """
        PEEKABOO_ALERT17_SENTINEL
        prompt=TEST_PROMPT_MARKER
        credential=TEST_CREDENTIAL_MARKER
        path=/Users/example/private
        host=private-host.invalid
        """
        let now = Date()
        let result = AgentExecutionResult(
            content: "TEST_MODEL_OUTPUT_MARKER",
            sessionId: "TEST_SESSION_PRIVATE_MARKER",
            usage: Usage(inputTokens: 11, outputTokens: 7),
            metadata: AgentMetadata(
                executionTime: 1.25,
                toolCallCount: 2,
                modelName: "TEST_MODEL_MARKER/result",
                startTime: now,
                endTime: now,
                context: [
                    "apiKey": "TEST_PASSWORD_MARKER",
                    "prompt": "TEST_RESULT_PROMPT_MARKER",
                    "status": "TEST_STATUS_PRIVATE_MARKER",
                ]
            )
        )
        let startedAt = Date()

        AgentCommand.logAgentAutomationResult(result, task: taskText, dryRun: false)

        let events = try await Self.agentEvents(since: startedAt, taskLength: taskText.count)
        for fragment in [
            "PEEKABOO_ALERT17_SENTINEL",
            "TEST_PROMPT_MARKER",
            "TEST_RESULT_PROMPT_MARKER",
            "TEST_CREDENTIAL_MARKER",
            "TEST_PASSWORD_MARKER",
            "TEST_MODEL_MARKER",
            "TEST_MODEL_OUTPUT_MARKER",
            "TEST_SESSION_PRIVATE_MARKER",
            "TEST_STATUS_PRIVATE_MARKER",
            "/Users/example/private",
            "private-host.invalid",
        ] {
            #expect(events.allSatisfy { !$0.contains(fragment) })
        }

        let projectedEvents = events.filter {
            $0.hasPrefix("result status=completed ") && $0.contains("task_chars=\(taskText.count)")
        }
        #expect(projectedEvents.count == 1)
        let event = try #require(projectedEvents.first)
        let parts = event.split(separator: " ")
        #expect(parts.first == "result")
        let fields = try Dictionary(uniqueKeysWithValues: parts.dropFirst().map { part in
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else {
                throw AgentEventTestError.malformedEvent
            }
            return try (String(#require(pair.first)), String(#require(pair.last)))
        })
        #expect(Set(fields.keys) == [
            "status", "task_chars", "model", "duration", "tools", "dry_run", "session", "tokens",
        ])
        #expect(fields["status"] == "completed")
        #expect(fields["task_chars"] == String(taskText.count))
        #expect(fields["model"] == "other")
        let duration = try #require(fields["duration"])
        #expect(duration.hasSuffix("s"))
        #expect(Double(String(duration.dropLast())) != nil)
        #expect(fields["tools"] == "2")
        #expect(fields["dry_run"] == "false")
        #expect(fields["session"] == "invalid")
        #expect(fields["tokens"] == "18")
    }

    private static func agentEvents(since date: Date, taskLength: Int) async throws -> [String] {
        let predicate = NSPredicate(
            format: "subsystem == %@ AND category == %@",
            "boo.peekaboo.playground",
            AutomationLogCategory.agent.rawValue
        )
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: date)
            let events = try store.getEntries(at: position, matching: predicate).map(\.composedMessage)
            if events.contains(where: {
                $0.hasPrefix("result status=completed ") && $0.contains("task_chars=\(taskLength)")
            }) {
                return events
            }
        }
        throw AgentEventTestError.missingEvent
    }

    private enum AgentEventTestError: Error {
        case malformedEvent
        case missingEvent
    }
}
