import Foundation
import os
import PeekabooAutomation
import PeekabooAutomationKit

actor UISnapshot {
    private struct TargetCache: Sendable {
        var applicationName: String?
        var windowTitle: String?
        var applicationProcessId: Int32?
        var applicationProcessStartIdentity: UInt64?
        var windowID: Int?
        var windowBounds: CGRect?
        var windowMutationIdentity: WindowMutationIdentity?
        var targetReceiptInvalidated = false
    }

    let id: String
    private(set) var screenshotPath: String?
    private(set) var screenshotMetadata: CaptureMetadata?
    private(set) var screenshotCoordinateContext: CaptureCoordinateContext?
    private(set) var uiElements: [UIElement] = []
    private(set) var createdAt: Date
    private(set) var lastAccessedAt: Date
    /// Cache readable from any isolation domain without `nonisolated(unsafe)` stored properties.
    private let targetCache = OSAllocatedUnfairLock(initialState: TargetCache())

    init(id: String = UUID().uuidString, createdAt: Date = Date()) {
        self.id = id
        self.createdAt = createdAt
        self.lastAccessedAt = createdAt
    }

    func setScreenshot(path: String, metadata: CaptureMetadata) {
        self.screenshotPath = path
        self.screenshotMetadata = metadata
        self.screenshotCoordinateContext = CaptureCoordinateContext(metadata: metadata, referenceID: self.id)
        self.targetCache.withLock {
            let priorWindowIdentity = $0.windowMutationIdentity
            let priorReceipt: ApplicationProcessIdentity? = if let priorProcessIdentifier = $0.applicationProcessId,
                                                               let priorProcessStartIdentity =
                                                               $0.applicationProcessStartIdentity
            {
                ApplicationProcessIdentity(
                    processIdentifier: priorProcessIdentifier,
                    processStartIdentity: priorProcessStartIdentity)
            } else if let priorWindowIdentity = $0.windowMutationIdentity {
                ApplicationProcessIdentity(
                    processIdentifier: priorWindowIdentity.ownerProcessIdentifier,
                    processStartIdentity: priorWindowIdentity.ownerProcessStartIdentity)
            } else {
                nil
            }
            let applicationProcessIdentifier = metadata.applicationInfo.map { Int32($0.processIdentifier) }
            let applicationProcessStartIdentity = metadata.applicationInfo?.processStartIdentity
            let windowIdentity = metadata.windowInfo?.mutationIdentity
            let hasWindowIdentifierConflict = if let windowIdentity, let windowID = metadata.windowInfo?.windowID {
                windowIdentity.windowID != windowID
            } else {
                false
            }
            let hasProcessConflict = if let applicationProcessIdentifier, let windowIdentity {
                windowIdentity.ownerProcessIdentifier != applicationProcessIdentifier
            } else {
                false
            }
            let hasGenerationConflict = if let applicationProcessStartIdentity, let windowIdentity {
                windowIdentity.ownerProcessStartIdentity != applicationProcessStartIdentity
            } else {
                false
            }
            let incomingReceipt: ApplicationProcessIdentity? = if let applicationProcessIdentifier,
                                                                  let applicationProcessStartIdentity
            {
                ApplicationProcessIdentity(
                    processIdentifier: applicationProcessIdentifier,
                    processStartIdentity: applicationProcessStartIdentity)
            } else if let windowIdentity {
                ApplicationProcessIdentity(
                    processIdentifier: windowIdentity.ownerProcessIdentifier,
                    processStartIdentity: windowIdentity.ownerProcessStartIdentity)
            } else {
                nil
            }
            let hasPriorReceiptConflict = if let priorReceipt, let incomingReceipt {
                priorReceipt != incomingReceipt
            } else {
                false
            }
            let hasPriorReceiptRemoval = priorReceipt != nil && incomingReceipt == nil
            let hasPriorWindowConflict = if let priorWindowIdentity, let windowIdentity {
                priorWindowIdentity != windowIdentity
            } else {
                false
            }
            let hasPriorWindowRemoval = priorWindowIdentity != nil && windowIdentity == nil
            let targetReceiptInvalidated = $0.targetReceiptInvalidated ||
                hasWindowIdentifierConflict || hasProcessConflict || hasGenerationConflict ||
                hasPriorReceiptConflict || hasPriorReceiptRemoval || hasPriorWindowConflict || hasPriorWindowRemoval

            $0.applicationName = metadata.applicationInfo?.name
            $0.windowTitle = metadata.windowInfo?.title
            $0.applicationProcessId = incomingReceipt?.processIdentifier ?? applicationProcessIdentifier
            $0.applicationProcessStartIdentity = targetReceiptInvalidated ? nil : incomingReceipt?.processStartIdentity
            $0.windowID = metadata.windowInfo?.windowID
            $0.windowBounds = metadata.windowInfo?.bounds
            $0.windowMutationIdentity = targetReceiptInvalidated ? nil : windowIdentity
            $0.targetReceiptInvalidated = targetReceiptInvalidated
        }
        self.lastAccessedAt = Date()
    }

    func setUIElements(_ elements: [UIElement]) {
        self.uiElements = elements
        self.lastAccessedAt = Date()
    }

    func setTargetMetadata(from context: WindowContext?) {
        self.targetCache.withLock {
            let priorWindowIdentity = $0.windowMutationIdentity
            let priorWindowBounds = $0.windowBounds
            let priorReceipt: ApplicationProcessIdentity? = if let priorProcessIdentifier = $0.applicationProcessId,
                                                               let priorProcessStartIdentity =
                                                               $0.applicationProcessStartIdentity
            {
                ApplicationProcessIdentity(
                    processIdentifier: priorProcessIdentifier,
                    processStartIdentity: priorProcessStartIdentity)
            } else if let priorWindowIdentity {
                ApplicationProcessIdentity(
                    processIdentifier: priorWindowIdentity.ownerProcessIdentifier,
                    processStartIdentity: priorWindowIdentity.ownerProcessStartIdentity)
            } else {
                nil
            }
            let incomingProcessIdentifier = context?.applicationProcessId
            let incomingWindowIdentity = context?.windowMutationIdentity
            let incomingReceipt = incomingWindowIdentity.map {
                ApplicationProcessIdentity(
                    processIdentifier: $0.ownerProcessIdentifier,
                    processStartIdentity: $0.ownerProcessStartIdentity)
            }
            let effectiveIncomingProcessIdentifier = incomingProcessIdentifier ??
                incomingWindowIdentity?.ownerProcessIdentifier
            let hasMalformedIncomingProcess = if let incomingProcessIdentifier, let incomingWindowIdentity {
                incomingProcessIdentifier != incomingWindowIdentity.ownerProcessIdentifier
            } else {
                false
            }
            let hasMalformedIncomingWindow = if let incomingWindowID = context?.windowID, let incomingWindowIdentity {
                incomingWindowID != incomingWindowIdentity.windowID
            } else {
                false
            }
            let hasPriorProcessConflict = if let priorReceipt, let effectiveIncomingProcessIdentifier {
                priorReceipt.processIdentifier != effectiveIncomingProcessIdentifier
            } else {
                false
            }
            let hasPriorGenerationConflict = if let priorReceipt, let incomingReceipt {
                priorReceipt != incomingReceipt
            } else {
                false
            }
            let hasPriorWindowConflict = if let priorWindowIdentity, let incomingWindowIdentity {
                priorWindowIdentity != incomingWindowIdentity
            } else if let priorWindowIdentity, let incomingWindowID = context?.windowID {
                priorWindowIdentity.windowID != incomingWindowID
            } else {
                false
            }
            if hasMalformedIncomingProcess || hasMalformedIncomingWindow ||
                hasPriorProcessConflict || hasPriorGenerationConflict || hasPriorWindowConflict
            {
                $0.targetReceiptInvalidated = true
            }

            $0.applicationName = context?.applicationName
            $0.windowTitle = context?.windowTitle
            if $0.targetReceiptInvalidated {
                $0.applicationProcessId = effectiveIncomingProcessIdentifier
                $0.applicationProcessStartIdentity = nil
                $0.windowMutationIdentity = nil
                $0.windowID = context?.windowID
                $0.windowBounds = context?.windowBounds
            } else {
                let resolvedReceipt = priorReceipt ?? incomingReceipt
                let resolvedWindowIdentity = priorWindowIdentity ?? incomingWindowIdentity
                $0.applicationProcessId = resolvedReceipt?.processIdentifier ?? effectiveIncomingProcessIdentifier
                $0.applicationProcessStartIdentity = resolvedReceipt?.processStartIdentity
                $0.windowMutationIdentity = resolvedWindowIdentity
                $0.windowID = resolvedWindowIdentity?.windowID ?? context?.windowID
                $0.windowBounds = priorWindowIdentity == nil ? context?.windowBounds : priorWindowBounds
            }
        }
        self.lastAccessedAt = Date()
    }

    func getElement(byId id: String) -> UIElement? {
        self.uiElements.first { $0.id == id }
    }

    nonisolated var applicationName: String? {
        self.targetCache.withLock { $0.applicationName }
    }

    nonisolated var windowTitle: String? {
        self.targetCache.withLock { $0.windowTitle }
    }

    nonisolated var applicationProcessId: Int32? {
        self.targetCache.withLock { $0.applicationProcessId }
    }

    nonisolated var applicationProcessIdentity: ApplicationProcessIdentity? {
        self.targetCache.withLock { cache in
            guard !cache.targetReceiptInvalidated else { return nil }
            guard let processIdentifier = cache.applicationProcessId else { return nil }
            if let windowIdentity = cache.windowMutationIdentity,
               windowIdentity.ownerProcessIdentifier == processIdentifier
            {
                return ApplicationProcessIdentity(
                    processIdentifier: processIdentifier,
                    processStartIdentity: windowIdentity.ownerProcessStartIdentity)
            }
            return cache.applicationProcessStartIdentity.map {
                ApplicationProcessIdentity(
                    processIdentifier: processIdentifier,
                    processStartIdentity: $0)
            }
        }
    }

    nonisolated var windowID: Int? {
        self.targetCache.withLock { $0.windowID }
    }

    nonisolated var windowBounds: CGRect? {
        self.targetCache.withLock { $0.windowBounds }
    }

    nonisolated var windowMutationIdentity: WindowMutationIdentity? {
        self.targetCache.withLock { $0.targetReceiptInvalidated ? nil : $0.windowMutationIdentity }
    }
}

