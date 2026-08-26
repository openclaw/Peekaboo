import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized)
@MainActor
struct BrowserMutationLaneInvalidatorTests {
    @Test
    func `Concurrent browser lanes share a durable cross process barrier`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-browser-lanes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let externalSnapshots = InMemorySnapshotManager(
            desktopMutationWatermarkStore: DesktopMutationWatermarkStore(directoryURL: root)
        )
        let tracker = InteractionMutationTracker(desktopMutationWatermarkStore: store)
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: snapshots),
            interactionMutationTracker: tracker
        )
        let coordinator = runtime.toolSnapshotMutationCoordinator
        let first = MCPToolSnapshotMutationScope(toolName: "browser", effect: .mutation)
        let second = MCPToolSnapshotMutationScope(toolName: "browser", effect: .mutation)
        _ = try await snapshots.createSnapshot()
        _ = try await externalSnapshots.createSnapshot()

        try coordinator.prepareConcurrentMutation(first)
        try coordinator.prepareConcurrentMutation(second)
        #expect(tracker.hasPendingDurableMutation)
        #expect(store.effectiveWatermark() != nil)
        #expect(await externalSnapshots.getMostRecentSnapshot() == nil)

        let completedFirst = first.completed(at: Date(), preserving: nil)
        let firstCompletion = try coordinator.completeMutationBarrier(completedFirst)
        let firstBarrier = try #require(firstCompletion)
        #expect(!firstBarrier.allowsObservationPreservation)
        #expect(await coordinator.completeMutation(completedFirst, succeeded: true))
        #expect(tracker.hasPendingDurableMutation)
        #expect(store.effectiveWatermark() != nil)
        let completedSecond = second.completed(at: Date(), preserving: nil)
        let secondCompletion = try coordinator.completeMutationBarrier(completedSecond)
        _ = try #require(secondCompletion)
        #expect(await coordinator.completeMutation(completedSecond, succeeded: true))
        #expect(!tracker.hasPendingDurableMutation)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Completed browser mutation stays durable when its peer cancels`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-browser-complete-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let tracker = InteractionMutationTracker(desktopMutationWatermarkStore: store)
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: InMemorySnapshotManager()),
            interactionMutationTracker: tracker
        )
        let coordinator = runtime.toolSnapshotMutationCoordinator
        let completed = MCPToolSnapshotMutationScope(toolName: "browser", effect: .mutation)
        let refused = MCPToolSnapshotMutationScope(toolName: "browser", effect: .mutation)

        try coordinator.prepareConcurrentMutation(completed)
        try coordinator.prepareConcurrentMutation(refused)
        let completionScope = completed.completed(at: Date(), preserving: nil)
        let barrierCompletion = try coordinator.completeMutationBarrier(completionScope)
        let completedBarrier = try #require(barrierCompletion)
        #expect(await coordinator.completeMutation(completionScope, succeeded: true))

        #expect(await coordinator.cancelMutation(refused))
        #expect(!tracker.hasPendingDurableMutation)
        #expect(try #require(store.effectiveWatermark()) >= completedBarrier.cutoff)
    }

    @Test
    func `Overlapping browser refusals cancel their shared uncommitted boundary`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-browser-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let tracker = InteractionMutationTracker(desktopMutationWatermarkStore: store)
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: InMemorySnapshotManager()),
            interactionMutationTracker: tracker
        )
        let coordinator = runtime.toolSnapshotMutationCoordinator
        let first = MCPToolSnapshotMutationScope(toolName: "browser", effect: .mutation)
        let second = MCPToolSnapshotMutationScope(toolName: "browser", effect: .mutation)

        try coordinator.prepareConcurrentMutation(first)
        try coordinator.prepareConcurrentMutation(second)
        #expect(tracker.mutationStartedAt != nil)
        #expect(tracker.hasPendingDurableMutation)

        #expect(await coordinator.cancelMutation(second))
        #expect(tracker.mutationStartedAt != nil)
        #expect(tracker.hasPendingDurableMutation)
        #expect(await coordinator.cancelMutation(first))
        #expect(tracker.mutationStartedAt == nil)
        #expect(!tracker.hasPendingDurableMutation)
        #expect(store.effectiveWatermark() == nil)
    }
}
