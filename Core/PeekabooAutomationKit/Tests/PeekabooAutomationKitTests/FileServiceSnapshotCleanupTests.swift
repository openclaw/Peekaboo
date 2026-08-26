import Foundation
import PeekabooFoundation
import PeekabooFoundationTestSupport
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class FileServiceSnapshotCleanupTests: XCTestCase {
    func testInvalidSnapshotIDsAreRejectedBeforeDryRunOrDeletion() async throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let service = FileService(snapshotCacheDirectory: fixture.cacheRoot)
        let invalidIDs = [
            "",
            ".",
            "..",
            "../outside",
            "nested/child",
            "nested/../outside",
            fixture.outside.path,
            "nul\0byte",
            "line\nbreak",
            "12345",
        ]

        for snapshotID in invalidIDs {
            for dryRun in [true, false] {
                await self.assertInvalidSnapshotID(snapshotID, dryRun: dryRun, service: service)
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cacheRoot.path))
                XCTAssertEqual(try Data(contentsOf: fixture.rootSentinel), fixture.rootSentinelContents)
                XCTAssertEqual(try Data(contentsOf: fixture.outsideSentinel), fixture.outsideSentinelContents)
            }
        }
    }

    func testProducerOwnedCanonicalIDsSupportDryRunAndDeletion() async throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let service = FileService(snapshotCacheDirectory: fixture.cacheRoot)

        for snapshotID in [
            SnapshotReferenceFixtures.id(1),
            SnapshotReferenceFixtures.id(2),
            SnapshotReferenceFixtures.id(3),
        ] {
            let manager = SnapshotManager(
                snapshotStorageURL: fixture.cacheRoot,
                snapshotReferenceGenerator: { SnapshotReference(rawValue: snapshotID)! })
            let createdSnapshotID = try await manager.createSnapshot()
            XCTAssertEqual(createdSnapshotID, snapshotID)
            let snapshot = fixture.cacheRoot.appendingPathComponent(snapshotID, isDirectory: true)
            let payload = snapshot.appendingPathComponent("snapshot.json")
            let payloadContents = Data("payload-\(snapshotID)".utf8)
            try payloadContents.write(to: payload)

            let preview = try await service.cleanSpecificSnapshot(snapshotId: snapshotID, dryRun: true)
            XCTAssertEqual(preview.snapshotsRemoved, 1)
            XCTAssertEqual(preview.snapshotDetails.map(\.snapshotId), [snapshotID])
            XCTAssertEqual(preview.snapshotDetails.map(\.path), [snapshot.path])
            XCTAssertEqual(preview.bytesFreed, Int64(payloadContents.count))
            XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))

            let cleaned = try await service.cleanSpecificSnapshot(snapshotId: snapshotID, dryRun: false)
            XCTAssertEqual(cleaned.snapshotsRemoved, 1)
            XCTAssertEqual(cleaned.snapshotDetails.map(\.snapshotId), [snapshotID])
            XCTAssertEqual(cleaned.bytesFreed, Int64(payloadContents.count))
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
            XCTAssertEqual(try Data(contentsOf: fixture.outsideSentinel), fixture.outsideSentinelContents)
        }
    }

    func testTerminalSymlinksAreRejectedWithoutTouchingTargets() async throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let service = FileService(snapshotCacheDirectory: fixture.cacheRoot)

        let sibling = fixture.cacheRoot.appendingPathComponent("sibling", isDirectory: true)
        let siblingSentinel = sibling.appendingPathComponent("snapshot.json")
        let siblingContents = Data("sibling".utf8)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        try siblingContents.write(to: siblingSentinel)

        let outsideLink = fixture.cacheRoot.appendingPathComponent(SnapshotReferenceFixtures.id(11))
        let siblingLink = fixture.cacheRoot.appendingPathComponent(SnapshotReferenceFixtures.id(12))
        let danglingLink = fixture.cacheRoot.appendingPathComponent(SnapshotReferenceFixtures.id(13))
        let missingTarget = fixture.container.appendingPathComponent("missing-target", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: outsideLink, withDestinationURL: fixture.outside)
        try FileManager.default.createSymbolicLink(at: siblingLink, withDestinationURL: sibling)
        try FileManager.default.createSymbolicLink(at: danglingLink, withDestinationURL: missingTarget)

        for snapshotID in [
            outsideLink.lastPathComponent,
            siblingLink.lastPathComponent,
            danglingLink.lastPathComponent,
        ] {
            for dryRun in [true, false] {
                try await self.assertUnownedSnapshotIgnored(snapshotID, dryRun: dryRun, service: service)
                XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(
                    atPath: fixture.cacheRoot.appendingPathComponent(snapshotID).path))
                XCTAssertEqual(try Data(contentsOf: fixture.outsideSentinel), fixture.outsideSentinelContents)
                XCTAssertEqual(try Data(contentsOf: siblingSentinel), siblingContents)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
    }

    func testDirectChildRegularFileIsRejectedWithoutDeletion() async throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let service = FileService(snapshotCacheDirectory: fixture.cacheRoot)
        let regularFile = fixture.cacheRoot.appendingPathComponent(SnapshotReferenceFixtures.id(21))
        let contents = Data("ordinary file".utf8)
        try contents.write(to: regularFile)

        for dryRun in [true, false] {
            try await self.assertUnownedSnapshotIgnored(
                regularFile.lastPathComponent,
                dryRun: dryRun,
                service: service)
            XCTAssertEqual(try Data(contentsOf: regularFile), contents)
        }
    }

    func testMissingValidSnapshotIDReturnsEmptyResult() async throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let service = FileService(snapshotCacheDirectory: fixture.cacheRoot)

        for dryRun in [true, false] {
            let result = try await service.cleanSpecificSnapshot(
                snapshotId: SnapshotReferenceFixtures.id(99),
                dryRun: dryRun)
            XCTAssertEqual(result.snapshotsRemoved, 0)
            XCTAssertEqual(result.bytesFreed, 0)
            XCTAssertTrue(result.snapshotDetails.isEmpty)
            XCTAssertEqual(result.dryRun, dryRun)
        }
    }

    func testListExposesOnlyCanonicalProducerOwnedSnapshots() async throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let service = FileService(snapshotCacheDirectory: fixture.cacheRoot)
        let manager = SnapshotManager(
            snapshotStorageURL: fixture.cacheRoot,
            snapshotReferenceGenerator: { SnapshotReferenceFixtures.first })
        let owned = try await manager.createSnapshot()

        for snapshotID in ["1787675983803-1514", SnapshotReferenceFixtures.id(88)] {
            let directory = fixture.cacheRoot.appendingPathComponent(snapshotID, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("{}".utf8).write(to: directory.appendingPathComponent("snapshot.json"))
        }
        let symlink = fixture.cacheRoot.appendingPathComponent(SnapshotReferenceFixtures.id(89))
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.outside)
        let markerSymlinkID = SnapshotReferenceFixtures.id(90)
        let markerSymlinkDirectory = fixture.cacheRoot.appendingPathComponent(markerSymlinkID, isDirectory: true)
        try FileManager.default.createDirectory(at: markerSymlinkDirectory, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: markerSymlinkDirectory.appendingPathComponent("snapshot.json"))
        let outsideMarker = fixture.outside.appendingPathComponent("owner-marker")
        try Data(markerSymlinkID.utf8).write(to: outsideMarker)
        try FileManager.default.createSymbolicLink(
            at: markerSymlinkDirectory.appendingPathComponent(SnapshotPathValidator.producerOwnerMarkerName),
            withDestinationURL: outsideMarker)

        let listed = try await service.listSnapshots()

        XCTAssertEqual(listed.map(\.snapshotId), [owned])
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerSymlinkDirectory.path))
    }

    func testLegacyTimestampSnapshotsRemainCleanupOnly() async throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let service = FileService(snapshotCacheDirectory: fixture.cacheRoot)
        let legacyID = "1787675983803-1514"
        let legacyURL = fixture.cacheRoot.appendingPathComponent(legacyID, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: false)
        try Data("legacy".utf8).write(to: legacyURL.appendingPathComponent("snapshot.json"))

        let listed = try await service.listSnapshots()
        XCTAssertTrue(listed.isEmpty)
        let preview = try await service.cleanSpecificSnapshot(snapshotId: legacyID, dryRun: true)
        XCTAssertEqual(preview.snapshotDetails.map(\.snapshotId), [legacyID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))

        let result = try await service.cleanSpecificSnapshot(snapshotId: legacyID, dryRun: false)
        XCTAssertEqual(result.snapshotsRemoved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testLegacyPendingSnapshotDirectoriesRemainCleanupOnly() async throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let service = FileService(snapshotCacheDirectory: fixture.cacheRoot)
        let legacyPendingID = ".pending-\(UUID().uuidString)"
        let legacyPendingURL = fixture.cacheRoot.appendingPathComponent(legacyPendingID, isDirectory: true)
        let malformedPendingURL = fixture.cacheRoot.appendingPathComponent(".pending-abandoned", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyPendingURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: malformedPendingURL, withIntermediateDirectories: false)
        try Data("legacy pending artifact".utf8).write(to: legacyPendingURL.appendingPathComponent("raw.png"))

        let listed = try await service.listSnapshots()
        XCTAssertTrue(listed.isEmpty)
        let preview = try await service.cleanAllSnapshots(dryRun: true)
        XCTAssertEqual(preview.snapshotDetails.map(\.snapshotId), [legacyPendingID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPendingURL.path))

        let cleaned = try await service.cleanAllSnapshots(dryRun: false)
        XCTAssertEqual(cleaned.snapshotDetails.map(\.snapshotId), [legacyPendingID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformedPendingURL.path))
    }

    func testCleanAllAndAgeCleanupRemoveOnlyOwnedOrLegacySnapshotDirectories() async throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let service = FileService(snapshotCacheDirectory: fixture.cacheRoot)
        let manager = SnapshotManager(
            snapshotStorageURL: fixture.cacheRoot,
            snapshotReferenceGenerator: { SnapshotReferenceFixtures.first })
        let owned = try await manager.createSnapshot()
        let legacyID = "1787675983803-1514"
        let legacyURL = fixture.cacheRoot.appendingPathComponent(legacyID, isDirectory: true)
        let unownedURL = fixture.cacheRoot.appendingPathComponent(SnapshotReferenceFixtures.id(88), isDirectory: true)
        for directory in [legacyURL, unownedURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("{}".utf8).write(to: directory.appendingPathComponent("snapshot.json"))
        }
        let oldDate = Date().addingTimeInterval(-48 * 3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: legacyURL.path)

        let aged = try await service.cleanOldSnapshots(hours: 24, dryRun: false)
        XCTAssertEqual(aged.snapshotDetails.map(\.snapshotId), [legacyID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unownedURL.path))

        let all = try await service.cleanAllSnapshots(dryRun: false)
        XCTAssertEqual(all.snapshotDetails.map(\.snapshotId), [owned])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheRoot.appendingPathComponent(owned).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unownedURL.path))
    }

    func testLegacyShapeWithoutRegularSnapshotPayloadIsNeverListedOrRemoved() async throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let service = FileService(snapshotCacheDirectory: fixture.cacheRoot)
        let missingPayload = fixture.cacheRoot.appendingPathComponent("1787675983803-1514", isDirectory: true)
        let directoryPayload = fixture.cacheRoot.appendingPathComponent("1787675983803-1515", isDirectory: true)
        let symlinkPayload = fixture.cacheRoot.appendingPathComponent("1787675983803-1516", isDirectory: true)
        for directory in [missingPayload, directoryPayload, symlinkPayload] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try FileManager.default.createDirectory(
            at: directoryPayload.appendingPathComponent("snapshot.json", isDirectory: true),
            withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: symlinkPayload.appendingPathComponent("snapshot.json"),
            withDestinationURL: fixture.outsideSentinel)

        let listed = try await service.listSnapshots()
        XCTAssertTrue(listed.isEmpty)
        let cleaned = try await service.cleanAllSnapshots(dryRun: false)
        XCTAssertEqual(cleaned.snapshotsRemoved, 0)
        for directory in [missingPayload, directoryPayload, symlinkPayload] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.outsideSentinel), fixture.outsideSentinelContents)
    }

    private func assertInvalidSnapshotID(
        _ snapshotID: String,
        dryRun: Bool,
        service: FileService) async
    {
        do {
            _ = try await service.cleanSpecificSnapshot(snapshotId: snapshotID, dryRun: dryRun)
            XCTFail("Expected invalid snapshot ID")
        } catch FileServiceError.invalidSnapshotID {
            // Expected.
        } catch {
            XCTFail("Expected FileServiceError.invalidSnapshotID, got \(error)")
        }
    }

    private func assertUnownedSnapshotIgnored(
        _ snapshotID: String,
        dryRun: Bool,
        service: FileService) async throws
    {
        let result = try await service.cleanSpecificSnapshot(snapshotId: snapshotID, dryRun: dryRun)
        XCTAssertEqual(result.snapshotsRemoved, 0)
        XCTAssertEqual(result.bytesFreed, 0)
        XCTAssertTrue(result.snapshotDetails.isEmpty)
    }

    private func makeFixture() throws -> Fixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-file-clean-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = container.appendingPathComponent("snapshots", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        let rootSentinel = cacheRoot.appendingPathComponent("root-sentinel")
        let outsideSentinel = outside.appendingPathComponent("outside-sentinel")
        let rootSentinelContents = Data("cache root".utf8)
        let outsideSentinelContents = Data("outside target".utf8)

        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try rootSentinelContents.write(to: rootSentinel)
        try outsideSentinelContents.write(to: outsideSentinel)

        return Fixture(
            container: container,
            cacheRoot: cacheRoot,
            outside: outside,
            rootSentinel: rootSentinel,
            outsideSentinel: outsideSentinel,
            rootSentinelContents: rootSentinelContents,
            outsideSentinelContents: outsideSentinelContents)
    }
}

private struct Fixture {
    let container: URL
    let cacheRoot: URL
    let outside: URL
    let rootSentinel: URL
    let outsideSentinel: URL
    let rootSentinelContents: Data
    let outsideSentinelContents: Data
}
