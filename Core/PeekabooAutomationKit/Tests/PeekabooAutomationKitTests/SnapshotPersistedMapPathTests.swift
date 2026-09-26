import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct SnapshotPersistedMapPathTests {
    enum UnavailableArtifact: CaseIterable, Sendable {
        case missingPayload
        case symlinkPayload
        case directoryPayload
        case missingOwner
        case foreignOwner
        case symlinkDirectory
    }

    @Test
    func `disk manager exposes its existing map through the protocol and recording wrapper`() async throws {
        let storage = Self.temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let manager: any SnapshotManagerProtocol = SnapshotManager(snapshotStorageURL: storage)
        let snapshotId = try await manager.createSnapshot()
        let expected = storage.appendingPathComponent(snapshotId).appendingPathComponent("snapshot.json")
        let recording = SnapshotMutationRecordingManager(wrapping: manager)

        #expect(manager.getPersistedSnapshotMapPath(snapshotId: snapshotId) == expected.path)
        #expect(recording.getPersistedSnapshotMapPath(snapshotId: snapshotId) == expected.path)
        #expect(try Data(contentsOf: expected).isEmpty == false)
        #expect(SnapshotManager(snapshotStorageURL: storage)
            .getPersistedSnapshotMapPath(snapshotId: snapshotId) == expected.path)

        try await manager.cleanSnapshot(snapshotId: snapshotId)
        #expect(manager.getPersistedSnapshotMapPath(snapshotId: snapshotId) == nil)
        #expect(recording.getPersistedSnapshotMapPath(snapshotId: snapshotId) == nil)
    }

    @Test(arguments: UnavailableArtifact.allCases)
    func `disk manager never advertises missing foreign or aliased payloads`(
        artifact: UnavailableArtifact) async throws
    {
        let storage = Self.temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let manager = SnapshotManager(snapshotStorageURL: storage)
        let snapshotId = try await manager.createSnapshot()
        let directory = storage.appendingPathComponent(snapshotId)
        let payload = directory.appendingPathComponent("snapshot.json")
        let marker = directory.appendingPathComponent(SnapshotPathValidator.producerOwnerMarkerName)
        let aliasTarget = storage.appendingPathComponent("alias-target")

        switch artifact {
        case .missingPayload:
            try FileManager.default.removeItem(at: payload)
        case .symlinkPayload:
            try FileManager.default.moveItem(at: payload, to: aliasTarget)
            try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: aliasTarget)
        case .directoryPayload:
            try FileManager.default.removeItem(at: payload)
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        case .missingOwner:
            try FileManager.default.removeItem(at: marker)
        case .foreignOwner:
            try Data(SnapshotReferenceFixtures.id(99).utf8).write(to: marker, options: .atomic)
        case .symlinkDirectory:
            try FileManager.default.moveItem(at: directory, to: aliasTarget)
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: aliasTarget)
        }

        #expect(manager.getPersistedSnapshotMapPath(snapshotId: snapshotId) == nil)
    }

    @Test(arguments: ["", "../outside", "1753686072886-3831", SnapshotReferenceFixtures.id(99)])
    func `disk manager does not invent paths for invalid or absent references`(snapshotId: String) {
        let storage = Self.temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let manager = SnapshotManager(snapshotStorageURL: storage)

        #expect(manager.getPersistedSnapshotMapPath(snapshotId: snapshotId) == nil)
    }

    @Test
    func `memory snapshot remains owned and readable without a persisted map`() async throws {
        let manager: any SnapshotManagerProtocol = InMemorySnapshotManager()
        let snapshotId = try await manager.createSnapshot()
        let recording = SnapshotMutationRecordingManager(wrapping: manager)

        #expect(manager.getPersistedSnapshotMapPath(snapshotId: snapshotId) == nil)
        #expect(recording.getPersistedSnapshotMapPath(snapshotId: snapshotId) == nil)
        #expect(try await manager.ownsSnapshot(snapshotId: snapshotId))
        #expect(try await manager.getUIAutomationSnapshot(snapshotId: snapshotId) != nil)
        #expect(await manager.getMostRecentSnapshot() == snapshotId)
    }

    private static func temporaryStorage() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("peekaboo-persisted-map-\(UUID().uuidString)", isDirectory: true)
    }
}
