import CoreGraphics
import Foundation
import PeekabooFoundation
@testable import PeekabooCore

final class StubSnapshotManager: SnapshotManagerProtocol, @unchecked Sendable {
    let supportsImplicitLatestSnapshotInvalidation = true
    let supportsSnapshotMutationLeases = true
    let supportsProducerBoundSnapshotReferences = true
    var copiesScreenshotArtifactsIntoStorage = false
    var effectiveImplicitLatestInvalidationWatermark: Date?
    private(set) var detectionResults: [String: ElementDetectionResult] = [:]
    private(set) var snapshotInfos: [String: SnapshotInfo] = [:]
    private(set) var storedElements: [String: [String: PeekabooCore.UIElement]] = [:]
    private(set) var storedAnnotatedScreenshots: [String: [String]] = [:]
    var mostRecentSnapshotId: String?
    var uiAutomationSnapshotError: PeekabooError?
    var uiAutomationSnapshotCancellation = false
    private(set) var postInvalidationSnapshotReadCount = 0
    var invalidationError: (any Error)?
    var mutationFinishError: (any Error)?
    var afterMutationFinish: (@Sendable () -> Void)?
    var snapshotCreationDelay: Duration?
    var preservingInvalidationDelay: Duration?
    private(set) var invalidationCutoffs: [Date] = []
    private var pendingSnapshotIDs: Set<String> = []
    private var mutationLeases: [String: SnapshotMutationLease] = [:]
    private var snapshotsRequiringFreshObservation: Set<String> = []
    private(set) var exposedPendingSnapshotDuringWrite = false
    struct ScreenshotRecord {
        let path: String
        let applicationBundleId: String?
        let applicationProcessId: Int32?
        let applicationName: String?
        let windowTitle: String?
        let windowBounds: CGRect?
    }

    private(set) var storedScreenshots: [String: [ScreenshotRecord]] = [:]

    func createSnapshot() async throws -> String {
        if let snapshotCreationDelay {
            try await Task.sleep(for: snapshotCreationDelay)
        }
        return self.createSnapshotImpl(pendingAt: nil)
    }

    func createSnapshot(pendingAt observationStartedAt: Date) async throws -> String {
        if let snapshotCreationDelay {
            try await Task.sleep(for: snapshotCreationDelay)
        }
        return self.createSnapshotImpl(pendingAt: observationStartedAt)
    }

    private func createSnapshotImpl(pendingAt observationStartedAt: Date?) -> String {
        let snapshotId = SnapshotReference.generate().rawValue
        let now = observationStartedAt ?? Date()
        self.snapshotInfos[snapshotId] = SnapshotInfo(
            id: snapshotId,
            processId: 0,
            createdAt: now,
            lastAccessedAt: now,
            sizeInBytes: 0,
            screenshotCount: 0,
            isActive: true
        )
        if observationStartedAt != nil {
            self.pendingSnapshotIDs.insert(snapshotId)
        } else {
            self.mostRecentSnapshotId = snapshotId
        }
        return snapshotId
    }

    func storeDetectionResult(snapshotId: String, result: ElementDetectionResult) async throws {
        try self.requireCreatedSnapshot(snapshotId)
        if self.pendingSnapshotIDs.contains(snapshotId), self.mostRecentSnapshotId == snapshotId {
            self.exposedPendingSnapshotDuringWrite = true
        }
        self.detectionResults[snapshotId] = result
        if !self.pendingSnapshotIDs.contains(snapshotId) {
            self.mostRecentSnapshotId = snapshotId
        }

        let existingInfo = self.snapshotInfos[snapshotId]
        let createdAt = existingInfo?.createdAt ?? Date()
        self.snapshotInfos[snapshotId] = SnapshotInfo(
            id: snapshotId,
            processId: existingInfo?.processId ?? 0,
            createdAt: createdAt,
            lastAccessedAt: Date(),
            sizeInBytes: existingInfo?.sizeInBytes ?? 0,
            screenshotCount: (existingInfo?.screenshotCount ?? 0) + 1,
            isActive: true
        )

        self.storedElements[snapshotId] = result.elements.all
            .reduce(into: [String: PeekabooCore.UIElement]()) { partial, element in
                partial[element.id] = PeekabooCore.UIElement(
                    id: element.id,
                    elementId: element.id,
                    role: element.attributes["role"] ?? element.type.rawValue,
                    title: element.attributes["title"],
                    label: element.label,
                    value: element.value,
                    description: element.attributes["description"],
                    help: element.attributes["help"],
                    roleDescription: element.attributes["roleDescription"],
                    identifier: element.attributes["identifier"],
                    frame: element.bounds,
                    isActionable: element.isActionable,
                    isEnabled: element.knownIsEnabled,
                    isSelected: element.isSelected,
                    isValueSettable: element.isValueSettable,
                    parentId: nil,
                    children: [],
                    keyboardShortcut: nil
                )
            }
    }

