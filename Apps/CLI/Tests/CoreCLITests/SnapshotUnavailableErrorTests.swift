import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

/// Regression tests for the honest, actionable errors when implicit "latest snapshot" resolution
/// comes back empty. Previously both cases collapsed into the misleading
/// `"Snapshot not found or expired: No snapshot found"`.
@Suite(.tags(.safe))
@MainActor
struct SnapshotUnavailableErrorTests {
    @Test
    func `Never-captured snapshot resolves to an actionable snapshotNotAvailable error`() async throws {
        let snapshots = WatermarkAwareSnapshotManagerStub()

        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )

        #expect(observation.unavailability == .noSnapshotCaptured)
        do {
            _ = try observation.requireSnapshot()
            Issue.record("Expected requireSnapshot to throw")
        } catch let PeekabooError.snapshotNotAvailable(message) {
            #expect(message.contains("peekaboo see"))
        }
    }

    @Test
    func `Watermark-hidden snapshot resolves to a distinct stale error that mentions see`() async throws {
        let snapshots = WatermarkAwareSnapshotManagerStub()
        _ = try await snapshots.createSnapshot(id: "hidden")
        _ = try await snapshots.invalidateImplicitLatestSnapshot(through: Date())

        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )

        #expect(observation.unavailability == .invalidatedByMutation)
        do {
            _ = try observation.requireSnapshot()
            Issue.record("Expected requireSnapshot to throw")
        } catch let error as PeekabooError {
            guard case let .snapshotStale(reason) = error else {
                Issue.record("Expected snapshotStale, got \(error)")
                return
            }
            #expect(reason.contains("invalidated"))
            let description = try #require(error.errorDescription)
            #expect(description.contains("Re-run peekaboo see"))
        }
    }
}

/// Minimal in-memory snapshot manager that honors an invalidation watermark for implicit lookup
/// while `listSnapshots()` stays watermark-blind, mirroring the real manager just enough to drive
/// the `noSnapshotCaptured` vs `invalidatedByMutation` distinction.
@MainActor
private final class WatermarkAwareSnapshotManagerStub: SnapshotManagerProtocol {
    nonisolated let supportsImplicitLatestSnapshotInvalidation = true
    private var snapshotInfos: [String: SnapshotInfo] = [:]
    private var watermark: Date?

    var effectiveImplicitLatestInvalidationWatermark: Date? {
        self.watermark
    }

    func createSnapshot() async throws -> String {
        try await self.createSnapshot(id: UUID().uuidString)
    }

    @discardableResult
    func createSnapshot(id snapshotId: String) async throws -> String {
        self.snapshotInfos[snapshotId] = SnapshotInfo(
            id: snapshotId,
            processId: 0,
            createdAt: Date(),
            lastAccessedAt: Date(),
            sizeInBytes: 0,
            screenshotCount: 0,
            isActive: true
        )
        return snapshotId
    }

    func storeDetectionResult(snapshotId _: String, result _: ElementDetectionResult) async throws {}

    func getDetectionResult(snapshotId _: String) async throws -> ElementDetectionResult? {
        nil
    }

    func getMostRecentSnapshot() async -> String? {
        self.snapshotInfos.values
            .filter { info in self.watermark.map { info.createdAt > $0 } ?? true }
            .max(by: { $0.createdAt < $1.createdAt })?
            .id
    }

    func getMostRecentSnapshot(applicationBundleId _: String) async -> String? {
        await self.getMostRecentSnapshot()
    }

    func invalidateImplicitLatestSnapshot(through cutoff: Date) async throws -> String? {
        try await self.invalidateImplicitLatestSnapshot(through: cutoff, preserving: nil, preservedAt: nil)
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
        preserving _: String?,
        preservedAt _: Date?
    ) async throws -> String? {
        let invalidated = await self.getMostRecentSnapshot()
        self.watermark = max(self.watermark ?? cutoff, cutoff)
        return invalidated
    }

    func listSnapshots() async throws -> [SnapshotInfo] {
        Array(self.snapshotInfos.values)
    }

    func cleanSnapshot(snapshotId: String) async throws {
        self.snapshotInfos.removeValue(forKey: snapshotId)
    }

    func cleanSnapshotsOlderThan(days _: Int) async throws -> Int {
        0
    }

    func cleanAllSnapshots() async throws -> Int {
        let count = self.snapshotInfos.count
        self.snapshotInfos.removeAll()
        self.watermark = nil
        return count
    }

    func getSnapshotStoragePath() -> String {
        "/tmp/peekaboo-unavailable-error-stub"
    }

    func storeScreenshot(_: SnapshotScreenshotRequest) async throws {}

    func storeAnnotatedScreenshot(snapshotId _: String, annotatedScreenshotPath _: String) async throws {}

    func getElement(snapshotId _: String, elementId _: String) async throws -> UIElement? {
        nil
    }

    func findElements(snapshotId _: String, matching _: String) async throws -> [UIElement] {
        []
    }

    func getUIAutomationSnapshot(snapshotId _: String) async throws -> UIAutomationSnapshot? {
        nil
    }
}
