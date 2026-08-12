import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAgentRuntime

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
