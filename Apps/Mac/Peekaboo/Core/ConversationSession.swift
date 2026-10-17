import Foundation
import Observation
import PeekabooCore

// MARK: - Session Management

/// Manages conversation sessions with automatic persistence.
///
/// Sessions are automatically saved to `~/Library/Application Support/Peekaboo/sessions.json`
/// and loaded on initialization. This class uses the modern @Observable pattern
/// for SwiftUI integration.
@Observable
@MainActor
final class SessionStore {
    var sessions: [ConversationSession] = []
    var currentSession: ConversationSession?

    private let titleGenerator = SessionTitleGenerator()

    private let storageURL: URL
    private enum SessionPersistenceBlock {
        case unreadableFile
        case saveFailed
    }

    /// Set until the original file is safe and a snapshot has been written.
    private var sessionPersistenceBlock: SessionPersistenceBlock?

    var sessionPersistenceBlocked: Bool {
        self.sessionPersistenceBlock != nil
    }

    static let sessionPersistenceBlockedNotice = """
    Chat history is not being saved. The sessions file is unreadable and could \
    not be moved aside. The next save will try again.
    """

    static let sessionSaveFailedNotice = """
    Chat history is not being saved. The last save did not finish. The next \
    save will try again.
    """

    var sessionPersistenceNotice: String? {
        switch self.sessionPersistenceBlock {
        case .unreadableFile:
            Self.sessionPersistenceBlockedNotice
        case .saveFailed:
            Self.sessionSaveFailedNotice
        case nil:
            nil
        }
    }

    init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            self.storageURL = Self.defaultStorageURL()
        }
        self.loadSessions()
    }

    private static func defaultStorageURL() -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let peekabooDirectory = baseDirectory.appendingPathComponent("Peekaboo", isDirectory: true)

        do {
            try fileManager.createDirectory(at: peekabooDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create application support directory: \(error)")
        }

        return peekabooDirectory.appendingPathComponent("sessions.json", isDirectory: false)
    }

    func createSession(title: String = "", modelName: String = "") -> ConversationSession {
        let session = ConversationSession(title: title.isEmpty ? "New Session" : title, modelName: modelName)
        self.sessions.insert(session, at: 0)
        self.currentSession = session
        Task { @MainActor in
            self.saveSessions()
        }
        return session
    }

    func addMessage(_ message: ConversationMessage, to session: ConversationSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        self.sessions[index].messages.append(message)
        self.publishCurrentSession(at: index)
        Task { @MainActor in
            self.saveSessions()
        }
    }

    func updateSummary(_ summary: String, for session: ConversationSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        self.sessions[index].summary = summary
        self.publishCurrentSession(at: index)
        Task { @MainActor in
            self.saveSessions()
        }
    }

    func updateTitle(_ title: String, for session: ConversationSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        self.sessions[index].title = title
        self.publishCurrentSession(at: index)
        Task { @MainActor in
            self.saveSessions()
        }
    }

    /// Generate AI title for session based on first user message
    func generateTitleForSession(_ session: ConversationSession) {
        // Only generate title if it's still "New Session" and has user messages
        guard session.title == "New Session",
              let firstUserMessage = session.messages.first(where: { $0.role == .user })
        else {
            return
        }

        Task { @MainActor in
            let generatedTitle = await titleGenerator.generateTitleFromFirstMessage(firstUserMessage.content)
            if generatedTitle != "New Session" {
                self.updateTitle(generatedTitle, for: session)
            }
        }
    }

    func updateLastMessage(_ message: ConversationMessage, in session: ConversationSession) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == session.id }),
              !sessions[sessionIndex].messages.isEmpty else { return }

        let lastIndex = self.sessions[sessionIndex].messages.count - 1
        self.sessions[sessionIndex].messages[lastIndex] = message
        self.publishCurrentSession(at: sessionIndex)
        Task { @MainActor in
            self.saveSessions()
        }
    }

    /// The menu bar reads `currentSession`, which is a separate copy of the struct.
    private func publishCurrentSession(at index: Int) {
        guard self.currentSession?.id == self.sessions[index].id else { return }
        self.currentSession = self.sessions[index]
    }

    func selectSession(_ session: ConversationSession) {
        self.currentSession = session
    }

    private func loadSessions() {
        guard FileManager.default.fileExists(atPath: self.storageURL.path) else { return }

        do {
            let data = try Data(contentsOf: self.storageURL)
            self.sessions = try self.decodeSessions(from: data)
        } catch let error as DecodingError {
            // Keep the bytes the decoder rejected. A later save must not replace them.
            if !self.moveUnreadableStoreAside() {
                self.sessionPersistenceBlock = .unreadableFile
            }
            print("Failed to load sessions: \(error)")
        } catch {
            self.sessionPersistenceBlock = .unreadableFile
            print("Failed to load sessions: \(error)")
        }
    }

    private func decodeSessions(from data: Data) throws -> [ConversationSession] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ConversationSession].self, from: data)
    }

    /// Tries again to protect the original file, then lets the caller save.
    private func retryPreservingUnreadableStore() {
        guard FileManager.default.fileExists(atPath: self.storageURL.path) else {
            self.sessionPersistenceBlock = nil
            return
        }
        do {
            let data = try Data(contentsOf: self.storageURL)
            let decoded = try self.decodeSessions(from: data)
            let known = Set(self.sessions.map(\.id))
            self.sessions.append(contentsOf: decoded.filter { !known.contains($0.id) })
            self.sessionPersistenceBlock = nil
        } catch is DecodingError {
            if self.moveUnreadableStoreAside() {
                self.sessionPersistenceBlock = nil
            }
        } catch {
            return
        }
    }

    private func moveUnreadableStoreAside() -> Bool {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        for attempt in 0..<100 {
            let suffix = attempt == 0 ? stamp : "\(stamp)-\(attempt)"
            let destination = self.storageURL.appendingPathExtension("unreadable-\(suffix)")
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            do {
                try FileManager.default.moveItem(at: self.storageURL, to: destination)
                return true
            } catch {
                return false
            }
        }
        return false
    }

    func saveSessions() {
        switch self.sessionPersistenceBlock {
        case .unreadableFile:
            self.retryPreservingUnreadableStore()
        case .saveFailed:
            self.sessionPersistenceBlock = nil
        case nil:
            break
        }
        guard self.sessionPersistenceBlock == nil else { return }
        do {
            try FileManager.default.createDirectory(
                at: self.storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(self.sessions)
            try data.write(to: self.storageURL, options: .atomic)
            self.sessionPersistenceBlock = nil
        } catch {
            self.sessionPersistenceBlock = .saveFailed
            print("Failed to save sessions: \(error)")
        }
    }
}
