import Foundation
import os
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation

actor UISnapshot {
    private struct TargetCache: Sendable {
        var applicationName: String?
        var windowTitle: String?
        var applicationProcessId: Int32?
        var applicationProcessStartIdentity: UInt64?
        var windowID: Int?
        var windowBounds: CGRect?
        var windowMutationIdentity: WindowMutationIdentity?
        var focusedElement: FocusedElementIdentity?
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

    init(id: String = SnapshotReference.generate().rawValue, createdAt: Date = Date()) {
        self.id = id
        self.createdAt = createdAt
        self.lastAccessedAt = createdAt
    }

    func setScreenshot(path: String, metadata: CaptureMetadata, context: WindowContext? = nil) {
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
            let metadataProcessIdentifier = metadata.applicationInfo.map { Int32($0.processIdentifier) }
            let metadataProcessStartIdentity = metadata.applicationInfo?.processStartIdentity
            let metadataWindowIdentity = metadata.windowInfo?.mutationIdentity
            let contextWindowIdentity = context?.windowMutationIdentity
            let contextFocusedElement = context?.focusedElement
            let contextWindowBounds = context?.windowBounds ?? contextWindowIdentity?.capturedBounds
            let windowIdentity = metadataWindowIdentity ?? contextWindowIdentity
            let windowID = metadata.windowInfo?.windowID ?? contextWindowIdentity?.windowID ?? context?.windowID
            let windowBounds = metadata.windowInfo?.bounds ?? contextWindowBounds
            let applicationProcessIdentifier = metadataProcessIdentifier ?? context?.applicationProcessId ??
                windowIdentity?.ownerProcessIdentifier
            let applicationProcessStartIdentity = metadataProcessStartIdentity ??
                windowIdentity?.ownerProcessStartIdentity
            let hasWindowIdentifierConflict = if let metadataWindowIdentity,
                                                 let metadataWindowID = metadata.windowInfo?.windowID
            {
                metadataWindowIdentity.windowID != metadataWindowID
            } else {
                false
            }
            let hasProcessConflict = if let metadataProcessIdentifier, let windowIdentity {
                windowIdentity.ownerProcessIdentifier != metadataProcessIdentifier
            } else if let contextProcessIdentifier = context?.applicationProcessId, let windowIdentity {
                windowIdentity.ownerProcessIdentifier != contextProcessIdentifier
            } else {
                false
            }
            let hasGenerationConflict = if let metadataProcessStartIdentity, let windowIdentity {
                windowIdentity.ownerProcessStartIdentity != metadataProcessStartIdentity
            } else {
                false
            }
            let hasContextWindowConflict = if let contextWindowIdentity, metadata.windowInfo != nil {
                (metadataWindowIdentity.map {
                    !contextWindowIdentity.hasSameStableReceipt(as: $0)
                } ?? false) ||
                    metadata.windowInfo?.windowID != contextWindowIdentity.windowID ||
                    (contextWindowBounds.map { metadata.windowInfo?.bounds != $0 } ?? false)
            } else {
                false
            }
            let hasMalformedContextWindow = if let contextWindowIdentity {
                context?.windowID.map { $0 != contextWindowIdentity.windowID } ?? false ||
                    (contextWindowIdentity.capturedBounds.flatMap { capturedBounds in
                        context?.windowBounds.map { $0 != capturedBounds }
                    } ?? false)
            } else {
                false
            }
            let hasContextFocusConflict = if let contextFocusedElement {
                contextFocusedElement.processIdentifier != applicationProcessIdentifier ||
                    contextFocusedElement.windowID != windowID ||
                    contextFocusedElement.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    contextFocusedElement.frame.isEmpty ||
                    windowBounds?.contains(CGPoint(
                        x: contextFocusedElement.frame.midX,
                        y: contextFocusedElement.frame.midY)) != true
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
                hasContextWindowConflict || hasMalformedContextWindow || hasContextFocusConflict ||
                hasPriorReceiptConflict ||
                hasPriorReceiptRemoval || hasPriorWindowConflict || hasPriorWindowRemoval

            $0.applicationName = context?.applicationName ?? metadata.applicationInfo?.name
            $0.windowTitle = context?.windowTitle ?? metadata.windowInfo?.title
            $0.applicationProcessId = incomingReceipt?.processIdentifier ?? applicationProcessIdentifier
            $0.applicationProcessStartIdentity = targetReceiptInvalidated ? nil : incomingReceipt?.processStartIdentity
            $0.windowID = windowID
            $0.windowBounds = windowBounds
            $0.windowMutationIdentity = targetReceiptInvalidated ? nil : windowIdentity
            $0.focusedElement = targetReceiptInvalidated ? nil : contextFocusedElement
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
            let incomingFocusedElement = context?.focusedElement
            let incomingReceipt: ApplicationProcessIdentity? = if let incomingProcessIdentifier,
                                                                  let processStartIdentity =
                                                                  context?.applicationProcessStartIdentity
            {
                ApplicationProcessIdentity(
                    processIdentifier: incomingProcessIdentifier,
                    processStartIdentity: processStartIdentity)
            } else {
                incomingWindowIdentity.map {
                    ApplicationProcessIdentity(
                        processIdentifier: $0.ownerProcessIdentifier,
                        processStartIdentity: $0.ownerProcessStartIdentity)
                }
            }
            let effectiveIncomingProcessIdentifier = incomingProcessIdentifier ??
                incomingWindowIdentity?.ownerProcessIdentifier
            let hasMalformedIncomingProcess = if let incomingProcessIdentifier, let incomingWindowIdentity {
                incomingProcessIdentifier != incomingWindowIdentity.ownerProcessIdentifier
            } else {
                false
            }
            let hasMalformedIncomingGeneration = if let processStartIdentity =
                context?.applicationProcessStartIdentity,
                let incomingWindowIdentity
            {
                processStartIdentity != incomingWindowIdentity.ownerProcessStartIdentity
            } else {
                false
            }
            let hasMalformedIncomingWindow = if let incomingWindowID = context?.windowID, let incomingWindowIdentity {
                incomingWindowID != incomingWindowIdentity.windowID
            } else {
                false
            }
            let hasMalformedIncomingFocus = if let incomingFocusedElement {
                incomingFocusedElement.processIdentifier != effectiveIncomingProcessIdentifier ||
                    incomingFocusedElement.windowID != (incomingWindowIdentity?.windowID ?? context?.windowID) ||
                    incomingFocusedElement.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    incomingFocusedElement.frame.isEmpty ||
                    context?.windowBounds?.contains(CGPoint(
                        x: incomingFocusedElement.frame.midX,
                        y: incomingFocusedElement.frame.midY)) != true
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
            if hasMalformedIncomingProcess || hasMalformedIncomingGeneration || hasMalformedIncomingWindow ||
                hasMalformedIncomingFocus || hasPriorProcessConflict || hasPriorGenerationConflict ||
                hasPriorWindowConflict
            {
                $0.targetReceiptInvalidated = true
            }

            $0.applicationName = context?.applicationName
            $0.windowTitle = context?.windowTitle
            if $0.targetReceiptInvalidated {
                $0.applicationProcessId = effectiveIncomingProcessIdentifier
                $0.applicationProcessStartIdentity = nil
                $0.windowMutationIdentity = nil
                $0.focusedElement = nil
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
                $0.focusedElement = incomingFocusedElement
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

    nonisolated var focusedElement: FocusedElementIdentity? {
        self.targetCache.withLock { $0.targetReceiptInvalidated ? nil : $0.focusedElement }
    }

    nonisolated var targetReceiptInvalidated: Bool {
        self.targetCache.withLock { $0.targetReceiptInvalidated }
    }

    /// Atomically projects the store's sticky receipt state into the canonical snapshot adapter.
    nonisolated func targetReceipt() throws -> SnapshotTargetReceipt {
        let cached = self.targetCache.withLock { cache in
            (
                applicationName: cache.applicationName,
                processIdentifier: cache.applicationProcessId,
                processStartIdentity: cache.applicationProcessStartIdentity,
                windowID: cache.windowID,
                windowBounds: cache.windowBounds,
                windowIdentity: cache.windowMutationIdentity,
                focusedElement: cache.focusedElement,
                invalidated: cache.targetReceiptInvalidated)
        }
        let evidence = DesktopTargetEvidenceAdapter.evidence(
            processIdentifier: cached.processIdentifier,
            processStartIdentity: cached.processStartIdentity,
            windowID: cached.windowIdentity == nil ? nil : cached.windowID,
            windowIdentity: cached.windowIdentity,
            windowBounds: cached.windowIdentity == nil ? nil : cached.windowBounds,
            focusedElement: cached.windowIdentity == nil ? nil : cached.focusedElement)
        return try SnapshotTargetReceiptPlanner.assemble(
            snapshotID: self.id,
            additionalEvidence: [evidence],
            targetReceiptInvalidated: cached.invalidated,
            applicationName: cached.applicationName).receipt
    }
}

/// Logical owner of one MCP/Agent snapshot history inside this process.
///
/// Snapshot IDs stay unchanged at the tool and Bridge boundaries. The owner is
/// only an in-process namespace, so two sessions can safely receive the same
/// external ID without replacing one another's UI metadata.
public struct MCPToolSnapshotOwner: Hashable, Sendable {
    fileprivate let rawValue: String

    public init() {
        self.rawValue = "context:\(UUID().uuidString)"
    }

    init(sessionID: String) {
        self.rawValue = "agent-session:\(sessionID)"
    }

    private init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let legacyProcess = Self(rawValue: "process-compatibility")
    static let compatibility = Self.legacyProcess
}

struct MCPToolUISnapshotStore: Sendable {
    let owner: MCPToolSnapshotOwner
    private let manager: UISnapshotManager

    init(owner: MCPToolSnapshotOwner, manager: UISnapshotManager = .shared) {
        self.owner = owner
        self.manager = manager
    }

    func createSnapshot(
        id: String = SnapshotReference.generate().rawValue,
        at creationDate: Date = Date(),
        pending: Bool = false) async -> UISnapshot
    {
        await self.manager.createSnapshot(
            owner: self.owner,
            id: id,
            at: creationDate,
            pending: pending)
    }

    func getSnapshot(id: String?) async -> UISnapshot? {
        await self.manager.getSnapshot(owner: self.owner, id: id)
    }

    func synchronizeImplicitLatestInvalidationWatermark(_ watermark: Date?) async {
        await self.manager.synchronizeImplicitLatestInvalidationWatermark(
            watermark,
            owner: self.owner)
    }

    func activeSnapshotId(id: String?) async -> String? {
        await self.manager.activeSnapshotId(owner: self.owner, id: id)
    }

    @discardableResult
    func invalidateActiveSnapshot(id: String?) async -> String? {
        await self.manager.invalidateActiveSnapshot(owner: self.owner, id: id)
    }

    @discardableResult
    func invalidateImplicitLatestSnapshot(
        through cutoff: Date,
        preserving snapshotId: String? = nil,
        preservedAt: Date? = nil) async -> String?
    {
        let effectivePreservedAt = snapshotId == nil ? nil : (preservedAt ?? Date())
        return await self.manager.invalidateImplicitLatestSnapshot(
            owner: self.owner,
            through: cutoff,
            preserving: snapshotId,
            preservedAt: effectivePreservedAt)
    }

    func removeSnapshot(id: String) async {
        await self.manager.removeSnapshot(owner: self.owner, id: id)
    }

    func removeAllSnapshots() async {
        await self.manager.removeAllSnapshots(owner: self.owner)
    }

    func removeOwner() async {
        await self.manager.removeOwner(self.owner)
    }

    func retainOwner() async {
        await self.manager.retainOwner(self.owner)
    }

    func releaseOwner() async {
        await self.manager.releaseOwner(self.owner)
    }

    func cleanupOldSnapshots(olderThan timeInterval: TimeInterval = 3600) async {
        await self.manager.cleanupOldSnapshots(owner: self.owner, olderThan: timeInterval)
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

    private struct OwnerState {
        var snapshots: [String: UISnapshot] = [:]
        var orderedSnapshotIds: [String] = []
        var snapshotCreationDates: [String: Date] = [:]
        var pendingSnapshotIds: Set<String> = []
        var implicitLatestInvalidatedThrough: Date?
        var implicitLatestPreservation: ImplicitLatestPreservation?
        var activeLeaseCount = 0
    }

    private var ownerStates: [MCPToolSnapshotOwner: OwnerState] = [:]
    private let maximumRetainedSnapshots: Int

    init(maximumRetainedSnapshots: Int = UISnapshotManager.defaultMaximumRetainedSnapshots) {
        self.maximumRetainedSnapshots = max(1, maximumRetainedSnapshots)
    }

    func createSnapshot(
        owner: MCPToolSnapshotOwner,
        id: String = SnapshotReference.generate().rawValue,
        at creationDate: Date = Date(),
        pending: Bool = false) -> UISnapshot
    {
        var state = self.ownerStates[owner] ?? OwnerState()
        if state.snapshots[id] != nil {
            Self.removeSnapshot(id: id, from: &state)
        }
        let snapshot = UISnapshot(id: id, createdAt: creationDate)
        state.snapshots[snapshot.id] = snapshot
        state.orderedSnapshotIds.append(snapshot.id)
        state.snapshotCreationDates[snapshot.id] = creationDate
        if pending {
            state.pendingSnapshotIds.insert(snapshot.id)
        }
        self.pruneOverflowIfNeeded(state: &state)
        self.ownerStates[owner] = state
        return snapshot
    }

    func getSnapshot(owner: MCPToolSnapshotOwner, id: String?) -> UISnapshot? {
        guard let state = self.ownerStates[owner] else { return nil }
        if let id {
            return state.snapshots[id]
        }
        let normalLatest = state.orderedSnapshotIds.enumerated().compactMap { index, snapshotId
            -> (id: String, createdAt: Date, insertionIndex: Int)? in
            guard let creationDate = state.snapshotCreationDates[snapshotId],
                  !state.pendingSnapshotIds.contains(snapshotId),
                  state.implicitLatestInvalidatedThrough.map({ creationDate > $0 }) ?? true
            else { return nil }
            return (snapshotId, creationDate, index)
        }.max { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.insertionIndex < rhs.insertionIndex
            }
            return lhs.createdAt < rhs.createdAt
        }
        if let preservation = state.implicitLatestPreservation,
           state.snapshots[preservation.snapshotId] != nil,
           normalLatest.map({ $0.createdAt <= preservation.preservedAt }) ?? true
        {
            return state.snapshots[preservation.snapshotId]
        }
        return normalLatest.flatMap { state.snapshots[$0.id] }
    }

    func removeSnapshot(owner: MCPToolSnapshotOwner, id: String) {
        guard var state = self.ownerStates[owner] else { return }
        Self.removeSnapshot(id: id, from: &state)
        self.store(state, for: owner)
    }

    private static func removeSnapshot(id: String, from state: inout OwnerState) {
        state.snapshots.removeValue(forKey: id)
        state.orderedSnapshotIds.removeAll(where: { $0 == id })
        state.snapshotCreationDates.removeValue(forKey: id)
        state.pendingSnapshotIds.remove(id)
        if state.implicitLatestPreservation?.snapshotId == id {
            state.implicitLatestPreservation = nil
        }
    }

    private func pruneOverflowIfNeeded(state: inout OwnerState) {
        let overflow = state.snapshots.count - self.maximumRetainedSnapshots
        guard overflow > 0 else { return }

        let preservedSnapshotId = state.implicitLatestPreservation?.snapshotId
        let evictionCandidates = state.orderedSnapshotIds.enumerated()
            .filter { _, id in
                state.snapshots[id] != nil && id != preservedSnapshotId
            }
            .sorted { lhs, rhs in
                let lhsDate = state.snapshotCreationDates[lhs.element] ?? .distantPast
                let rhsDate = state.snapshotCreationDates[rhs.element] ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.offset < rhs.offset
                }
                return lhsDate < rhsDate
            }

        for candidate in evictionCandidates.prefix(overflow) {
            Self.removeSnapshot(id: candidate.element, from: &state)
        }
    }

    func activeSnapshotId(owner: MCPToolSnapshotOwner, id: String?) -> String? {
        if let id, self.ownerStates[owner]?.snapshots[id] != nil {
            return id
        }
        if id != nil {
            return nil
        }
        return self.getSnapshot(owner: owner, id: nil)?.id
    }

    func synchronizeImplicitLatestInvalidationWatermark(
        _ watermark: Date?,
        owner: MCPToolSnapshotOwner)
    {
        guard let watermark else { return }
        _ = self.invalidateImplicitLatestSnapshot(owner: owner, through: watermark)
    }

    @discardableResult
    func invalidateActiveSnapshot(owner: MCPToolSnapshotOwner, id: String?) -> String? {
        guard let id = self.activeSnapshotId(owner: owner, id: id) else { return nil }
        self.invalidateImplicitLatestSnapshot(owner: owner, through: Date())
        return id
    }

    @discardableResult
    func invalidateImplicitLatestSnapshot(owner: MCPToolSnapshotOwner, through cutoff: Date) -> String? {
        self.invalidateImplicitLatestSnapshot(owner: owner, through: cutoff, preserving: nil)
    }

    @discardableResult
    func invalidateImplicitLatestSnapshot(
        owner: MCPToolSnapshotOwner,
        through cutoff: Date,
        preserving snapshotId: String?) -> String?
    {
        self.invalidateImplicitLatestSnapshot(
            owner: owner,
            through: cutoff,
            preserving: snapshotId,
            preservedAt: snapshotId == nil ? nil : Date())
    }

    @discardableResult
    func invalidateImplicitLatestSnapshot(
        owner: MCPToolSnapshotOwner,
        through cutoff: Date,
        preserving snapshotId: String?,
        preservedAt: Date?) -> String?
    {
        var state = self.ownerStates[owner] ?? OwnerState()
        let invalidatedSnapshotId = self.activeSnapshotId(owner: owner, id: nil)
        if let snapshotId {
            state.pendingSnapshotIds.remove(snapshotId)
        }
        let existingWatermark = state.implicitLatestInvalidatedThrough
        if let snapshotId,
           let preservedAt,
           state.snapshots[snapshotId] != nil,
           existingWatermark.map({ $0 <= cutoff }) ?? true
        {
            state.implicitLatestPreservation = .init(
                snapshotId: snapshotId,
                invalidatedThrough: cutoff,
                preservedAt: preservedAt)
        } else if let preservation = state.implicitLatestPreservation,
                  cutoff > preservation.invalidatedThrough
        {
            state.implicitLatestPreservation = nil
        }
        state.implicitLatestInvalidatedThrough = max(state.implicitLatestInvalidatedThrough ?? cutoff, cutoff)
        self.store(state, for: owner)
        return invalidatedSnapshotId
    }

    func removeAllSnapshots(owner: MCPToolSnapshotOwner) {
        self.ownerStates.removeValue(forKey: owner)
    }

    func removeOwner(_ owner: MCPToolSnapshotOwner) {
        guard owner != .compatibility else { return }
        self.ownerStates.removeValue(forKey: owner)
    }

    func retainOwner(_ owner: MCPToolSnapshotOwner) {
        guard owner != .compatibility else { return }
        var state = self.ownerStates[owner] ?? OwnerState()
        state.activeLeaseCount += 1
        self.ownerStates[owner] = state
    }

    func releaseOwner(_ owner: MCPToolSnapshotOwner) {
        guard owner != .compatibility,
              var state = self.ownerStates[owner]
        else { return }
        state.activeLeaseCount = max(0, state.activeLeaseCount - 1)
        if state.activeLeaseCount == 0 {
            self.ownerStates.removeValue(forKey: owner)
        } else {
            self.ownerStates[owner] = state
        }
    }

    func retainedOwnerCountForTesting() -> Int {
        self.ownerStates.count
    }

    func cleanupOldSnapshots(
        owner: MCPToolSnapshotOwner,
        olderThan timeInterval: TimeInterval = 3600) async
    {
        let cutoffDate = Date().addingTimeInterval(-timeInterval)
        let candidates = self.ownerStates[owner]?.snapshots ?? [:]
        for (id, snapshot) in candidates {
            let lastAccessed = await snapshot.lastAccessedAt
            guard lastAccessed <= cutoffDate,
                  self.ownerStates[owner]?.snapshots[id] === snapshot
            else { continue }
            self.removeSnapshot(owner: owner, id: id)
        }
    }

    private func store(_ state: OwnerState, for owner: MCPToolSnapshotOwner) {
        if state.snapshots.isEmpty,
           state.implicitLatestInvalidatedThrough == nil,
           state.implicitLatestPreservation == nil,
           state.activeLeaseCount == 0
        {
            self.ownerStates.removeValue(forKey: owner)
        } else {
            self.ownerStates[owner] = state
        }
    }

    /// Source-compatible test seams. Production callers use the owner-scoped
    /// store injected by `MCPToolContext`.
    func createSnapshot(
        id: String = SnapshotReference.generate().rawValue,
        at creationDate: Date = Date(),
        pending: Bool = false) -> UISnapshot
    {
        self.createSnapshot(
            owner: .compatibility,
            id: id,
            at: creationDate,
            pending: pending)
    }

    func getSnapshot(id: String?) -> UISnapshot? {
        self.getSnapshot(owner: .compatibility, id: id)
    }

    func removeSnapshot(id: String) {
        self.removeSnapshot(owner: .compatibility, id: id)
    }

    func activeSnapshotId(id: String?) -> String? {
        self.activeSnapshotId(owner: .compatibility, id: id)
    }

    func synchronizeImplicitLatestInvalidationWatermark(_ watermark: Date?) {
        self.synchronizeImplicitLatestInvalidationWatermark(watermark, owner: .compatibility)
    }

    @discardableResult
    func invalidateActiveSnapshot(id: String?) -> String? {
        self.invalidateActiveSnapshot(owner: .compatibility, id: id)
    }

    @discardableResult
    func invalidateImplicitLatestSnapshot(through cutoff: Date) -> String? {
        self.invalidateImplicitLatestSnapshot(owner: .compatibility, through: cutoff)
    }

    @discardableResult
    func invalidateImplicitLatestSnapshot(through cutoff: Date, preserving snapshotId: String?) -> String? {
        self.invalidateImplicitLatestSnapshot(
            owner: .compatibility,
            through: cutoff,
            preserving: snapshotId)
    }

    @discardableResult
    func invalidateImplicitLatestSnapshot(
        through cutoff: Date,
        preserving snapshotId: String?,
        preservedAt: Date?) -> String?
    {
        self.invalidateImplicitLatestSnapshot(
            owner: .compatibility,
            through: cutoff,
            preserving: snapshotId,
            preservedAt: preservedAt)
    }

    func removeAllSnapshots() {
        self.removeAllSnapshots(owner: .compatibility)
    }

    func cleanupOldSnapshots(olderThan timeInterval: TimeInterval = 3600) async {
        await self.cleanupOldSnapshots(owner: .compatibility, olderThan: timeInterval)
    }
}
