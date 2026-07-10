import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

/// Regression tests for snapshot invalidation after FAILED commands.
///
/// Previously, any failure after `beginInteractionMutation()` advanced the invalidation watermark
/// to "now", retroactively hiding every cached snapshot and turning follow-up commands into a
/// misleading "Snapshot not found or expired: No snapshot found".
@Suite(.tags(.safe))
@MainActor
struct SnapshotFailureInvalidationTests {
    @Test
    func `Failure before any desktop event keeps the latest snapshot resolvable`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let latest = try await fixture.snapshots.createSnapshot(id: "latest")
        let sequenceAtStart = fixture.tracker.mutationSequence
        let createdDurableMutation = try fixture.tracker.beginDurableMutation()
        fixture.tracker.begin()

        let invalidated = await CommanderRuntimeExecutor.invalidateSnapshotsAfterCommandIfNeeded(
            dependencies: fixture.dependencies,
            required: true,
            succeeded: false,
            failure: PeekabooError.elementNotFound("Element 'Save' not found"),
            mutationSequenceAtStart: sequenceAtStart,
            createdDurableMutation: createdDurableMutation
        )

        #expect(invalidated)
        #expect(fixture.snapshots.invalidationCutoffs.isEmpty)
        #expect(await fixture.snapshots.getMostRecentSnapshot() == latest)
        #expect(!fixture.tracker.hasPendingDurableMutation)
        #expect(fixture.store.effectiveWatermark() == nil)
    }

    @Test
    func `Ambiguous failure such as a timeout still invalidates snapshots`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.snapshots.createSnapshot(id: "latest")
        let sequenceAtStart = fixture.tracker.mutationSequence
        let createdDurableMutation = try fixture.tracker.beginDurableMutation()
        fixture.tracker.begin()

        let invalidated = await CommanderRuntimeExecutor.invalidateSnapshotsAfterCommandIfNeeded(
            dependencies: fixture.dependencies,
            required: true,
            succeeded: false,
            failure: PeekabooError.timeout("clicking 'Save'"),
            mutationSequenceAtStart: sequenceAtStart,
            createdDurableMutation: createdDurableMutation
        )

        #expect(invalidated)
        #expect(fixture.snapshots.invalidationCutoffs.count == 1)
        #expect(await fixture.snapshots.getMostRecentSnapshot() == nil)
        #expect(fixture.store.effectiveWatermark() != nil)
    }

    @Test
    func `Post-dispatch menu lookup failure still invalidates (dock right-click shape)`() async throws {
        // `dock right-click --select` clicks the item, opens the context menu, then throws
        // menuNotFound. Even within a single mutation boundary this MUST invalidate, because the
        // menu is now open on screen -- so `.menuNotFound` is not classified pre-dispatch.
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.snapshots.createSnapshot(id: "latest")
        let sequenceAtStart = fixture.tracker.mutationSequence
        let createdDurableMutation = try fixture.tracker.beginDurableMutation()
        fixture.tracker.begin()

        let invalidated = await CommanderRuntimeExecutor.invalidateSnapshotsAfterCommandIfNeeded(
            dependencies: fixture.dependencies,
            required: true,
            succeeded: false,
            failure: PeekabooError.menuNotFound("New Finder Window"),
            mutationSequenceAtStart: sequenceAtStart,
            createdDurableMutation: createdDurableMutation
        )

        #expect(invalidated)
        #expect(fixture.snapshots.invalidationCutoffs.count == 1)
        #expect(await fixture.snapshots.getMostRecentSnapshot() == nil)
        #expect(fixture.store.effectiveWatermark() != nil)
    }

    @Test
    func `Lookup failure after an earlier mutation boundary still invalidates`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.snapshots.createSnapshot(id: "latest")
        let sequenceAtStart = fixture.tracker.mutationSequence
        let createdDurableMutation = try fixture.tracker.beginDurableMutation()
        // Two boundaries: e.g. a focus change dispatched before the failing element lookup.
        fixture.tracker.begin()
        fixture.tracker.begin()

        let invalidated = await CommanderRuntimeExecutor.invalidateSnapshotsAfterCommandIfNeeded(
            dependencies: fixture.dependencies,
            required: true,
            succeeded: false,
            failure: PeekabooError.elementNotFound("Element 'Save' not found"),
            mutationSequenceAtStart: sequenceAtStart,
            createdDurableMutation: createdDurableMutation
        )

        #expect(invalidated)
        #expect(fixture.snapshots.invalidationCutoffs.count == 1)
        #expect(await fixture.snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Failure bypass never applies after a failed invalidation attempt`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sequenceAtStart = fixture.tracker.mutationSequence
        fixture.tracker.begin()
        fixture.tracker.markInvalidationFailed(through: Date())

        let bypasses = CommanderRuntimeExecutor.failureBypassesSnapshotInvalidation(
            failure: PeekabooError.elementNotFound("Element 'Save' not found"),
            tracker: fixture.tracker,
            mutationSequenceAtStart: sequenceAtStart
        )

        #expect(!bypasses)
    }

    @Test
    func `Never-captured snapshot resolves to an actionable snapshotNotAvailable error`() async throws {
        let snapshots = InvalidationRecordingSnapshotManagerStub()

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
        let snapshots = InvalidationRecordingSnapshotManagerStub()
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

    @MainActor
    private struct Fixture {
        let root: URL
        let store: DesktopMutationWatermarkStore
        let tracker: InteractionMutationTracker
        let snapshots: InvalidationRecordingSnapshotManagerStub
        let dependencies: CommanderRuntimeExecutor.SnapshotInvalidationDependencies

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("peekaboo-failure-invalidation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            self.store = DesktopMutationWatermarkStore(directoryURL: self.root)
            self.tracker = InteractionMutationTracker(desktopMutationWatermarkStore: self.store)
            self.snapshots = InvalidationRecordingSnapshotManagerStub()
            self.dependencies = CommanderRuntimeExecutor.SnapshotInvalidationDependencies(
                tracker: self.tracker,
                targets: .init(
                    snapshots: self.snapshots,
                    selectedRemoteSocketPath: nil,
                    remoteSocketPaths: [],
                    mutationTracker: self.tracker
                ),
                logger: Logger.shared
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}

/// Minimal in-memory snapshot manager that records invalidation cutoffs and mirrors the real
/// manager's watermark semantics for implicit latest-snapshot lookup.
@MainActor
private final class InvalidationRecordingSnapshotManagerStub: SnapshotManagerProtocol {
    nonisolated let supportsImplicitLatestSnapshotInvalidation = true
    private var snapshotInfos: [String: SnapshotInfo] = [:]
    private var watermark: Date?
    private(set) var invalidationCutoffs: [Date] = []

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
        self.invalidationCutoffs.append(cutoff)
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
        "/tmp/peekaboo-failure-invalidation-stub"
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
