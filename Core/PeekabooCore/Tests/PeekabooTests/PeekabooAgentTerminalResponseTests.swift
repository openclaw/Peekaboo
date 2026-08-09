import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

struct PeekabooAgentTerminalResponseTests {
    @Test
    @MainActor
    func `Terminal response refuses an unexecuted known tool call`() throws {
        let (agentService, sessionStore) = try Self.makeAgentService()
        defer { sessionStore.cleanup() }

        let error = #expect(throws: TachikomaError.self) {
            try agentService.validateTerminalResponse(
                text: #"{"name":"inspect_ui","arguments":{"app_target":"Safari"}}"#,
                availableToolNames: ["inspect_ui", "see"])
        }

        #expect(error?.localizedDescription.contains("unexecuted tool call") == true)
    }

    @Test
    @MainActor
    func `Terminal response refuses a fenced unexecuted known tool call`() throws {
        let (agentService, sessionStore) = try Self.makeAgentService()
        defer { sessionStore.cleanup() }

        let error = #expect(throws: TachikomaError.self) {
            try agentService.validateTerminalResponse(
                text: """
                ```json
                {"name":"click","arguments":{"query":"Save"}}
                ```
                """,
                availableToolNames: ["click", "see"])
        }

        #expect(error?.localizedDescription.contains("unexecuted tool call") == true)
    }

    @Test
    @MainActor
    func `Terminal response refuses an array of unexecuted tool calls`() throws {
        let (agentService, sessionStore) = try Self.makeAgentService()
        defer { sessionStore.cleanup() }

        let error = #expect(throws: TachikomaError.self) {
            try agentService.validateTerminalResponse(
                text: #"[{"name":"click","arguments":{"query":"Save"}}]"#,
                availableToolNames: ["click", "see"])
        }

        #expect(error?.localizedDescription.contains("unexecuted tool call") == true)
    }

    @Test
    @MainActor
    func `Terminal response refuses a prefaced fenced tool call`() throws {
        let (agentService, sessionStore) = try Self.makeAgentService()
        defer { sessionStore.cleanup() }

        let error = #expect(throws: TachikomaError.self) {
            try agentService.validateTerminalResponse(
                text: """
                I will use the tool now:
                ```json
                {"name":"click","arguments":{"query":"Save"}}
                ```
                """,
                availableToolNames: ["click", "see"])
        }

        #expect(error?.localizedDescription.contains("unexecuted tool call") == true)
    }

    @Test
    @MainActor
    func `Terminal response refuses an unfenced tool call embedded in prose`() throws {
        let (agentService, sessionStore) = try Self.makeAgentService()
        defer { sessionStore.cleanup() }

        let error = #expect(throws: TachikomaError.self) {
            try agentService.validateTerminalResponse(
                text: """
                I will use the tool now:
                {"name":"click","arguments":{"query":"Save"}}
                """,
                availableToolNames: ["click", "see"])
        }

        #expect(error?.localizedDescription.contains("unexecuted tool call") == true)
    }

    @Test
    @MainActor
    func `Terminal response refuses a commented fenced tool call in a wrapper`() throws {
        let (agentService, sessionStore) = try Self.makeAgentService()
        defer { sessionStore.cleanup() }

        let error = #expect(throws: TachikomaError.self) {
            try agentService.validateTerminalResponse(
                text: """
                ```jsonc
                {
                  // Provider-specific wrapper
                  "payload": {"name":"click","arguments":{"query":"Save"}}
                }
                ```
                """,
                availableToolNames: ["click", "see"])
        }

        #expect(error?.localizedDescription.contains("unexecuted tool call") == true)
    }

    @Test
    @MainActor
    func `Terminal response permits ordinary JSON that is not an available tool call`() throws {
        let (agentService, sessionStore) = try Self.makeAgentService()
        defer { sessionStore.cleanup() }

        try agentService.validateTerminalResponse(
            text: #"{"name":"report","arguments":{"status":"complete"}}"#,
            availableToolNames: ["inspect_ui", "see"])
    }

    @MainActor
    private static func makeAgentService() throws -> (
        service: PeekabooAgentService,
        store: IsolatedAgentSessionStore)
    {
        let store = try IsolatedAgentSessionStore()
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.opus48),
            sessionManager: store.manager)
        return (service, store)
    }
}