actor UISnapshotManager {
    static let defaultMaximumRetainedSnapshots = 25

    private struct ImplicitLatestPreservation {
        let snapshotId: String
        let invalidatedThrough: Date
        let preservedAt: Date
    }

    static let shared = UISnapshotManager()

    private var snapshots: [String: UISnapshot] = [:]
    private var orderedSnapshotIds: [String] = []
    private var snapshotCreationDates: [String: Date] = [:]
    private var pendingSnapshotIds: Set<String> = []
    private var implicitLatestInvalidatedThrough: Date?
    private var implicitLatestPreservation: ImplicitLatestPreservation?
    private let maximumRetainedSnapshots: Int

    init(maximumRetainedSnapshots: Int = UISnapshotManager.defaultMaximumRetainedSnapshots) {
        self.maximumRetainedSnapshots = max(1, maximumRetainedSnapshots)
    }

    func createSnapshot(
        id: String = UUID().uuidString,
        at creationDate: Date = Date(),
        pending: Bool = false) -> UISnapshot
    {
        if self.snapshots[id] != nil {
            self.removeSnapshot(id: id)
        }
        let snapshot = UISnapshot(id: id, createdAt: creationDate)
        self.snapshots[snapshot.id] = snapshot
        self.orderedSnapshotIds.append(snapshot.id)
        self.snapshotCreationDates[snapshot.id] = creationDate
        if pending {
            self.pendingSnapshotIds.insert(snapshot.id)
        }
        self.pruneOverflowIfNeeded()
        return snapshot
    }

    func getSnapshot(id: String?) -> UISnapshot? {
        if let id {
            return self.snapshots[id]
        }
        let normalLatest = self.orderedSnapshotIds.enumerated().compactMap { index, snapshotId
            -> (id: String, createdAt: Date, insertionIndex: Int)? in
            guard let creationDate = self.snapshotCreationDates[snapshotId],
                  !self.pendingSnapshotIds.contains(snapshotId),
                  self.implicitLatestInvalidatedThrough.map({ creationDate > $0 }) ?? true
            else { return nil }
            return (snapshotId, creationDate, index)
        }.max { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.insertionIndex < rhs.insertionIndex
            }
            return lhs.createdAt < rhs.createdAt
        }
        if let preservation = self.implicitLatestPreservation,
           self.snapshots[preservation.snapshotId] != nil,
           normalLatest.map({ $0.createdAt <= preservation.preservedAt }) ?? true
        {
            return self.snapshots[preservation.snapshotId]
        }
        return normalLatest.flatMap { self.snapshots[$0.id] }
    }

    func removeSnapshot(id: String) {
        self.snapshots.removeValue(forKey: id)
        self.orderedSnapshotIds.removeAll(where: { $0 == id })
        self.snapshotCreationDates.removeValue(forKey: id)
        self.pendingSnapshotIds.remove(id)
        if self.implicitLatestPreservation?.snapshotId == id {
            self.implicitLatestPreservation = nil
        }
    }

    private func pruneOverflowIfNeeded() {
        let overflow = self.snapshots.count - self.maximumRetainedSnapshots
        guard overflow > 0 else { return }

        let preservedSnapshotId = self.implicitLatestPreservation?.snapshotId
        let evictionCandidates = self.orderedSnapshotIds.enumerated()
            .filter { _, id in
                self.snapshots[id] != nil && id != preservedSnapshotId
            }
            .sorted { lhs, rhs in
                let lhsDate = self.snapshotCreationDates[lhs.element] ?? .distantPast
                let rhsDate = self.snapshotCreationDates[rhs.element] ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.offset < rhs.offset
                }
                return lhsDate < rhsDate
            }

        for candidate in evictionCandidates.prefix(overflow) {
            self.removeSnapshot(id: candidate.element)
        }
    }

    func activeSnapshotId(id: String?) -> String? {
        if let id, self.snapshots[id] != nil {
            return id
        }
        if id != nil {
            return nil
        }
        return self.getSnapshot(id: nil)?.id
    }

    func synchronizeImplicitLatestInvalidationWatermark(_ watermark: Date?) {
        guard let watermark else { return }
        _ = self.invalidateImplicitLatestSnapshot(through: watermark)
    }

    @discardableResult
    func invalidateActiveSnapshot(id: String?) -> String? {
        guard let id = self.activeSnapshotId(id: id) else { return nil }
        self.invalidateImplicitLatestSnapshot(through: Date())
        return id
    }

    @discardableResult
    func invalidateImplicitLatestSnapshot(through cutoff: Date) -> String? {
        self.invalidateImplicitLatestSnapshot(through: cutoff, preserving: nil)
    }

    @discardableResult
    func invalidateImplicitLatestSnapshot(through cutoff: Date, preserving snapshotId: String?) -> String? {
        self.invalidateImplicitLatestSnapshot(
            through: cutoff,
            preserving: snapshotId,
            preservedAt: snapshotId == nil ? nil : Date())
    }

    @discardableResult
    func invalidateImplicitLatestSnapshot(
        through cutoff: Date,
        preserving snapshotId: String?,
        preservedAt: Date?) -> String?
    {
        let invalidatedSnapshotId = self.activeSnapshotId(id: nil)
        if let snapshotId {
            self.pendingSnapshotIds.remove(snapshotId)
        }
        let existingWatermark = self.implicitLatestInvalidatedThrough
        if let snapshotId,
           let preservedAt,
           self.snapshots[snapshotId] != nil,
           existingWatermark.map({ $0 <= cutoff }) ?? true
        {
            self.implicitLatestPreservation = .init(
                snapshotId: snapshotId,
                invalidatedThrough: cutoff,
                preservedAt: preservedAt)
        } else if let preservation = self.implicitLatestPreservation,
                  cutoff > preservation.invalidatedThrough
        {
            self.implicitLatestPreservation = nil
        }
        self.implicitLatestInvalidatedThrough = max(self.implicitLatestInvalidatedThrough ?? cutoff, cutoff)
        return invalidatedSnapshotId
    }

    func removeAllSnapshots() {
        self.snapshots.removeAll()
        self.orderedSnapshotIds.removeAll()
        self.snapshotCreationDates.removeAll()
        self.pendingSnapshotIds.removeAll()
        self.implicitLatestInvalidatedThrough = nil
        self.implicitLatestPreservation = nil
    }

    func cleanupOldSnapshots(olderThan timeInterval: TimeInterval = 3600) async {
        let cutoffDate = Date().addingTimeInterval(-timeInterval)
        let candidates = self.snapshots
        for (id, snapshot) in candidates {
            let lastAccessed = await snapshot.lastAccessedAt
            guard lastAccessed <= cutoffDate,
                  self.snapshots[id] === snapshot
            else { continue }
            self.removeSnapshot(id: id)
        }
    }
}
