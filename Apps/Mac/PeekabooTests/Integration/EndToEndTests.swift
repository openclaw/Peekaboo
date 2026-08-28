import Foundation
import Testing
@testable import Peekaboo
@testable import PeekabooCore

@Suite(.tags(.integration, .slow))
@MainActor
struct EndToEndTests {
    var settings: PeekabooSettings!
    var sessionStore: SessionStore!
    var agent: PeekabooAgent!

    mutating func setup(installAgent: Bool = false) throws -> Bool {
        let services = PeekabooServices()
        if !installAgent {
            services.agent = nil
        }
        self.settings = makeTestSettings()
        self.settings.connectServices(services)
        self.sessionStore = SessionStore(storageURL: Self.makeTemporarySessionURL())
        self.agent = PeekabooAgent(settings: self.settings, sessionStore: self.sessionStore, services: services)
        return services.agent != nil
    }

    @Test(.enabled(if: Test.runsLiveAgentTests))
    mutating func `Full agent execution flow`() async throws {
        let liveAgentAvailable = try self.setup(installAgent: true)
        try #require(liveAgentAvailable, "Live agent test is enabled, but no configured agent service is available")

        // Execute a simple task
        _ = try await self.agent.executeTask("What time is it?")

        // Verify session was created
        let sessions = self.sessionStore.sessions
        #expect(sessions.count >= 1)

        if let session = sessions.first {
            #expect(!session.messages.isEmpty)
            #expect(session.messages.first?.role == .user)
        }
    }

    private static func makeTemporarySessionURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sessions.json")
    }
}

@Suite(.tags(.unit, .fast))
@MainActor
struct ErrorRecoveryTests {
    var settings: PeekabooSettings!
    var sessionStore: SessionStore!
    var agent: PeekabooAgent!

    mutating func setup() throws {
        let services = PeekabooServices()
        services.agent = nil
        self.settings = makeTestSettings()
        self.settings.connectServices(services)
        self.sessionStore = SessionStore(storageURL: Self.makeTemporarySessionURL())
        self.agent = PeekabooAgent(settings: self.settings, sessionStore: self.sessionStore, services: services)
    }

    @Test
    mutating func `Agent handles invalid API key gracefully`() async throws {
        try self.setup()

        await #expect(throws: AgentError.serviceUnavailable) {
            try await agent.executeTask("Test task")
        }
    }

    @Test
    mutating func `Session service handles corrupt data`() throws {
        try self.setup()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("sessions.json")

        // Create a session service and add a session
        let store1 = SessionStore(storageURL: path)
        let session = store1.createSession(title: "Test", modelName: "test")
        store1.addMessage(
            ConversationMessage(role: .user, content: "Test"),
            to: session)

        // Verify it works normally
        #expect(store1.sessions.count == 1)

        // Simulate corrupt data
        try "{ invalid json }".write(to: path, atomically: true, encoding: .utf8)

        // Create new instance - should handle corrupt data gracefully
        let store2 = SessionStore(storageURL: path)

        // Should have no sessions and not crash
        #expect(store2.sessions.isEmpty)

        try? FileManager.default.removeItem(at: dir)
    }

    private static func makeTemporarySessionURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sessions.json")
    }
}

@Suite(.tags(.unit, .fast))
@MainActor
struct ConcurrencyTests {
    var settings: PeekabooSettings!
    var sessionStore: SessionStore!
    var agent: PeekabooAgent!

    mutating func setup() throws {
        let services = PeekabooServices()
        services.agent = nil
        self.settings = makeTestSettings()
        self.settings.connectServices(services)
        self.sessionStore = SessionStore(storageURL: Self.makeTemporarySessionURL())
        self.agent = PeekabooAgent(settings: self.settings, sessionStore: self.sessionStore, services: services)
    }

    @Test
    mutating func `Multiple simultaneous agent executions`() async throws {
        try self.setup()

        func failsWithUnavailableService(_ task: String) async -> Bool {
            do {
                try await self.agent.executeTask(task)
                return false
            } catch AgentError.serviceUnavailable {
                return true
            } catch {
                return false
            }
        }

        async let result1 = failsWithUnavailableService("Task 1")
        async let result2 = failsWithUnavailableService("Task 2")
        async let result3 = failsWithUnavailableService("Task 3")

        let results = await [result1, result2, result3]
        #expect(results.allSatisfy { value in value })
    }

    @Test
    mutating func `Session service thread safety`() async throws {
        try self.setup()
        let store = try #require(self.sessionStore)
        // Create sessions from multiple tasks
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let session = await store.createSession(title: "Session \(i)", modelName: "test")
                    await store.addMessage(
                        ConversationMessage(
                            role: .user,
                            content: "Message \(i)"),
                        to: session)
                }
            }
        }

        // Should have created 10 sessions
        let sessions = self.sessionStore.sessions
        #expect(sessions.count == 10)

        // Each should have one message
        for session in sessions {
            #expect(session.messages.count == 1)
        }
    }

    private static func makeTemporarySessionURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sessions.json")
    }
}
