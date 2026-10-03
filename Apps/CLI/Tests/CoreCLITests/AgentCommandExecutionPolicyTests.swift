import Commander
import Foundation
import PeekabooAgentRuntimeTestSupport
import PeekabooCore
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCLI

@MainActor
struct AgentCommandExecutionPolicyTests {
    init() throws {
        try AuthorityTestSupport.prepare()
    }

    @Test(arguments: [false, true])
    func `all Agent invocation forms bind temporary clipboard independently of foreground`(foreground: Bool) throws {
        let flags = ["--allow-temporary-clipboard"] + (foreground ? ["--allow-foreground"] : [])
        let shorthand = try AgentCommand.parse(["Paste a synthetic fragment"] + flags)
        let run = try AgentRunSubcommand.parse(["Paste a synthetic fragment"] + flags)
        let chat = try AgentChatSubcommand.parse(flags)
        let resume = try AgentResumeSubcommand.parse(flags)
        var commands = [shorthand]
        for options in [run.options, chat.options, resume.options] {
            var command = AgentCommand()
            options.apply(to: &command)
            commands.append(command)
        }
        for command in commands {
            #expect(command.allowTemporaryClipboard)
            #expect(command.toolExecutionAuthority.temporaryClipboardPasteGranted)
            #expect(command.toolExecutionAuthority.basePolicy == (foreground ? .foregroundAllowed : .backgroundOnly))
        }
    }

    @Test
    @MainActor
    func `CLI cannot add a temporary clipboard maximum on resume`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-cli-clipboard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = try AgentSessionManager(sessionDirectory: directory)
        let service = try AuthorityTestSupport.agent(services: AuthorityTestSupport.services(), sessionManager: manager)
        let session = Self.session(id: "background", policy: .backgroundOnly)
        try manager.saveSession(session)
        var command = AgentCommand()
        command.resumeSession = session.id
        command.allowTemporaryClipboard = true
        await #expect(throws: ExitCode.self) { try await command.requireRequestedSession(service) }
    }

    @Test
    func `Agent defaults to background-only and requires explicit foreground opt-in`() throws {
        let defaultCommand = try AgentCommand.parse(["Inspect TextEdit"])
        #expect(defaultCommand.allowForeground == false)
        #expect(defaultCommand.toolExecutionAuthority == .backgroundOnly)

        let foregroundCommand = try AgentCommand.parse(["Inspect TextEdit", "--allow-foreground"])
        #expect(foregroundCommand.allowForeground == true)
        #expect(foregroundCommand.toolExecutionAuthority.basePolicy == .foregroundAllowed)
    }

    @Test
    func `foreground opt-in remains independent from shell authority`() throws {
        let command = try AgentCommand.parse(["Use the foreground", "--allow-foreground"])
        let shellResponse = command.toolExecutionAuthority.rejection(
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
        let service = try AuthorityTestSupport.agent(services: AuthorityTestSupport.services(), sessionManager: manager)
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
        let service = try AuthorityTestSupport.agent(services: AuthorityTestSupport.services(), sessionManager: manager)
        let session = Self.session(id: "foreground", policy: .foregroundAllowed)
        try manager.saveSession(session)

        var command = AgentCommand()
        command.resumeSession = session.id
        command.allowForeground = false
        try await command.requireRequestedSession(service)
        #expect(command.toolExecutionAuthority == .backgroundOnly)
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
            toolExecutionPolicy: MCPToolExecutionPolicy.foregroundAllowed.rawValue,
            temporaryClipboardPasteMaximum: nil
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
            toolExecutionPolicy: session.toolExecutionPolicy,
            temporaryClipboardPasteMaximum: session.temporaryClipboardPasteMaximum
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
