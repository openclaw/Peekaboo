import Foundation
import PeekabooFoundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct AgentSessionExecutionPolicyTests {
    @Test
    @MainActor
    func `new policy persists and reloads exactly`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = try AgentSessionManager(sessionDirectory: directory)
        let session = Self.session(id: "foreground", policy: .foregroundAllowed)
        try manager.saveSession(session)

        let freshManager = try AgentSessionManager(sessionDirectory: directory)
        let loaded = try #require(try await freshManager.loadSession(id: session.id))
        #expect(loaded.effectiveToolExecutionPolicy == .foregroundAllowed)
        #expect(freshManager.listSessions().first?.toolExecutionPolicy == .foregroundAllowed)
    }

    @Test
    @MainActor
    func `fresh non-directory-hinted session path saves on first attempt`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-policy-root-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("sessions", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = try AgentSessionManager(sessionDirectory: directory)
        let session = Self.session(id: UUID().uuidString, policy: .backgroundOnly)
        try manager.saveSession(session)

        let loaded = try #require(try await manager.loadSession(id: session.id))
        #expect(loaded.id == session.id)
        #expect(loaded.effectiveToolExecutionPolicy == .backgroundOnly)
    }

    @Test
    func `legacy session without policy decodes as background-only`() throws {
        let encoded = try JSONEncoder().encode(Self.session(id: "legacy", policy: .foregroundAllowed))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "toolExecutionPolicy")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AgentSession.self, from: legacy)
        #expect(decoded.toolExecutionPolicy == nil)
        #expect(decoded.effectiveToolExecutionPolicy == .backgroundOnly)
    }

    @Test
    func `legacy session summary without policy decodes as background-only`() throws {
        let now = Date()
        let encoded = try JSONEncoder().encode(SessionSummary(
            id: "legacy-summary",
            modelName: "test-model",
            createdAt: now,
            lastAccessedAt: now,
            messageCount: 2,
            status: .active,
            summary: "task",
            toolExecutionPolicy: .foregroundAllowed))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "toolExecutionPolicy")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SessionSummary.self, from: legacy)
        #expect(decoded.toolExecutionPolicy == .backgroundOnly)
        #expect(decoded.id == "legacy-summary")
        #expect(decoded.summary == "task")
    }

    @Test
    func `unrestricted persisted value cannot grant Agent shell authority`() {
        let session = Self.session(id: "tampered", policy: .unrestricted)
        #expect(session.effectiveToolExecutionPolicy == .backgroundOnly)
    }

    @Test
    @MainActor
    func `resume defaults each invocation to background and refuses broadening`() throws {
        let background = Self.session(id: "background", policy: .backgroundOnly)
        #expect(try PeekabooAgentService.resolveToolExecutionPolicy(
            for: background,
            requested: nil) == .backgroundOnly)
        #expect(try PeekabooAgentService.resolveToolExecutionPolicy(
            for: background,
            requested: .backgroundOnly) == .backgroundOnly)
        #expect(throws: PeekabooError.self) {
            try PeekabooAgentService.resolveToolExecutionPolicy(
                for: background,
                requested: .foregroundAllowed)
        }

        let foreground = Self.session(id: "foreground", policy: .foregroundAllowed)
        #expect(try PeekabooAgentService.resolveToolExecutionPolicy(
            for: foreground,
            requested: nil) == .backgroundOnly)
        #expect(try PeekabooAgentService.resolveToolExecutionPolicy(
            for: foreground,
            requested: .backgroundOnly) == .backgroundOnly)
        #expect(try PeekabooAgentService.resolveToolExecutionPolicy(
            for: foreground,
            requested: .foregroundAllowed) == .foregroundAllowed)
        #expect(throws: PeekabooError.self) {
            try PeekabooAgentService.resolveToolExecutionPolicy(
                for: foreground,
                requested: .unrestricted)
        }
    }

    @Test
    @MainActor
    func `forged persisted foreground value cannot elevate a default resume`() throws {
        let forged = Self.session(id: "forged", policy: .foregroundAllowed)
        #expect(try PeekabooAgentService.resolveToolExecutionPolicy(
            for: forged,
            requested: nil) == .backgroundOnly)
    }

    @Test
    @MainActor
    func `background resume preserves stored foreground maximum`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = try AgentSessionManager(sessionDirectory: directory)
        let service = try PeekabooAgentService(services: PeekabooServices(), sessionManager: manager)
        let session = Self.session(id: "foreground-maximum", policy: .foregroundAllowed)
        try manager.saveSession(session)

        let context = service.makeContinuationContext(
            from: session,
            userMessage: "background turn",
            model: .ollama(.llama33),
            toolExecutionPolicy: .backgroundOnly)
        try service.saveExecutionSession(
            context: context,
            model: .ollama(.llama33),
            finalMessages: context.messages + [ModelMessage.assistant("done")],
            endTime: Date(),
            toolCallCount: 0,
            usage: nil,
            status: SessionStatus.completed.rawValue)

        let loaded = try #require(try await manager.loadSession(id: session.id))
        #expect(context.toolExecutionPolicy == .backgroundOnly)
        #expect(context.storedToolExecutionPolicy == .foregroundAllowed)
        #expect(loaded.effectiveToolExecutionPolicy == .foregroundAllowed)
        #expect(try PeekabooAgentService.resolveToolExecutionPolicy(
            for: loaded,
            requested: .foregroundAllowed) == .foregroundAllowed)
    }

    @Test
    @MainActor
    func `session summary skips injected desktop state and preserves lifecycle`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = try AgentSessionManager(sessionDirectory: directory)
        let now = Date()
        let session = AgentSession(
            id: "summary",
            modelName: "test-model",
            toolExecutionPolicy: .backgroundOnly,
            messages: [
                .system("system"),
                .user("<DESKTOP_STATE nonce>\nDESKTOP_STATE | untrusted\n</DESKTOP_STATE nonce>"),
                .user("Original exact task"),
            ],
            metadata: SessionMetadata(customData: ["status": SessionStatus.completed.rawValue]),
            createdAt: now,
            updatedAt: now)
        try manager.saveSession(session)

        let summary = try #require(manager.listSessions().first)
        #expect(summary.summary == "Original exact task")
        #expect(summary.status == .completed)
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
            updatedAt: now)
    }
}
