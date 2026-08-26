import CoreGraphics
import Foundation
import PeekabooFoundation

extension SnapshotManager {
    /// Store raw screenshot and build UI map
    public func storeScreenshot(_ request: SnapshotScreenshotRequest) async throws {
        guard let snapshotPath = try self.ownedSnapshotURL(for: request.snapshotId) else {
            throw SnapshotError.snapshotNotFound
        }
        try SnapshotPublicationBinding.validate(
            snapshotId: request.snapshotId,
            captureCoordinateContext: request.captureCoordinateContext)

        guard var snapshotData = await self.snapshotActor
            .loadSnapshot(snapshotId: request.snapshotId, from: snapshotPath)
        else {
            throw SnapshotError.snapshotNotFound
        }
        await self.postLoadBarrier()
        if snapshotData.creatorProcessId == nil {
            snapshotData.creatorProcessId = getpid()
        }

        let rawPath = snapshotPath.appendingPathComponent("raw.png")
        let sourceURL = URL(fileURLWithPath: request.screenshotPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CaptureError.fileIOError("Screenshot missing at \(sourceURL.path)")
        }
        if FileManager.default.fileExists(atPath: rawPath.path) {
            try FileManager.default.removeItem(at: rawPath)
        }
        let annotatedPath = snapshotPath.appendingPathComponent("annotated.png")
        if FileManager.default.fileExists(atPath: annotatedPath.path) {
            try FileManager.default.removeItem(at: annotatedPath)
        }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: rawPath)
        } catch {
            let message = "Failed to copy screenshot to snapshot storage: \(error.localizedDescription)"
            throw CaptureError.fileIOError(message)
        }

        snapshotData.screenshotPath = rawPath.path
        snapshotData.annotatedPath = nil
        snapshotData.uiMap = [:]
        snapshotData.applicationName = request.applicationName
        snapshotData.applicationBundleId = request.applicationBundleId
        snapshotData.applicationProcessId = request.applicationProcessId
        snapshotData.windowTitle = request.windowTitle
        snapshotData.windowBounds = request.windowBounds
        snapshotData.windowID = request.windowID.flatMap { CGWindowID(exactly: $0) }
        snapshotData.windowMutationIdentity = request.windowMutationIdentity
        snapshotData.focusedElement = nil
        snapshotData.captureCoordinateContext = request.captureCoordinateContext
        snapshotData.lastUpdateTime = Date()

        try await self.snapshotActor.saveSnapshot(snapshotId: request.snapshotId, data: snapshotData, at: snapshotPath)
    }

    public func storeAnnotatedScreenshot(snapshotId: String, annotatedScreenshotPath: String) async throws {
        guard let snapshotPath = try self.ownedSnapshotURL(for: snapshotId) else {
            throw SnapshotError.snapshotNotFound
        }

        guard var snapshotData = await self.snapshotActor
            .loadSnapshot(snapshotId: snapshotId, from: snapshotPath)
        else {
            throw SnapshotError.snapshotNotFound
        }
        await self.postLoadBarrier()
        if snapshotData.creatorProcessId == nil {
            snapshotData.creatorProcessId = getpid()
        }

        let annotatedPath = snapshotPath.appendingPathComponent("annotated.png")
        let sourceURL = URL(fileURLWithPath: annotatedScreenshotPath).standardizedFileURL

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CaptureError.fileIOError("Annotated screenshot missing at \(sourceURL.path)")
        }

        if FileManager.default.fileExists(atPath: annotatedPath.path) {
            try FileManager.default.removeItem(at: annotatedPath)
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: annotatedPath)
        } catch {
            let message = "Failed to copy annotated screenshot to snapshot storage: \(error.localizedDescription)"
            throw CaptureError.fileIOError(message)
        }

        snapshotData.annotatedPath = annotatedPath.path
        snapshotData.lastUpdateTime = Date()

        try await self.snapshotActor.saveSnapshot(snapshotId: snapshotId, data: snapshotData, at: snapshotPath)
    }
}
