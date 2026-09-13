import Foundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct AgentResumeCLITests {
    @Test
    func `Agent defaults to no task or resume selection`() throws {
        let command = try AgentCommand.parse([])

        #expect(command.task == nil)
        #expect(!command.resume)
        #expect(command.resumeSession == nil)
    }

    @Test
    func `Resume subcommand selects latest session without an ID`() throws {
        let command = try AgentResumeSubcommand.parse([])

        #expect(command.sessionId == nil)
        #expect(!command.options.allowForeground)
        #expect(command.options.model == nil)
    }

    @Test
    func `Resume subcommand retains exact ID and execution options`() throws {
        let id = "12345678-1234-1234-1234-123456789abc"
        let command = try AgentResumeSubcommand.parse([
            id, "--model", "ollama/test-model", "--max-steps", "12", "--allow-foreground",
        ])

        #expect(command.sessionId == id)
        #expect(command.options.model == "ollama/test-model")
        #expect(command.options.maxSteps == 12)
        #expect(command.options.allowForeground)
    }

    @Test(arguments: [
        "Continue with émojis 👻 and unicode ∆∇∫",
        "Task with \"quotes\" and 'apostrophes' and {brackets} and <tags>",
        String(repeating: "Long continuation. ", count: 100),
    ])
    func `Resume parsing preserves continuation text`(_ task: String) throws {
        let command = try AgentCommand.parse([task, "--resume-session", "saved-session"])

        #expect(command.task == task)
        #expect(command.resumeSession == "saved-session")
        #expect(!command.resume)
    }

    @Test
    func `Session JSON uses the production projection and complete timestamps`() throws {
        let command = AgentCommand()
        let session = AgentSessionInfo(
            id: "saved-session",
            task: "Continue \"document\" 👻",
            created: Date(timeIntervalSince1970: 1_700_000_000),
            lastModified: Date(timeIntervalSince1970: 1_700_000_060),
            messageCount: 4,
            status: "active",
            toolExecutionPolicy: "background_only"
        )
        let data = try JSONSerialization.data(withJSONObject: command.sessionJSONObject(session))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["id"] as? String == session.id)
        #expect(json["task"] as? String == session.task)
        #expect(json["createdAt"] as? String == "2023-11-14T22:13:20Z")
        #expect(json["updatedAt"] as? String == "2023-11-14T22:14:20Z")
        #expect(json["messageCount"] as? Int == 4)
        #expect(json["status"] as? String == "active")
        #expect(json["toolExecutionPolicy"] as? String == "background_only")
    }

    @Test(arguments: [
        (30.0, "just now"), (90.0, "1 minute ago"), (300.0, "5 minutes ago"),
        (3900.0, "1 hour ago"), (7200.0, "2 hours ago"),
        (86500.0, "1 day ago"), (172_800.0, "2 days ago"),
    ])
    func `Session age uses the production formatter`(_ interval: TimeInterval, _ expected: String) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(PeekabooCLI.formatTimeAgo(now.addingTimeInterval(-interval), from: now) == expected)
    }
}
