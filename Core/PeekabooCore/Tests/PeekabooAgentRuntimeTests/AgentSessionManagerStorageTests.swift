import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime

@Suite("Agent session persistence", .serialized)
struct AgentSessionManagerStorageTests {
    @Test
    @MainActor
    func `Session operations reject traversal IDs without touching outside files`() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        let manager = try AgentSessionManager(sessionDirectory: sessionDirectory)
        let outsideFile = root.appendingPathComponent("outside.json")
        let sentinel = Data("outside-session-data".utf8)
        try sentinel.write(to: outsideFile)

        #expect(throws: AgentSessionManagerError.self) {
            try manager.saveSession(Self.session(id: "../outside"))
        }
        #expect(try Data(contentsOf: outsideFile) == sentinel)

        await #expect(throws: AgentSessionManagerError.self) {
            _ = try await manager.loadSession(id: "../outside")
        }
        #expect(try Data(contentsOf: outsideFile) == sentinel)

        await #expect(throws: AgentSessionManagerError.self) {
            try await manager.deleteSession(id: "../outside")
        }
        #expect(try Data(contentsOf: outsideFile) == sentinel)
    }

    @Test
    @MainActor
    func `Session IDs cannot contain path separators or ambiguous path components`() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = try AgentSessionManager(sessionDirectory: root)
        let unsafeIDs = ["", ".", "..", "nested/session", "nested\\session", "/tmp/session"]

        for id in unsafeIDs {
            #expect(throws: AgentSessionManagerError.self) {
                try manager.saveSession(Self.session(id: id))
            }
        }
        #expect(manager.listSessions().isEmpty)
    }

    @Test
    @MainActor
    func `Stored session identity must match its contained file`() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let encoded = try JSONEncoder().encode(Self.session(id: "../outside"))
        try encoded.write(to: root.appendingPathComponent("safe.json"))
        let manager = try AgentSessionManager(sessionDirectory: root)

        await #expect(throws: AgentSessionManagerError.self) {
            _ = try await manager.loadSession(id: "safe")
        }
        #expect(manager.listSessions().isEmpty)
    }

    @Test
    @MainActor
    func `Saving a session atomically replaces its previous snapshot`() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = try AgentSessionManager(sessionDirectory: root)
        try manager.saveSession(Self.session(id: "replace-me", totalTokens: 10))
        try manager.saveSession(Self.session(id: "replace-me", totalTokens: 25))

        let freshManager = try AgentSessionManager(sessionDirectory: root)
        let loaded = try #require(try await freshManager.loadSession(id: "replace-me"))
        #expect(loaded.metadata.totalTokens == 25)

        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(files.map(\.lastPathComponent) == ["replace-me.json"])
    }

    @Test
    @MainActor
    func `Session summaries reflect persisted lifecycle status`() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = try AgentSessionManager(sessionDirectory: root)
        try manager.saveSession(Self.session(id: "active", status: "active"))
        try manager.saveSession(Self.session(id: "completed", status: "completed"))
        try manager.saveSession(Self.session(id: "failed", status: "failed"))
        try manager.saveSession(Self.session(id: "cancelled", status: "cancelled"))
        try manager.saveSession(Self.session(id: "resumable", status: "max_steps_exhausted"))

        let statuses = Dictionary(uniqueKeysWithValues: manager.listSessions().map { ($0.id, $0.status) })
        #expect(statuses["active"] == .active)
        #expect(statuses["completed"] == .completed)
        #expect(statuses["failed"] == .failed)
        #expect(statuses["cancelled"] == .failed)
        #expect(statuses["resumable"] == .active)
    }

    @Test
    @MainActor
    func `Session summaries preserve persisted timestamps across atomic saves`() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = try AgentSessionManager(sessionDirectory: root)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let firstUpdatedAt = createdAt.addingTimeInterval(60)
        let secondUpdatedAt = createdAt.addingTimeInterval(120)
        try manager.saveSession(Self.session(
            id: "timestamped",
            createdAt: createdAt,
            updatedAt: firstUpdatedAt))

        var summary = try #require(manager.listSessions().first { $0.id == "timestamped" })
        #expect(summary.createdAt == createdAt)
        #expect(summary.lastAccessedAt == firstUpdatedAt)

        try manager.saveSession(Self.session(
            id: "timestamped",
            totalTokens: 25,
            createdAt: createdAt,
            updatedAt: secondUpdatedAt))

        summary = try #require(manager.listSessions().first { $0.id == "timestamped" })
        #expect(summary.createdAt == createdAt)
        #expect(summary.lastAccessedAt == secondUpdatedAt)
    }

    @Test
    @MainActor
    func `Session summary expiry and order use persisted update time`() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = try AgentSessionManager(sessionDirectory: root)
        let now = Date()
        let expiredAt = now.addingTimeInterval(-AgentSessionManager.maxSessionAge - 60)
        try manager.saveSession(Self.session(
            id: "newer",
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now.addingTimeInterval(-60)))
        try manager.saveSession(Self.session(
            id: "expired",
            createdAt: expiredAt.addingTimeInterval(-60),
            updatedAt: expiredAt))

        let summaries = manager.listSessions()
        #expect(summaries.map(\.id) == ["newer", "expired"])
        #expect(summaries.first { $0.id == "expired" }?.status == .expired)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionManagerStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func session(
        id: String,
        status: String? = nil,
        totalTokens: Int = 0,
        createdAt: Date? = nil,
        updatedAt: Date? = nil) -> AgentSession
    {
        let now = Date()
        let customData = status.map { ["status": $0] } ?? [:]
        return AgentSession(
            id: id,
            modelName: "test-model",
            messages: [.user("Test session")],
            metadata: SessionMetadata(totalTokens: totalTokens, customData: customData),
            createdAt: createdAt ?? now,
            updatedAt: updatedAt ?? now)
    }
}
