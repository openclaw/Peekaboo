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