    func getDetectionResult(snapshotId: String) async throws -> ElementDetectionResult? {
        self.detectionResults[snapshotId]
    }

    func getMostRecentSnapshot() async -> String? {
        self.mostRecentSnapshotId
    }

    func getMostRecentSnapshot(applicationBundleId _: String) async -> String? {
        self.mostRecentSnapshotId
    }

    func ownsSnapshot(snapshotId: String) async throws -> Bool {
        guard SnapshotReference(rawValue: snapshotId) != nil else {
            throw SnapshotError.invalidSnapshotReference(snapshotId)
        }
        return self.snapshotInfos[snapshotId] != nil
    }

    func beginSnapshotMutation(snapshotId: String) async throws -> SnapshotMutationLease {
        guard self.snapshotInfos[snapshotId] != nil else {
            throw SnapshotError.snapshotNotFound
        }
        guard self.mutationLeases[snapshotId] == nil,
              !self.snapshotsRequiringFreshObservation.contains(snapshotId)
        else {
            throw PeekabooError.snapshotStale(
                "Snapshot '\(snapshotId)' already drove a mutation whose result requires a fresh observation. " +
                    "Run 'peekaboo see' again before another mutation. " +
                    "Read-only snapshot inspection is still available."
            )
        }
        let lease = SnapshotMutationLease(snapshotId: snapshotId)
        self.mutationLeases[snapshotId] = lease
        return lease
    }

    func finishSnapshotMutation(
        _ lease: SnapshotMutationLease,
        requiresFreshObservation: Bool
    ) async throws {
        guard self.mutationLeases[lease.snapshotId] == lease else {
            throw SnapshotError.storageError("Mutation lease changed before completion")
        }
        if let mutationFinishError {
            throw mutationFinishError
        }
        self.mutationLeases.removeValue(forKey: lease.snapshotId)
        if requiresFreshObservation {
            self.snapshotsRequiringFreshObservation.insert(lease.snapshotId)
        }
        self.afterMutationFinish?()
    }

    func invalidateImplicitLatestSnapshot(through cutoff: Date) async throws -> String? {
        try await self.invalidateImplicitLatestSnapshot(
            through: cutoff,
            preserving: nil,
            preservedAt: nil
        )
    }

    func invalidateImplicitLatestSnapshot(
        through cutoff: Date,
        preserving snapshotId: String?
    ) async throws -> String? {
        try await self.invalidateImplicitLatestSnapshot(
            through: cutoff,
            preserving: snapshotId,
            preservedAt: snapshotId == nil ? nil : Date()
        )
    }

    func invalidateImplicitLatestSnapshot(
        through cutoff: Date,
        preserving snapshotId: String?,
        preservedAt _: Date?
    ) async throws -> String? {
        self.invalidationCutoffs.append(cutoff)
        if snapshotId != nil, let preservingInvalidationDelay {
            try await Task.sleep(for: preservingInvalidationDelay)
        }
        if let invalidationError {
            throw invalidationError
        }
        let invalidatedSnapshotID = self.mostRecentSnapshotId
        if let snapshotId, snapshotInfos[snapshotId] != nil {
            self.pendingSnapshotIDs.remove(snapshotId)
            self.mostRecentSnapshotId = snapshotId
        } else {
            self.mostRecentSnapshotId = nil
        }
        return invalidatedSnapshotID
    }

    func listSnapshots() async throws -> [SnapshotInfo] {
        self.snapshotInfos.values.filter { !self.pendingSnapshotIDs.contains($0.id) }
    }

