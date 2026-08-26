import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

/// Records mutation-lease completion while preserving the wrapped manager's behavior.
@MainActor
public final class SnapshotMutationRecordingManager: SnapshotManagerProtocol {
    public struct FinishCall: Equatable, Sendable {
        public let lease: SnapshotMutationLease
        public let requiresFreshObservation: Bool

        public init(lease: SnapshotMutationLease, requiresFreshObservation: Bool) {
            self.lease = lease
            self.requiresFreshObservation = requiresFreshObservation
        }
    }

    public private(set) var beginCalls: [String] = []
    public private(set) var finishCalls: [FinishCall] = []
    public private(set) var ownsCalls: [String] = []
    public private(set) var createCalls: [Date?] = []
    public private(set) var createExplicitCallCount = 0
    public var failFinish = false
    public var ownsSnapshotError: (any Error)?

    private let wrapped: any SnapshotManagerProtocol
    private let producerBoundSnapshotReferencesOverride: Bool?
    private let createdSnapshotReferenceOverride: String?

    public init(
        wrapping wrapped: any SnapshotManagerProtocol,
        supportsProducerBoundSnapshotReferences: Bool? = nil,
        createdSnapshotReferenceOverride: String? = nil)
    {
        self.wrapped = wrapped
        self.producerBoundSnapshotReferencesOverride = supportsProducerBoundSnapshotReferences
        self.createdSnapshotReferenceOverride = createdSnapshotReferenceOverride
    }

    public var supportsImplicitLatestSnapshotInvalidation: Bool {
        self.wrapped.supportsImplicitLatestSnapshotInvalidation
    }

    public var copiesScreenshotArtifactsIntoStorage: Bool {
        self.wrapped.copiesScreenshotArtifactsIntoStorage
    }

    public var supportsAtomicObservationSnapshotPublication: Bool {
        self.wrapped.supportsAtomicObservationSnapshotPublication
    }

    public var supportsSnapshotMutationLeases: Bool {
        self.wrapped.supportsSnapshotMutationLeases
    }

    public var supportsExplicitSnapshotPublication: Bool {
        self.wrapped.supportsExplicitSnapshotPublication
    }

    public var supportsProducerBoundSnapshotReferences: Bool {
        self.producerBoundSnapshotReferencesOverride ?? self.wrapped.supportsProducerBoundSnapshotReferences
    }

    public var effectiveImplicitLatestInvalidationWatermark: Date? {
        self.wrapped.effectiveImplicitLatestInvalidationWatermark
    }

    public func createSnapshot() async throws -> String {
        self.createCalls.append(nil)
        if let createdSnapshotReferenceOverride {
            return createdSnapshotReferenceOverride
        }
        return try await self.wrapped.createSnapshot()
    }

    public func createSnapshot(pendingAt observationStartedAt: Date) async throws -> String {
        self.createCalls.append(observationStartedAt)
        if let createdSnapshotReferenceOverride {
            return createdSnapshotReferenceOverride
        }
        return try await self.wrapped.createSnapshot(pendingAt: observationStartedAt)
    }

    public func createExplicitSnapshot() async throws -> String {
        self.createExplicitCallCount += 1
        if let createdSnapshotReferenceOverride {
            return createdSnapshotReferenceOverride
        }
        return try await self.wrapped.createExplicitSnapshot()
    }

    public func ownsSnapshot(snapshotId: String) async throws -> Bool {
        self.ownsCalls.append(snapshotId)
        if let ownsSnapshotError {
            throw ownsSnapshotError
        }
        guard self.supportsProducerBoundSnapshotReferences else { return false }
        return try await self.wrapped.ownsSnapshot(snapshotId: snapshotId)
    }

    public func storeDetectionResult(snapshotId: String, result: ElementDetectionResult) async throws {
        try await self.wrapped.storeDetectionResult(snapshotId: snapshotId, result: result)
    }

    public func getDetectionResult(snapshotId: String) async throws -> ElementDetectionResult? {
        try await self.wrapped.getDetectionResult(snapshotId: snapshotId)
    }

    public func getMostRecentSnapshot() async -> String? {
        await self.wrapped.getMostRecentSnapshot()
    }

    public func getMostRecentSnapshot(applicationBundleId: String) async -> String? {
        await self.wrapped.getMostRecentSnapshot(applicationBundleId: applicationBundleId)
    }

    public func invalidateImplicitLatestSnapshot(through cutoff: Date) async throws -> String? {
        try await self.wrapped.invalidateImplicitLatestSnapshot(through: cutoff)
    }

    public func invalidateImplicitLatestSnapshot(
        through cutoff: Date,
        preserving snapshotId: String?) async throws -> String?
    {
        try await self.wrapped.invalidateImplicitLatestSnapshot(through: cutoff, preserving: snapshotId)
    }

    public func invalidateImplicitLatestSnapshot(
        through cutoff: Date,
        preserving snapshotId: String?,
        preservedAt: Date?) async throws -> String?
    {
        try await self.wrapped.invalidateImplicitLatestSnapshot(
            through: cutoff,
            preserving: snapshotId,
            preservedAt: preservedAt)
    }

    public func listSnapshots() async throws -> [SnapshotInfo] {
        try await self.wrapped.listSnapshots()
    }

    public func cleanSnapshot(snapshotId: String) async throws {
        try await self.wrapped.cleanSnapshot(snapshotId: snapshotId)
    }

    public func cleanSnapshotsOlderThan(days: Int) async throws -> Int {
        try await self.wrapped.cleanSnapshotsOlderThan(days: days)
    }

    public func cleanAllSnapshots() async throws -> Int {
        try await self.wrapped.cleanAllSnapshots()
    }

    public func getSnapshotStoragePath() -> String {
        self.wrapped.getSnapshotStoragePath()
    }

    public func storeScreenshot(_ request: SnapshotScreenshotRequest) async throws {
        try await self.wrapped.storeScreenshot(request)
    }

    public func storeObservationSnapshot(_ request: SnapshotObservationPublicationRequest) async throws {
        try await self.wrapped.storeObservationSnapshot(request)
    }

    public func storeAnnotatedScreenshot(
        snapshotId: String,
        annotatedScreenshotPath: String) async throws
    {
        try await self.wrapped.storeAnnotatedScreenshot(
            snapshotId: snapshotId,
            annotatedScreenshotPath: annotatedScreenshotPath)
    }

    public func getElement(snapshotId: String, elementId: String) async throws -> UIElement? {
        try await self.wrapped.getElement(snapshotId: snapshotId, elementId: elementId)
    }

    public func findElements(snapshotId: String, matching query: String) async throws -> [UIElement] {
        try await self.wrapped.findElements(snapshotId: snapshotId, matching: query)
    }

    public func getUIAutomationSnapshot(snapshotId: String) async throws -> UIAutomationSnapshot? {
        try await self.wrapped.getUIAutomationSnapshot(snapshotId: snapshotId)
    }

    public func beginSnapshotMutation(snapshotId: String) async throws -> SnapshotMutationLease {
        self.beginCalls.append(snapshotId)
        return try await self.wrapped.beginSnapshotMutation(snapshotId: snapshotId)
    }

    public func finishSnapshotMutation(
        _ lease: SnapshotMutationLease,
        requiresFreshObservation: Bool) async throws
    {
        self.finishCalls.append(FinishCall(
            lease: lease,
            requiresFreshObservation: requiresFreshObservation))
        if self.failFinish {
            throw SnapshotError.storageError("Injected snapshot mutation finalization failure")
        }
        try await self.wrapped.finishSnapshotMutation(
            lease,
            requiresFreshObservation: requiresFreshObservation)
    }
}
