import CoreGraphics
import Foundation

extension InMemorySnapshotManager {
    // MARK: - Screenshot + UI map helpers

    public func storeScreenshot(_ request: SnapshotScreenshotRequest) async throws {
        self.pruneIfNeeded()

        var entry = self.entries[request.snapshotId] ?? Entry(
            createdAt: Date(),
            lastAccessedAt: Date(),
            processId: getpid(),
            isPending: false,
            detectionResult: nil,
            snapshotData: UIAutomationSnapshot(creatorProcessId: getpid()))

        entry.lastAccessedAt = Date()
        entry.detectionResult = nil
        entry.snapshotData.screenshotPath = request.screenshotPath
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

        var entry = self.entries[snapshotId] ?? Entry(
            createdAt: Date(),
            lastAccessedAt: Date(),
            processId: getpid(),
            isPending: false,
            detectionResult: nil,
            snapshotData: UIAutomationSnapshot(creatorProcessId: getpid()))

        entry.lastAccessedAt = Date()
        entry.snapshotData.annotatedPath = annotatedScreenshotPath
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
}