    func cleanSnapshot(snapshotId: String) async throws {
        self.detectionResults.removeValue(forKey: snapshotId)
        self.snapshotInfos.removeValue(forKey: snapshotId)
        self.storedElements.removeValue(forKey: snapshotId)
        self.pendingSnapshotIDs.remove(snapshotId)
        self.mutationLeases.removeValue(forKey: snapshotId)
        self.snapshotsRequiringFreshObservation.remove(snapshotId)
        if self.mostRecentSnapshotId == snapshotId {
            self.mostRecentSnapshotId = nil
        }
    }

    func cleanSnapshotsOlderThan(days: Int) async throws -> Int {
        let threshold = Date().addingTimeInterval(TimeInterval(-days * 24 * 60 * 60))
        let ids: [String] = self.snapshotInfos.values
            .filter { $0.lastAccessedAt < threshold }
            .reduce(into: []) { partialResult, info in
                partialResult.append(info.id)
            }
        for id in ids {
            try await self.cleanSnapshot(snapshotId: id)
        }
        return ids.count
    }

    func cleanAllSnapshots() async throws -> Int {
        let count = self.snapshotInfos.count
        self.detectionResults.removeAll()
        self.snapshotInfos.removeAll()
        self.storedElements.removeAll()
        self.pendingSnapshotIDs.removeAll()
        self.mutationLeases.removeAll()
        self.snapshotsRequiringFreshObservation.removeAll()
        self.mostRecentSnapshotId = nil
        return count
    }

    func getSnapshotStoragePath() -> String {
        "/tmp/peekaboo-snapshots"
    }

    func storeScreenshot(_ request: SnapshotScreenshotRequest) async throws {
        try self.requireCreatedSnapshot(request.snapshotId)
        if self.pendingSnapshotIDs.contains(request.snapshotId), self.mostRecentSnapshotId == request.snapshotId {
            self.exposedPendingSnapshotDuringWrite = true
        }
        let existingInfo = self.snapshotInfos[request.snapshotId]
        let createdAt = existingInfo?.createdAt ?? Date()
        let screenshotCount = (existingInfo?.screenshotCount ?? 0) + 1
        self.snapshotInfos[request.snapshotId] = SnapshotInfo(
            id: request.snapshotId,
            processId: existingInfo?.processId ?? 0,
            createdAt: createdAt,
            lastAccessedAt: Date(),
            sizeInBytes: existingInfo?.sizeInBytes ?? 0,
            screenshotCount: screenshotCount,
            isActive: existingInfo?.isActive ?? true
        )
        var records = self.storedScreenshots[request.snapshotId] ?? []
        records.append(
            ScreenshotRecord(
                path: request.screenshotPath,
                applicationBundleId: request.applicationBundleId,
                applicationProcessId: request.applicationProcessId,
                applicationName: request.applicationName,
                windowTitle: request.windowTitle,
                windowBounds: request.windowBounds
            )
        )
        self.storedScreenshots[request.snapshotId] = records
    }

    func storeAnnotatedScreenshot(snapshotId: String, annotatedScreenshotPath: String) async throws {
        try self.requireCreatedSnapshot(snapshotId)
        var records = self.storedAnnotatedScreenshots[snapshotId] ?? []
        records.append(annotatedScreenshotPath)
        self.storedAnnotatedScreenshots[snapshotId] = records
    }

    private func requireCreatedSnapshot(_ snapshotId: String) throws {
        guard SnapshotReference(rawValue: snapshotId) != nil else {
            throw SnapshotError.invalidSnapshotReference(snapshotId)
        }
        guard self.snapshotInfos[snapshotId] != nil else {
            throw SnapshotError.snapshotNotFound
        }
    }

    func getElement(snapshotId: String, elementId: String) async throws -> PeekabooCore.UIElement? {
        self.storedElements[snapshotId]?[elementId]
    }

    func findElements(snapshotId: String, matching query: String) async throws -> [PeekabooCore.UIElement] {
        self.storedElements[snapshotId]?.values.filter {
            $0.label?.localizedCaseInsensitiveContains(query) == true ||
                $0.title?.localizedCaseInsensitiveContains(query) == true
        } ?? []
    }

    func getUIAutomationSnapshot(snapshotId _: String) async throws -> UIAutomationSnapshot? {
        if !self.invalidationCutoffs.isEmpty {
            self.postInvalidationSnapshotReadCount += 1
        }
        if self.uiAutomationSnapshotCancellation {
            throw CancellationError()
        }
        if let uiAutomationSnapshotError {
            throw uiAutomationSnapshotError
        }
        return nil
    }
}
