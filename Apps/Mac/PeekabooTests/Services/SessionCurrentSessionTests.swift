import Foundation
import Testing
@testable import Peekaboo
@testable import PeekabooCore

@MainActor
struct SessionCurrentSessionTests {
    @Test
    func `menu bar session follows messages and title on the current chat`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))
        let session = store.createSession()

        store.addMessage(ConversationMessage(role: .user, content: "hello"), to: session)
        #expect(store.currentSession?.messages.last?.content == "hello")
        #expect(store.sessions.first?.messages.last?.content == "hello")

        store.updateTitle("Renamed chat", for: session)
        #expect(store.currentSession?.title == "Renamed chat")

        store.updateSummary("Talked about hello", for: session)
        #expect(store.currentSession?.summary == "Talked about hello")

        guard let current = store.currentSession,
              let last = current.messages.last
        else {
            Issue.record("The menu bar session has no message")
            return
        }
        let updated = ConversationMessage(
            id: last.id,
            role: last.role,
            content: "hello again",
            timestamp: last.timestamp,
            toolCalls: last.toolCalls)
        store.updateLastMessage(updated, in: session)
        #expect(store.currentSession?.messages.last?.content == "hello again")
    }

    @Test
    func `editing another session does not change the menu bar session`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))
        let older = store.createSession(title: "Older")
        let current = store.createSession(title: "Current")
        #expect(store.currentSession?.id == current.id)

        store.addMessage(ConversationMessage(role: .user, content: "old note"), to: older)
        store.updateTitle("Older renamed", for: older)

        #expect(store.currentSession?.id == current.id)
        #expect(store.currentSession?.title == "Current")
        #expect(store.currentSession?.messages.isEmpty == true)
        #expect(store.sessions.first { $0.id == older.id }?.title == "Older renamed")
    }
}
