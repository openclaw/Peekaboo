import CoreGraphics
import Foundation
import PeekabooFoundation

extension InMemorySnapshotManager {
    // MARK: - Screenshot + UI map helpers

    public func storeScreenshot(_ request: SnapshotScreenshotRequest) async throws {
        self.pruneIfNeeded()
        var entry = try self.requireEntry(for: request.snapshotId)
        try SnapshotPublicationBinding.validate(
            snapshotId: request.snapshotId,
            captureCoordinateContext: request.captureCoordinateContext)
        let storedPath = try self.storedArtifactPath(
            sourcePath: request.screenshotPath,
            preferredName: "raw")

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
        entry.snapshotData.focusedElement = nil
        entry.snapshotData.captureCoordinateContext = request.captureCoordinateContext
        entry.snapshotData.lastUpdateTime = Date()
        self.entries[request.snapshotId] = entry
        self.pruneIfNeeded()
    }

    public func storeObservationSnapshot(_ request: SnapshotObservationPublicationRequest) async throws {
        var entry = try self.requireEntry(for: request.screenshot.snapshotId)
        try SnapshotPublicationBinding.validate(
            snapshotId: request.screenshot.snapshotId,
            detectionResult: request.detectionResult,
            captureCoordinateContext: request.screenshot.captureCoordinateContext)
        let storedRawPath = try self.storedArtifactPath(
            sourcePath: request.screenshot.screenshotPath,
            preferredName: "raw")
        var storedAnnotatedPath: String?
        do {
            if let annotatedScreenshotPath = request.annotatedScreenshotPath {
                storedAnnotatedPath = try self.storedArtifactPath(
                    sourcePath: annotatedScreenshotPath,
                    preferredName: "annotated")
            }
        } catch {
            self.deleteManagedTemporaryArtifact(at: storedRawPath)
            throw error
        }

        // Pending visibility belongs to the outer mutation coordinator. Ordinary reservations are already visible;
        // web-focus observations must stay pending until their mutation and preservation boundary is published.
        let previousSnapshotData = entry.snapshotData
        entry.lastAccessedAt = Date()
        entry.snapshotData.screenshotPath = storedRawPath
        entry.snapshotData.annotatedPath = storedAnnotatedPath
        entry.snapshotData.uiMap = [:]
        entry.snapshotData.applicationName = request.screenshot.applicationName
        entry.snapshotData.applicationBundleId = request.screenshot.applicationBundleId
        entry.snapshotData.applicationProcessId = request.screenshot.applicationProcessId
        entry.snapshotData.windowTitle = request.screenshot.windowTitle
        entry.snapshotData.windowBounds = request.screenshot.windowBounds
        entry.snapshotData.windowID = request.screenshot.windowID.flatMap { CGWindowID(exactly: $0) }
        entry.snapshotData.windowMutationIdentity = request.screenshot.windowMutationIdentity
        entry.snapshotData.focusedElement = nil
        entry.snapshotData.captureCoordinateContext = request.screenshot.captureCoordinateContext
        entry.snapshotData.lastUpdateTime = Date()
        if let detectionResult = request.detectionResult {
            self.applyDetectionResult(detectionResult, to: &entry.snapshotData)
            entry.detectionResult = ElementDetectionResult(
                snapshotId: detectionResult.snapshotId,
                screenshotPath: storedRawPath,
                elements: detectionResult.elements,
                metadata: detectionResult.metadata.withCaptureCoordinateContext(
                    entry.snapshotData.captureCoordinateContext))
        } else {
            entry.detectionResult = nil
        }

        self.entries[request.screenshot.snapshotId] = entry
        if self.options.copyArtifactsOnStore {
            self.deleteManagedTemporaryArtifacts(for: previousSnapshotData)
        }
        self.pruneIfNeeded()
    }

    public func storeAnnotatedScreenshot(snapshotId: String, annotatedScreenshotPath: String) async throws {
        self.pruneIfNeeded()
        var entry = try self.requireEntry(for: snapshotId)
        let storedPath = try self.storedArtifactPath(
            sourcePath: annotatedScreenshotPath,
            preferredName: "annotated")

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
        var entry = try self.requireEntry(for: snapshotId)
        entry.lastAccessedAt = Date()
        self.entries[snapshotId] = entry
        return entry.snapshotData.uiMap[elementId]
    }

    public func findElements(snapshotId: String, matching query: String) async throws -> [UIElement] {
        var entry = try self.requireEntry(for: snapshotId)
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
        try self.validateSnapshotReference(snapshotId)
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
