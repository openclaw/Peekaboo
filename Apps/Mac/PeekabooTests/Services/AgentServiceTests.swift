import Foundation
import Testing
@testable import Peekaboo
@testable import PeekabooCore

@Suite(.tags(.services, .unit))
@MainActor
struct PeekabooAgentTests {
    let agent: PeekabooAgent
    let mockPeekabooSettings: PeekabooSettings
    let mockSessionStore: SessionStore

    init() {
        self.mockPeekabooSettings = makeTestSettings()
        // Use isolated storage for tests
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        let storageURL = testDir.appendingPathComponent("test_sessions.json")
        self.mockSessionStore = SessionStore(storageURL: storageURL)
        let services = PeekabooServices()
        services.agent = nil
        self.agent = PeekabooAgent(
            settings: self.mockPeekabooSettings,
            sessionStore: self.mockSessionStore,
            services: services)
    }

    @Test
    func `Service requires API key to execute`() async throws {
        // No API key set
        self.mockPeekabooSettings.openAIAPIKey = ""

        await #expect(throws: AgentError.serviceUnavailable) {
            try await agent.executeTask("Test task")
        }
    }

    @Test
    func `Unavailable agent service does not create a session`() async {
        self.mockPeekabooSettings.openAIAPIKey = "sk-test-key"

        // Initially no sessions
        #expect(self.mockSessionStore.sessions.isEmpty)

        await #expect(throws: AgentError.serviceUnavailable) {
            try await self.agent.executeTask("Test task")
        }

        #expect(self.mockSessionStore.sessions.isEmpty)
    }

    @Test
    func `Current session starts empty`() {
        #expect(self.agent.currentSession == nil)
        #expect(self.agent.currentSessionId == nil)
        #expect(self.mockSessionStore.currentSession == nil)
    }
}

@MainActor
private func makeUnavailableAgent() -> (PeekabooAgent, PeekabooSettings, SessionStore) {
    let settings = makeTestSettings()
    settings.openAIAPIKey = "sk-test-key"
    let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    let storageURL = testDir.appendingPathComponent("test_sessions.json")
    let sessionStore = SessionStore(storageURL: storageURL)
    let services = PeekabooServices()
    services.agent = nil
    let agent = PeekabooAgent(
        settings: settings,
        sessionStore: sessionStore,
        services: services)
    return (agent, settings, sessionStore)
}

@Suite(.tags(.services, .unit, .fast))
@MainActor
struct AgentServiceErrorTests {
    @Test
    func `Empty task fails fast when agent service is unavailable`() async {
        let (agent, _, sessionStore) = makeUnavailableAgent()

        await #expect(throws: AgentError.serviceUnavailable) {
            try await agent.executeTask("")
        }
        #expect(sessionStore.sessions.isEmpty)
    }

    @Test(arguments: [
        String(repeating: "a", count: 1000),
        String(repeating: "word ", count: 500),
        String(repeating: "This is a very long task. ", count: 100),
    ])
    func `Very long task fails fast when agent service is unavailable`(longTask: String) async {
        let (agent, _, sessionStore) = makeUnavailableAgent()

        await #expect(throws: AgentError.serviceUnavailable) {
            try await agent.executeTask(longTask)
        }
        #expect(sessionStore.sessions.isEmpty)
    }
}
