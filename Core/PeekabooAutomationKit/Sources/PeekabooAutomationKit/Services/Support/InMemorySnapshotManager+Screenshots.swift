import CoreGraphics
import Foundation
import PeekabooFoundation

extension InMemorySnapshotManager {
    // MARK: - Screenshot + UI map helpers

    public func storeScreenshot(_ request: SnapshotScreenshotRequest) async throws {
        self.pruneIfNeeded()
        let storedPath = try self.storedArtifactPath(
            sourcePath: request.screenshotPath,
            preferredName: "raw")

        var entry = self.entries[request.snapshotId] ?? Entry(
            createdAt: Date(),
            lastAccessedAt: Date(),
            processId: getpid(),
            isPending: false,
            detectionResult: nil,
            snapshotData: UIAutomationSnapshot(creatorProcessId: getpid()))
        if self.options.copyArtifactsOnStore {
            self.deleteManagedTemporaryArtifacts(for: entry.snapshotData)
        }

        entry.lastAccessedAt = Date()
        entry.detectionResult = nil
        entry.snapshotData.screenshotPath = storedPath
        entry.snapshotData.annotatedPath = nil
        entry.snapshotData.uiMap = [:]
        entry.snapshotData.applicationName = request.applicationName
        entry.snapshotData.applicationBundleId = request.applicationBundleId
        entry.snapshotData.applicationProcessId = request.applicationProcessId
        entry.snapshotData.windowTitle = request.windowTitle
        entry.snapshotData.windowBounds = request.windowBounds
        entry.snapshotData.windowID = request.windowID.flatMap { CGWindowID(exactly: $0) }
        entry.snapshotData.windowMutationIdentity = request.windowMutationIdentity
        entry.snapshotData.captureCoordinateContext = request.captureCoordinateContext
        entry.snapshotData.lastUpdateTime = Date()
        self.entries[request.snapshotId] = entry
        self.pruneIfNeeded()
    }

    public func storeAnnotatedScreenshot(snapshotId: String, annotatedScreenshotPath: String) async throws {
        self.pruneIfNeeded()
        let storedPath = try self.storedArtifactPath(
            sourcePath: annotatedScreenshotPath,
            preferredName: "annotated")

        var entry = self.entries[snapshotId] ?? Entry(
            createdAt: Date(),
            lastAccessedAt: Date(),
            processId: getpid(),
            isPending: false,
            detectionResult: nil,
            snapshotData: UIAutomationSnapshot(creatorProcessId: getpid()))

        entry.lastAccessedAt = Date()
        if self.options.copyArtifactsOnStore,
           let existing = entry.snapshotData.annotatedPath,
           existing != entry.snapshotData.screenshotPath
        {
            self.deleteManagedTemporaryArtifact(at: existing)
        }
        entry.snapshotData.annotatedPath = storedPath
        entry.snapshotData.lastUpdateTime = Date()
        self.entries[snapshotId] = entry
        self.pruneIfNeeded()
    }

    public func getElement(snapshotId: String, elementId: String) async throws -> UIElement? {
        guard var entry = self.entries[snapshotId] else {
            throw SnapshotError.snapshotNotFound
        }
        entry.lastAccessedAt = Date()
        self.entries[snapshotId] = entry
        return entry.snapshotData.uiMap[elementId]
    }

    public func findElements(snapshotId: String, matching query: String) async throws -> [UIElement] {
        guard var entry = self.entries[snapshotId] else {
            throw SnapshotError.snapshotNotFound
        }
        entry.lastAccessedAt = Date()
        self.entries[snapshotId] = entry

        let lowercaseQuery = query.lowercased()
        return entry.snapshotData.uiMap.values.filter { element in
            let searchableText = [
                element.title,
                element.label,
                element.value,
                element.role,
            ].compactMap(\.self).joined(separator: " ").lowercased()

            return searchableText.contains(lowercaseQuery)
        }.sorted { lhs, rhs in
            if abs(lhs.frame.origin.y - rhs.frame.origin.y) < 10 {
                return lhs.frame.origin.x < rhs.frame.origin.x
            }
            return lhs.frame.origin.y < rhs.frame.origin.y
        }
    }

    public func getUIAutomationSnapshot(snapshotId: String) async throws -> UIAutomationSnapshot? {
        guard var entry = self.entries[snapshotId] else { return nil }
        entry.lastAccessedAt = Date()
        self.entries[snapshotId] = entry
        return entry.snapshotData
    }

    private func storedArtifactPath(sourcePath: String, preferredName: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        guard self.options.copyArtifactsOnStore else { return sourceURL.path }
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CaptureError.fileIOError("Snapshot artifact is not a regular file: \(sourceURL.path)")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-see", isDirectory: true)
            .appendingPathComponent("host-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pathExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let destinationURL = directory
            .appendingPathComponent(preferredName, isDirectory: false)
            .appendingPathExtension(pathExtension)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL.path
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw CaptureError.fileIOError("Failed to copy snapshot artifact: \(error.localizedDescription)")
        }
    }
}
