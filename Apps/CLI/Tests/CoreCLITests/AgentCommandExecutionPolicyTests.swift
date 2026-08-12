import Commander
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCLI

struct AgentCommandExecutionPolicyTests {
    @Test
    func `Agent defaults to background-only and requires explicit foreground opt-in`() throws {
        let defaultCommand = try AgentCommand.parse(["Inspect TextEdit"])
        #expect(defaultCommand.allowForeground == false)
        #expect(defaultCommand.newSessionToolExecutionPolicy == .backgroundOnly)
        #expect(defaultCommand.requestedResumeToolExecutionPolicy == .backgroundOnly)

        let foregroundCommand = try AgentCommand.parse(["Inspect TextEdit", "--allow-foreground"])
        #expect(foregroundCommand.allowForeground == true)
        #expect(foregroundCommand.newSessionToolExecutionPolicy == .foregroundAllowed)
        #expect(foregroundCommand.requestedResumeToolExecutionPolicy == .foregroundAllowed)
    }

    @Test
    func `foreground opt-in remains independent from shell authority`() throws {
        let command = try AgentCommand.parse(["Use the foreground", "--allow-foreground"])
        let shellResponse = command.newSessionToolExecutionPolicy.rejection(
            toolName: "shell",
            arguments: .init(raw: ["command": "/usr/bin/osascript -e ignored"])
        )

        #expect(shellResponse?.isError == true)
    }

    @Test
    @MainActor
    func `CLI resume cannot broaden a background-only session`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-cli-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = try AgentSessionManager(sessionDirectory: directory)
        let service = try PeekabooAgentService(services: PeekabooServices(), sessionManager: manager)
        let session = Self.session(id: "background", policy: .backgroundOnly)
        try manager.saveSession(session)

        var command = AgentCommand()
        command.resumeSession = session.id
        command.allowForeground = true

        await #expect(throws: ExitCode.self) {
            try await command.requireRequestedSession(service)
        }
    }

    @Test
    @MainActor
    func `CLI resume defaults a stored foreground session back to background`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-cli-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = try AgentSessionManager(sessionDirectory: directory)
        let service = try PeekabooAgentService(services: PeekabooServices(), sessionManager: manager)
        let session = Self.session(id: "foreground", policy: .foregroundAllowed)
        try manager.saveSession(session)

        var command = AgentCommand()
        command.resumeSession = session.id
        command.allowForeground = false
        try await command.requireRequestedSession(service)
        #expect(command.requestedResumeToolExecutionPolicy == .backgroundOnly)
    }

    @Test
    func `human session output keeps the full copyable ID task status and policy`() {
        let command = AgentCommand()
        let session = AgentSessionInfo(
            id: "12345678-1234-1234-1234-123456789abc",
            task: "Inspect\nTextEdit\u{1B}[31m",
            created: Date(),
            lastModified: Date(),
            messageCount: 4,
            status: SessionStatus.active.rawValue,
            toolExecutionPolicy: MCPToolExecutionPolicy.foregroundAllowed.rawValue
        )

        let output = command.sessionDisplayLines(index: 0, session: session).joined(separator: "\n")

        #expect(output.contains("12345678-1234-1234-1234-123456789abc"))
        #expect(output.contains("Inspect TextEdit[31m"))
        #expect(!output.contains("\u{1B}[31m"))
        #expect(output.contains("active (saved/resumable; not a live-process signal)"))
        #expect(output.contains("Stored policy maximum: foreground_allowed"))
        #expect(output.contains("Next resume default: background_only"))

        let json = command.sessionJSONObject(session)
        #expect(json["id"] as? String == session.id)
        #expect(json["task"] as? String == session.task)
        #expect(json["status"] as? String == SessionStatus.active.rawValue)
        #expect(json["toolExecutionPolicy"] as? String == MCPToolExecutionPolicy.foregroundAllowed.rawValue)

        let completed = AgentSessionInfo(
            id: session.id,
            task: session.task,
            created: session.created,
            lastModified: session.lastModified,
            messageCount: session.messageCount,
            status: SessionStatus.completed.rawValue,
            toolExecutionPolicy: session.toolExecutionPolicy
        )
        let completedOutput = command.sessionDisplayLines(index: 0, session: completed).joined(separator: "\n")
        #expect(completedOutput.contains("completed (saved/resumable; last run finished)"))
    }

    @Test
    func `Agent help explains authority exact IDs and active busy retry semantics`() {
        let rootHelp = AgentRootCommand.helpMessage()
        let runHelp = AgentRunSubcommand.helpMessage()
        let resumeHelp = AgentResumeSubcommand.helpMessage()
        let sessionsHelp = AgentSessionsSubcommand.helpMessage()

        #expect(rootHelp.contains("background-only"))
        #expect(runHelp.contains("immutable maximum"))
        #expect(runHelp.contains("never exposes the Shell tool"))
        #expect(resumeHelp.contains("exact full ID"))
        #expect(resumeHelp.contains("wait for it to finish and retry"))
        #expect(resumeHelp.contains("Every resumed process invocation defaults to"))
        #expect(resumeHelp.contains("background-only"))
        #expect(sessionsHelp.contains("not mean a process is currently running"))
        #expect(sessionsHelp.contains("not busy"))
    }

    private static func session(id: String, policy: MCPToolExecutionPolicy) -> AgentSession {
        let now = Date()
        return AgentSession(
            id: id,
            modelName: "test-model",
            toolExecutionPolicy: policy,
            messages: [.system("system"), .user("task")],
            metadata: SessionMetadata(),
            createdAt: now,
            updatedAt: now
        )
    }
}
