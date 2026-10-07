import Foundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct SnapshotDetectionMetadataTests {
    @Test(arguments: [false, true])
    func `disk detection classification survives reopening the manager`(partial: Bool) async throws {
        let storage = Self.storage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let manager = SnapshotManager(snapshotStorageURL: storage)
        let id = try await manager.createExplicitSnapshot()
        let truncation = partial ? DetectionTruncationInfo(maxElementCountReached: true) : nil
        try await manager.storeDetectionResult(
            snapshotId: id,
            result: Self.result(id, dialog: partial, truncation: truncation))

        let reopened = SnapshotManager(snapshotStorageURL: storage)
        let loaded = try #require(try await reopened.getDetectionResult(snapshotId: id))
        #expect(loaded.metadata.isDialog == partial)
        #expect(loaded.metadata.truncationInfo == truncation)
    }

    @Test
    func `legacy version one record without classification remains readable`() async throws {
        let storage = Self.storage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let manager = SnapshotManager(snapshotStorageURL: storage)
        let id = try await manager.createExplicitSnapshot()
        let payload = try #require(manager.getPersistedSnapshotMapPath(snapshotId: id))
        let legacy = #"{"version":1,"uiMap":{},"lastUpdateTime":"2026-10-06T12:00:00Z"}"#
        try Data(legacy.utf8).write(to: URL(fileURLWithPath: payload), options: .atomic)

        let reopened = SnapshotManager(snapshotStorageURL: storage)
        let loaded = try #require(try await reopened.getDetectionResult(snapshotId: id))
        #expect(loaded.metadata.isDialog == false)
        #expect(loaded.metadata.truncationInfo == nil)
        #expect(FileManager.default.fileExists(atPath: payload))
    }

    @Test
    func `raw screenshot replacement clears prior detection classification`() async throws {
        let storage = Self.storage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let manager = SnapshotManager(snapshotStorageURL: storage)
        let id = try await manager.createExplicitSnapshot()
        try await manager.storeDetectionResult(
            snapshotId: id,
            result: Self.result(id, dialog: true, truncation: DetectionTruncationInfo(deadlineReached: true)))
        let image = storage.appendingPathComponent("replacement.png")
        try Data([1, 2, 3]).write(to: image)
        try await manager.storeScreenshot(SnapshotScreenshotRequest(
            snapshotId: id,
            screenshotPath: image.path,
            applicationBundleId: nil,
            applicationProcessId: nil,
            applicationName: nil,
            windowTitle: nil,
            windowBounds: nil))

        let loaded = try #require(try await SnapshotManager(snapshotStorageURL: storage)
            .getDetectionResult(snapshotId: id))
        #expect(loaded.metadata.isDialog == false)
        #expect(loaded.metadata.truncationInfo == nil)
    }

    private static func result(
        _ id: String,
        dialog: Bool,
        truncation: DetectionTruncationInfo?) -> ElementDetectionResult
    {
        ElementDetectionResult(
            snapshotId: id,
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 0,
                method: "AXorcist",
                isDialog: dialog,
                truncationInfo: truncation))
    }

    private static func storage() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("peekaboo-detection-metadata-\(UUID().uuidString)", isDirectory: true)
    }
}
