import Foundation
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

    func testLegacyShapedDirectChildIDsSupportDryRunAndDeletion() async throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let service = FileService(snapshotCacheDirectory: fixture.cacheRoot)

        for snapshotID in ["12345", "abc", "a..b"] {
            let snapshot = fixture.cacheRoot.appendingPathComponent(snapshotID, isDirectory: true)
            let payload = snapshot.appendingPathComponent("snapshot.json")
            let payloadContents = Data("payload-\(snapshotID)".utf8)
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: false)
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

        let outsideLink = fixture.cacheRoot.appendingPathComponent("outside-link")
        let siblingLink = fixture.cacheRoot.appendingPathComponent("sibling-link")
        let danglingLink = fixture.cacheRoot.appendingPathComponent("dangling-link")
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
                await self.assertInvalidSnapshotID(snapshotID, dryRun: dryRun, service: service)
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
        let regularFile = fixture.cacheRoot.appendingPathComponent("not-a-snapshot")
        let contents = Data("ordinary file".utf8)
        try contents.write(to: regularFile)

        for dryRun in [true, false] {
            await self.assertInvalidSnapshotID(
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
            let result = try await service.cleanSpecificSnapshot(snapshotId: "missing", dryRun: dryRun)
            XCTAssertEqual(result.snapshotsRemoved, 0)
            XCTAssertEqual(result.bytesFreed, 0)
            XCTAssertTrue(result.snapshotDetails.isEmpty)
            XCTAssertEqual(result.dryRun, dryRun)
        }
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
