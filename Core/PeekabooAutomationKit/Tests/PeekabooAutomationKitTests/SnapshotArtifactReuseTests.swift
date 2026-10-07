import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct SnapshotArtifactReuseTests {
    @Test
    func `raw screenshot can be stored again from its managed artifact`() async throws {
        let storage = Self.temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let manager = SnapshotManager(snapshotStorageURL: storage)
        let snapshotId = try await manager.createSnapshot()
        let source = storage.appendingPathComponent("source.png")
        let png = try CapturePNGTestFixtures.pngData(image: CapturePNGTestFixtures.makeImage(width: 2, height: 2))
        try png.write(to: source)
        try await manager.storeScreenshot(Self.request(snapshotId: snapshotId, path: source.path))
        let before = try #require(try await manager.getUIAutomationSnapshot(snapshotId: snapshotId))
        let managedPath = try #require(before.screenshotPath)

        try await manager.storeScreenshot(Self.request(snapshotId: snapshotId, path: managedPath))

        #expect(try Data(contentsOf: URL(fileURLWithPath: managedPath)) == png)
        let after = try #require(try await manager.getUIAutomationSnapshot(snapshotId: snapshotId))
        #expect(after.screenshotPath == managedPath)
    }

    @Test
    func `annotation can be stored again from its managed artifact`() async throws {
        let storage = Self.temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let manager = SnapshotManager(snapshotStorageURL: storage)
        let snapshotId = try await manager.createSnapshot()
        let source = storage.appendingPathComponent("source.png")
        let png = try CapturePNGTestFixtures.pngData(image: CapturePNGTestFixtures.makeImage(width: 2, height: 2))
        try png.write(to: source)
        try await manager.storeAnnotatedScreenshot(snapshotId: snapshotId, annotatedScreenshotPath: source.path)
        let before = try #require(try await manager.getUIAutomationSnapshot(snapshotId: snapshotId))
        let managedPath = try #require(before.annotatedPath)

        try await manager.storeAnnotatedScreenshot(snapshotId: snapshotId, annotatedScreenshotPath: managedPath)

        #expect(try Data(contentsOf: URL(fileURLWithPath: managedPath)) == png)
        let after = try #require(try await manager.getUIAutomationSnapshot(snapshotId: snapshotId))
        #expect(after.annotatedPath == managedPath)
    }

    @Test
    func `managed annotation can become the new raw screenshot`() async throws {
        let storage = Self.temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let manager = SnapshotManager(snapshotStorageURL: storage)
        let snapshotId = try await manager.createSnapshot()
        let source = storage.appendingPathComponent("source.png")
        let png = try CapturePNGTestFixtures.pngData(image: CapturePNGTestFixtures.makeImage(width: 2, height: 2))
        try png.write(to: source)
        try await manager.storeAnnotatedScreenshot(snapshotId: snapshotId, annotatedScreenshotPath: source.path)
        let before = try #require(try await manager.getUIAutomationSnapshot(snapshotId: snapshotId))
        let annotation = try #require(before.annotatedPath)

        try await manager.storeScreenshot(Self.request(snapshotId: snapshotId, path: annotation))

        let after = try #require(try await manager.getUIAutomationSnapshot(snapshotId: snapshotId))
        let rawPath = try #require(after.screenshotPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: rawPath)) == png)
        #expect(after.annotatedPath == nil)
        #expect(!FileManager.default.fileExists(atPath: annotation))
    }

    @Test(arguments: [false, true])
    func `failed copy preserves the last complete artifact`(annotation: Bool) async throws {
        guard getuid() != 0 else { return } // Native mode-bit denial requires a non-root caller.
        let storage = Self.temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let manager = SnapshotManager(snapshotStorageURL: storage)
        let snapshotId = try await manager.createSnapshot()
        let source = storage.appendingPathComponent("source.png")
        let png = try CapturePNGTestFixtures.pngData(image: CapturePNGTestFixtures.makeImage(width: 2, height: 2))
        try png.write(to: source)
        try await manager.storeScreenshot(Self.request(snapshotId: snapshotId, path: source.path))
        try await manager.storeAnnotatedScreenshot(snapshotId: snapshotId, annotatedScreenshotPath: source.path)
        let before = try #require(try await manager.getUIAutomationSnapshot(snapshotId: snapshotId))
        let rawPath = try #require(before.screenshotPath)
        let annotationPath = try #require(before.annotatedPath)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path) }

        await #expect(throws: CaptureError.self) {
            if annotation {
                try await manager.storeAnnotatedScreenshot(snapshotId: snapshotId, annotatedScreenshotPath: source.path)
            } else {
                try await manager.storeScreenshot(Self.request(snapshotId: snapshotId, path: source.path))
            }
        }

        #expect(try Data(contentsOf: URL(fileURLWithPath: rawPath)) == png)
        #expect(try Data(contentsOf: URL(fileURLWithPath: annotationPath)) == png)
        let after = try #require(try await manager.getUIAutomationSnapshot(snapshotId: snapshotId))
        #expect(after.screenshotPath == before.screenshotPath)
        #expect(after.annotatedPath == before.annotatedPath)
    }

    private static func request(snapshotId: String, path: String) -> SnapshotScreenshotRequest {
        SnapshotScreenshotRequest(
            snapshotId: snapshotId,
            screenshotPath: path,
            applicationBundleId: nil,
            applicationProcessId: nil,
            applicationName: "Owned artifact fixture",
            windowTitle: nil,
            windowBounds: nil)
    }

    private static func temporaryStorage() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("peekaboo-artifact-reuse-\(UUID().uuidString)", isDirectory: true)
    }
}
