import Foundation
import PeekabooAgentRuntimeTestSupport
import PeekabooFoundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized, AuthorityTestIsolation())
@MainActor
struct AgentSessionExecutionPolicyTests {
    @Test
    func `catalog prompt refresh preserves first system identity and every other history message`() throws {
        let firstSystem = ModelMessage(
            id: "retained-system-id",
            role: .system,
            content: [.text("stale foreground instructions"), .text("superseded recipe")],
            timestamp: Date(timeIntervalSince1970: 1234),
            channel: .commentary,
            metadata: MessageMetadata(
                conversationId: "retained-conversation",
                turnId: "retained-turn",
                customData: ["marker": "retain"]))
        let history: [ModelMessage] = [
            .user("Earlier user input"),
            firstSystem,
            .system("Separate system policy must remain"),
            .assistant("Prior assistant response"),
            ModelMessage(role: .tool, content: [.text("Prior tool evidence")]),
            .user("Current user input"),
        ]
        let updated = PeekabooAgentService.updatingSystemPrompt(
            in: history,
            for: .ollama(.llama33),
            executionAuthority: .backgroundOnly,
            availableToolNames: ["permissions"])

        #expect(updated.count == history.count)
        let system = try #require(updated.first { $0.role == .system })
        #expect(system.id == firstSystem.id)
        #expect(system.timestamp == firstSystem.timestamp)
        #expect(system.channel == firstSystem.channel)
        #expect(system.metadata == firstSystem.metadata)
        #expect(system.content == [.text(AgentSystemPrompt.generate(
            for: .ollama(.llama33),
            executionAuthority: .backgroundOnly,
            availableToolNames: ["permissions"]))])
        for index in history.indices where index != 1 {
            #expect(updated[index] == history[index])
        }
        #expect(history[1] == firstSystem)
        #expect(PeekabooAgentService.updatingSystemPrompt(
            in: updated,
            for: .ollama(.llama33),
            executionAuthority: .backgroundOnly,
            availableToolNames: ["permissions"]) == updated)
    }

    @Test(arguments: [false, true])
    func `catalog prompt inserts one missing system message without replacing user history`(emptyHistory: Bool) {
        let history: [ModelMessage] = emptyHistory ? [] : [.user("Original task"), .assistant("Prior answer")]
        let updated = PeekabooAgentService.updatingSystemPrompt(
            in: history,
            for: .ollama(.llama33),
            executionAuthority: .backgroundOnly,
            availableToolNames: [])
        #expect(updated.count == history.count + 1)
        #expect(updated.first?.role == .system)
        #expect(Array(updated.dropFirst()) == history)
        #expect(updated.first?.content == [.text(AgentSystemPrompt.generate(availableToolNames: []))])
        #expect(PeekabooAgentService.updatingSystemPrompt(
            in: updated,
            for: .ollama(.llama33),
            executionAuthority: .backgroundOnly,
            availableToolNames: []) == updated)
    }

    @Test
    @MainActor
    func `temporary clipboard saved maximum is additive and never an invocation grant`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-clipboard-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = try AgentSessionManager(sessionDirectory: directory)
        let service = try AuthorityTestSupport.agent(services: AuthorityTestSupport.services(), sessionManager: manager)
        let grant = MCPToolExecutionAuthority(temporaryClipboardPasteGranted: true)
        let session = Self.session(id: "clipboard-maximum", policy: .backgroundOnly, clipboardMaximum: true)
        try manager.saveSession(session)
        let loaded = try #require(try await manager.loadSession(id: session.id))
        let data = try JSONEncoder().encode(loaded)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["toolExecutionPolicy"] as? String == "background_only")
        #expect(object["temporaryClipboardPasteMaximum"] as? Bool == true)
        #expect(manager.listSessions().first?.temporaryClipboardPasteMaximum == true)
        #expect(try PeekabooAgentService.resolveToolExecutionAuthority(for: loaded, requested: nil) == .backgroundOnly)
        #expect(try PeekabooAgentService.resolveToolExecutionAuthority(for: loaded, requested: grant) == grant)
        #expect(throws: PeekabooError.self) {
            try PeekabooAgentService.resolveToolExecutionAuthority(
                for: loaded,
                requested: .init(basePolicy: .foregroundAllowed))
        }

        let resumed = service.makeContinuationContext(from: loaded, userMessage: nil, model: .ollama(.llama33))
        #expect(resumed.toolExecutionAuthority == .backgroundOnly)
        #expect(resumed.storedToolExecutionAuthority == grant)
        let prompt = resumed.messages.first?.content.compactMap { part -> String? in
            guard case let .text(text) = part else { return nil }
            return text
        }.joined()
        #expect(prompt?.contains("explicit temporary-clipboard permission") == false)
        try service.saveExecutionSession(
            context: resumed,
            model: .ollama(.llama33),
            finalMessages: resumed.messages,
            endTime: Date(),
            toolCallCount: 0,
            usage: nil,
            status: "completed")
        #expect(try await manager.loadSession(id: session.id)?.temporaryClipboardPasteMaximum == true)
    }

    @Test
    @MainActor
    func `legacy and forged saved clipboard data cannot supply fresh permission`() throws {
        let legacy = Self.session(id: "legacy-clipboard", policy: .backgroundOnly)
        #expect(legacy.temporaryClipboardPasteMaximum == nil)
        #expect(legacy.maximumToolExecutionAuthority == .backgroundOnly)
        #expect(throws: PeekabooError.self) {
            try PeekabooAgentService.resolveToolExecutionAuthority(
                for: legacy, requested: .init(temporaryClipboardPasteGranted: true))
        }
        let encoded = try JSONEncoder().encode(legacy)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["temporaryClipboardPasteMaximum"] = true
        object["toolExecutionPolicy"] = "foreground_allowed"
        let forged = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(try PeekabooAgentService.resolveToolExecutionAuthority(for: forged, requested: nil) == .backgroundOnly)
        #expect(try PeekabooAgentService.resolveToolExecutionAuthority(for: forged, requested: nil)
            .basePolicy == .backgroundOnly)
        let foreground = Self.session(id: "legacy-foreground", policy: .foregroundAllowed)
        #expect(try PeekabooAgentService.resolveToolExecutionAuthority(
            for: foreground, requested: .init(temporaryClipboardPasteGranted: true)).temporaryClipboardPasteGranted)
    }

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
        #expect(try PeekabooAgentService.resolveToolExecutionAuthority(
            for: background,
            requested: nil).basePolicy == .backgroundOnly)
        #expect(try PeekabooAgentService.resolveToolExecutionAuthority(
            for: background,
            requested: .backgroundOnly).basePolicy == .backgroundOnly)
        #expect(throws: PeekabooError.self) {
            try PeekabooAgentService.resolveToolExecutionAuthority(
                for: background,
                requested: .init(basePolicy: .foregroundAllowed))
        }

        let foreground = Self.session(id: "foreground", policy: .foregroundAllowed)
        #expect(try PeekabooAgentService.resolveToolExecutionAuthority(
            for: foreground,
            requested: nil).basePolicy == .backgroundOnly)
        #expect(try PeekabooAgentService.resolveToolExecutionAuthority(
            for: foreground,
            requested: .backgroundOnly).basePolicy == .backgroundOnly)
        #expect(try PeekabooAgentService.resolveToolExecutionAuthority(
            for: foreground,
            requested: .init(basePolicy: .foregroundAllowed)).basePolicy == .foregroundAllowed)
        #expect(throws: PeekabooError.self) {
            try PeekabooAgentService.resolveToolExecutionAuthority(
                for: foreground,
                requested: .init(basePolicy: .unrestricted))
        }
    }

    @Test
    @MainActor
    func `forged persisted foreground value cannot elevate a default resume`() throws {
        let forged = Self.session(id: "forged", policy: .foregroundAllowed)
        #expect(try PeekabooAgentService.resolveToolExecutionAuthority(
            for: forged,
            requested: nil).basePolicy == .backgroundOnly)
    }

    @Test
    @MainActor
    func `background resume preserves stored foreground maximum`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = try AgentSessionManager(sessionDirectory: directory)
        let service = try AuthorityTestSupport.agent(services: AuthorityTestSupport.services(), sessionManager: manager)
        let session = Self.session(id: "foreground-maximum", policy: .foregroundAllowed)
        try manager.saveSession(session)

        let context = service.makeContinuationContext(
            from: session,
            userMessage: "background turn",
            model: .ollama(.llama33),
            toolExecutionAuthority: .backgroundOnly)
        let executionMessages = PeekabooAgentService.updatingSystemPrompt(
            in: context.messages,
            for: .ollama(.llama33),
            executionAuthority: context.toolExecutionAuthority,
            availableToolNames: ["permissions"])
        #expect(executionMessages.first?.id == session.messages.first?.id)
        #expect(executionMessages.first?.content == [.text(AgentSystemPrompt.generate(
            availableToolNames: ["permissions"]))])
        #expect(executionMessages.last?.content == [.text("background turn")])
        try service.saveExecutionSession(
            context: context,
            model: .ollama(.llama33),
            finalMessages: executionMessages + [ModelMessage.assistant("done")],
            endTime: Date(),
            toolCallCount: 0,
            usage: nil,
            status: SessionStatus.completed.rawValue)

        let loaded = try #require(try await manager.loadSession(id: session.id))
        #expect(context.toolExecutionAuthority == .backgroundOnly)
        #expect(context.storedToolExecutionAuthority.basePolicy == .foregroundAllowed)
        #expect(loaded.effectiveToolExecutionPolicy == .foregroundAllowed)
        #expect(loaded.messages.first == executionMessages.first)
        #expect(try PeekabooAgentService.resolveToolExecutionAuthority(
            for: loaded,
            requested: .init(basePolicy: .foregroundAllowed)).basePolicy == .foregroundAllowed)
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

    private static func session(
        id: String, policy: MCPToolExecutionPolicy, clipboardMaximum: Bool? = nil) -> AgentSession
    {
        let now = Date()
        return AgentSession(
            id: id,
            modelName: "test-model",
            toolExecutionPolicy: policy,
            temporaryClipboardPasteMaximum: clipboardMaximum,
            messages: [.system("system"), .user("task")],
            metadata: SessionMetadata(),
            createdAt: now,
            updatedAt: now)
    }
}
