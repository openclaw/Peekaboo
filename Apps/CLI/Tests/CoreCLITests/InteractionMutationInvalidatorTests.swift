import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized)
@MainActor
struct InteractionMutationInvalidatorTests {
    @Test
    func `Bridge timeout retries once with a longer budget`() async throws {
        var attemptedTimeouts: [TimeInterval] = []

        let result: String = try await InteractionObservationInvalidator.retryBridgeTimeout { timeoutSec in
            attemptedTimeouts.append(timeoutSec)
            if attemptedTimeouts.count == 1 {
                throw POSIXError(.ETIMEDOUT)
            }
            return "connected"
        }

        #expect(result == "connected")
        #expect(attemptedTimeouts == [1, 2])
    }

    @Test
    func `Mutation invalidates all hosts while preserving explicit snapshots`() async throws {
        let selectedSnapshots = InMemorySnapshotManager()
        let alternateSnapshots = InMemorySnapshotManager()
        let explicitSnapshot = try await selectedSnapshots.createSnapshot()
        let selectedLatest = try await selectedSnapshots.createSnapshot()
        let alternateLatest = try await alternateSnapshots.createSnapshot()
        let explicitObservation = await InteractionObservationContext.resolve(
            explicitSnapshot: explicitSnapshot,
            fallbackToLatest: true,
            snapshots: selectedSnapshots
        )
        let cutoff = Date()

        await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: .init(
                snapshots: selectedSnapshots,
                selectedRemoteSocketPath: nil,
                remoteSocketPaths: ["/tmp/alternate.sock"],
                socketExists: { _ in true },
                makeRemoteSnapshotManager: { _ in alternateSnapshots }
            ),
            logger: Logger.shared,
            reason: "test sibling mutation",
            through: cutoff
        )

        #expect(await selectedSnapshots.getMostRecentSnapshot() == nil)
        #expect(await alternateSnapshots.getMostRecentSnapshot() == nil)
        #expect(explicitObservation.source == .explicit)
        #expect(explicitObservation.snapshotId == explicitSnapshot)
        #expect(try await Set(selectedSnapshots.listSnapshots().map(\.id)) == [
            explicitSnapshot,
            selectedLatest,
        ])
        #expect(try await Set(alternateSnapshots.listSnapshots().map(\.id)) == [alternateLatest])

        let selectedFresh = try await selectedSnapshots.createSnapshot()
        let alternateFresh = try await alternateSnapshots.createSnapshot()
        #expect(await selectedSnapshots.getMostRecentSnapshot() == selectedFresh)
        #expect(await alternateSnapshots.getMostRecentSnapshot() == alternateFresh)
    }

    @Test
    func `Sibling mutation uses selected remote plus local and discovered alternate hosts`() async throws {
        let selectedRemoteSnapshots = InMemorySnapshotManager()
        let localSnapshots = InMemorySnapshotManager()
        let alternateRemoteSnapshots = InMemorySnapshotManager()
        let selectedLatest = try await selectedRemoteSnapshots.createSnapshot()
        let localLatest = try await localSnapshots.createSnapshot()
        let alternateLatest = try await alternateRemoteSnapshots.createSnapshot()

        await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: .init(
                snapshots: selectedRemoteSnapshots,
                selectedRemoteSocketPath: "/tmp/selected.sock",
                remoteSocketPaths: ["/tmp/selected.sock", "/tmp/alternate.sock"],
                socketExists: { _ in true },
                makeLocalSnapshotManager: { localSnapshots },
                makeRemoteSnapshotManager: { _ in alternateRemoteSnapshots }
            ),
            logger: Logger.shared,
            reason: "test remote sibling mutation"
        )

        #expect(await selectedRemoteSnapshots.getMostRecentSnapshot() == nil)
        #expect(await localSnapshots.getMostRecentSnapshot() == nil)
        #expect(await alternateRemoteSnapshots.getMostRecentSnapshot() == nil)
        #expect(try await selectedRemoteSnapshots.listSnapshots().map(\.id) == [selectedLatest])
        #expect(try await localSnapshots.listSnapshots().map(\.id) == [localLatest])
        #expect(try await alternateRemoteSnapshots.listSnapshots().map(\.id) == [alternateLatest])
    }

    @Test
    func `Required hosts invalidate before alternate endpoint discovery`() async throws {
        let selectedRemoteSnapshots = InMemorySnapshotManager()
        let localSnapshots = InMemorySnapshotManager()
        let alternateRemoteSnapshots = InMemorySnapshotManager()
        _ = try await selectedRemoteSnapshots.createSnapshot()
        _ = try await localSnapshots.createSnapshot()
        _ = try await alternateRemoteSnapshots.createSnapshot()
        var requiredHostsWereInvalidated = false

        let succeeded = await InteractionObservationInvalidator.invalidateLatestSnapshotsAcrossKnownHosts(
            using: selectedRemoteSnapshots,
            selectedRemoteSocketPath: "/tmp/selected.sock",
            remoteSocketPaths: ["/tmp/alternate.sock"],
            logger: Logger.shared,
            reason: "test invalidation ordering",
            socketExists: { _ in true },
            makeLocalSnapshotManager: { localSnapshots },
            makeRemoteSnapshotManager: { _ in
                let selectedLatest = await selectedRemoteSnapshots.getMostRecentSnapshot()
                let localLatest = await localSnapshots.getMostRecentSnapshot()
                requiredHostsWereInvalidated = selectedLatest == nil && localLatest == nil
                return alternateRemoteSnapshots
            }
        )

        #expect(succeeded)
        #expect(requiredHostsWereInvalidated)
        #expect(await alternateRemoteSnapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Command wrapper uses completion cutoff unless success preserves a fresh observation`() async throws {
        let snapshots = InMemorySnapshotManager()
        let original = try await snapshots.createSnapshot()
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: snapshots)
        )

        await #expect(throws: TestCommandError.self) {
            try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
                using: runtime,
                required: true
            ) { () async throws in
                throw TestCommandError.failedBeforeMutation
            }
        }
        #expect(await snapshots.getMostRecentSnapshot() == original)

        var failedMutationSnapshot: String?
        await #expect(throws: TestCommandError.self) {
            try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
                using: runtime,
                required: true
            ) { () async throws in
                runtime.beginInteractionMutation()
                failedMutationSnapshot = try await snapshots.createSnapshot()
                throw TestCommandError.failedAfterMutation
            }
        }
        #expect(failedMutationSnapshot != nil)
        #expect(await snapshots.getMostRecentSnapshot() == nil)

        _ = try await snapshots.createSnapshot()
        var concurrentSnapshot: String?
        try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
            using: runtime,
            required: true
        ) {
            runtime.beginInteractionMutation()
            concurrentSnapshot = try await snapshots.createSnapshot()
        }
        #expect(concurrentSnapshot != nil)
        #expect(await snapshots.getMostRecentSnapshot() == nil)

        _ = try await snapshots.createSnapshot()
        var freshObservation: String?
        try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
            using: runtime,
            required: true
        ) {
            runtime.beginInteractionMutation(preservingSnapshotsCreatedAfterBoundary: true)
            freshObservation = try await snapshots.createSnapshot()
        }
        #expect(await snapshots.getMostRecentSnapshot() == freshObservation)
    }

    @Test
    func `Local command installs durable barrier before mutation dispatch`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-command-barrier-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
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
        let started = AsyncTestGate()
        let release = AsyncTestGate()
        let command = Task { @MainActor in
            try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
                using: runtime,
                required: true
            ) {
                runtime.beginInteractionMutation()
                await started.open()
                await release.wait()
            }
        }

        await started.wait()
        let firstPendingRead = try #require(store.effectiveWatermark())
        try await Task.sleep(for: .milliseconds(2))
        #expect(try #require(store.effectiveWatermark()) > firstPendingRead)
        let interimSnapshotID = try await snapshots.createSnapshot()
        #expect(await snapshots.getMostRecentSnapshot() == nil)

        await release.open()
        try await command.value
        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(try await snapshots.getUIAutomationSnapshot(snapshotId: interimSnapshotID) != nil)
    }

    @Test
    func `Local command can resolve its own pre-mutation implicit latest snapshot`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-visible-barrier-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let snapshots = InMemorySnapshotManager(
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
        let original = try await snapshots.createSnapshot()
        var resolvedSnapshotID: String?

        try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
            using: runtime,
            required: true
        ) {
            resolvedSnapshotID = await snapshots.getMostRecentSnapshot()
            runtime.beginInteractionMutation()
        }

        #expect(resolvedSnapshotID == original)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Remote-selected local mutation installs a caller barrier`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-remote-caller-barrier-\(UUID().uuidString)", isDirectory: true)
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
            selectedRemoteSocketPath: "/tmp/selected.sock",
            interactionMutationTracker: tracker
        )
        let started = AsyncTestGate()
        let release = AsyncTestGate()
        let command = Task { @MainActor in
            try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
                using: runtime,
                required: true,
                requiresCallerBarrier: true
            ) {
                runtime.beginInteractionMutation()
                await started.open()
                await release.wait()
            }
        }

        await started.wait()
        #expect(store.effectiveWatermark() != nil)
        await release.open()
        try await command.value
        #expect(!tracker.hasPendingDurableMutation)
    }

    @Test
    func `Per-tool coordinator closes its local barrier before fresh observation publication`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-tool-barrier-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
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
        let scope = MCPToolSnapshotMutationScope(
            toolName: "inspect_ui",
            effect: .mutationProducingFreshObservation
        )

        try coordinator.prepareMutation(scope)
        let firstPendingRead = try #require(store.effectiveWatermark())
        try await Task.sleep(for: .milliseconds(2))
        #expect(try #require(store.effectiveWatermark()) > firstPendingRead)

        let completedScope = scope.completed(at: Date(), preserving: nil)
        let barrierResult = try coordinator.completeMutationBarrier(completedScope)
        let barrier = try #require(barrierResult)
        #expect(barrier.allowsObservationPreservation)
        let resolvedScope = completedScope.completed(
            at: completedScope.completedAt ?? Date(),
            preserving: nil,
            confirmedMutationCompletedAt: barrier.cutoff,
            observationPreservationAllowed: barrier.allowsObservationPreservation
        )
        #expect(await coordinator.completeMutation(resolvedScope, succeeded: true))
    }

    @Test
    func `Remote ordinary tools retain a caller barrier while remote observations use host certificate`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-remote-tool-barrier-\(UUID().uuidString)", isDirectory: true)
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
            selectedRemoteSocketPath: "/tmp/selected.sock",
            interactionMutationTracker: tracker
        )
        let coordinator = runtime.toolSnapshotMutationCoordinator
        let mutation = MCPToolSnapshotMutationScope(toolName: "shell", effect: .mutation)

        try coordinator.prepareMutation(mutation)
        #expect(store.effectiveWatermark() != nil)
        let completedMutation = mutation.completed(at: Date(), preserving: nil)
        #expect(try coordinator.completeMutationBarrier(completedMutation) != nil)

        let observation = MCPToolSnapshotMutationScope(
            toolName: "see",
            effect: .mutationProducingFreshObservation
        )
        try coordinator.prepareMutation(observation)
        #expect(try coordinator.completeMutationBarrier(observation.completed(at: Date(), preserving: nil)) == nil)
    }

    @Test
    func `Observation timeouts borrow only local or existing caller barriers`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-timeout-barrier-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let localTracker = InteractionMutationTracker(
            desktopMutationWatermarkStore: DesktopMutationWatermarkStore(directoryURL: root)
        )
        let localRuntime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: InMemorySnapshotManager()),
            interactionMutationTracker: localTracker
        )
        #expect(localRuntime.observationTimeoutMutationTracker === localTracker)

        let remoteTracker = InteractionMutationTracker(
            desktopMutationWatermarkStore: DesktopMutationWatermarkStore(directoryURL: root)
        )
        let remoteRuntime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: InMemorySnapshotManager()),
            selectedRemoteSocketPath: "/tmp/selected.sock",
            interactionMutationTracker: remoteTracker
        )
        #expect(remoteRuntime.observationTimeoutMutationTracker == nil)

        #expect(try remoteTracker.beginDurableMutation())
        #expect(remoteRuntime.observationTimeoutMutationTracker === remoteTracker)
        try remoteTracker.cancelDurableMutation()
    }

    @Test
    func `Remote coordinator rejects a host observation certificate that forbids preservation`() async throws {
        let snapshots = InMemorySnapshotManager()
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: snapshots),
            selectedRemoteSocketPath: "/tmp/selected.sock"
        )
        let snapshotID = try await snapshots.createSnapshot()
        let scope = MCPToolSnapshotMutationScope(
            toolName: "see",
            startedAt: Date(),
            effect: .mutationProducingFreshObservation
        ).completed(
            at: Date(),
            preserving: snapshotID,
            confirmedMutationCompletedAt: Date(),
            observationPreservationAllowed: false
        )

        let published = await runtime.toolSnapshotMutationCoordinator.completeMutation(scope, succeeded: true)
        #expect(!published)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Command wrapper retries failed invalidation with the original cutoff`() async throws {
        let snapshots = RetrySnapshotManager()
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: snapshots)
        )

        let result = try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
            using: runtime,
            required: true
        ) {
            runtime.beginInteractionMutation()
            _ = try await snapshots.createSnapshot()
            return 42
        }

        #expect(result == 42)
        #expect(snapshots.invalidationCalls == 2)
        #expect(snapshots.invalidationCutoffs.count == 2)
        #expect(snapshots.invalidationCutoffs.first == snapshots.invalidationCutoffs.last)
        #expect(runtime.interactionMutationTracker.mutationStartedAt == nil)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Successful command remains successful when snapshot invalidation fails twice`() async throws {
        let snapshots = RetrySnapshotManager(firstInvalidationAction: .alwaysFail)
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: snapshots)
        )

        try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
            using: runtime,
            required: true
        ) {
            runtime.beginInteractionMutation()
            _ = try await snapshots.createSnapshot()
        }

        #expect(snapshots.invalidationCalls == 2)
        #expect(runtime.interactionMutationTracker.mutationStartedAt != nil)
    }

    @Test
    func `Existing failed barrier is completed rather than canceled by a no-op retry`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-existing-barrier-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let tracker = InteractionMutationTracker(desktopMutationWatermarkStore: store)
        let snapshots = RetrySnapshotManager(firstInvalidationAction: .alwaysFail)
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
        #expect(try tracker.beginDurableMutation())
        let mutationCutoff = tracker.begin()
        tracker.markInvalidationFailed(through: mutationCutoff)

        try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
            using: runtime,
            required: true
        ) {}

        #expect(!tracker.hasPendingDurableMutation)
        #expect(try #require(store.effectiveWatermark()) >= mutationCutoff)
    }

    @Test
    func `Command wrapper makes one retry after direct invalidation failure`() async throws {
        let snapshots = RetrySnapshotManager(firstInvalidationAction: .alwaysFail)
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: snapshots)
        )
        runtime.beginInteractionMutation()
        let cutoff = Date()

        let directInvalidationSucceeded = await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: runtime.interactionMutationTargets,
            logger: runtime.logger,
            reason: "test direct invalidation",
            through: cutoff
        )
        #expect(!directInvalidationSucceeded)

        let result = try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
            using: runtime,
            required: true
        ) {
            42
        }

        #expect(result == 42)
        #expect(snapshots.invalidationCalls == 2)
        #expect(snapshots.invalidationCutoffs == [cutoff, cutoff])
        #expect(runtime.interactionMutationTracker.mutationStartedAt != nil)
    }

    @Test
    func `Operation failure remains primary when snapshot cleanup fails twice`() async throws {
        let snapshots = RetrySnapshotManager(firstInvalidationAction: .alwaysFail)
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: snapshots)
        )

        await #expect(throws: TestCommandError.self) {
            try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
                using: runtime,
                required: true
            ) {
                runtime.beginInteractionMutation()
                throw TestCommandError.failedAfterMutation
            }
        }

        #expect(snapshots.invalidationCalls == 2)
        #expect(runtime.interactionMutationTracker.mutationStartedAt != nil)
    }

    @Test
    func `Successful capture focus preserves snapshots created after focus completion`() async throws {
        let snapshots = InMemorySnapshotManager()
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: snapshots)
        )
        var freshSnapshot: String?

        try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
            using: runtime,
            required: true
        ) {
            await runtime.withCaptureFocusMutation {}
            try await Task.sleep(for: .milliseconds(1))
            freshSnapshot = try await snapshots.createSnapshot()
        }

        #expect(await snapshots.getMostRecentSnapshot() == freshSnapshot)
    }

    @Test
    func `Failed capture focus invalidates snapshots through command completion`() async throws {
        let snapshots = InMemorySnapshotManager()
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: snapshots)
        )
        var focusSnapshot: String?

        await #expect(throws: TestCommandError.self) {
            try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
                using: runtime,
                required: true
            ) {
                try await runtime.withCaptureFocusMutation {
                    focusSnapshot = try await snapshots.createSnapshot()
                    throw TestCommandError.focusFailed
                }
            }
        }

        #expect(focusSnapshot != nil)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Action mutation reopens a completed capture focus boundary`() async throws {
        let snapshots = InMemorySnapshotManager()
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: snapshots)
        )

        try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
            using: runtime,
            required: true
        ) {
            await runtime.withCaptureFocusMutation {}
            runtime.beginInteractionMutation()
            _ = try await snapshots.createSnapshot()
        }

        #expect(await snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Command cancellation invalidates snapshots after a completed focus boundary`() async throws {
        let snapshots = InMemorySnapshotManager()
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: snapshots)
        )

        let task = Task { @MainActor in
            try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
                using: runtime,
                required: true
            ) {
                await runtime.withCaptureFocusMutation {}
                try await Task.sleep(for: .milliseconds(1))
                _ = try await snapshots.createSnapshot()
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Cancellation during success cleanup forces completion invalidation`() async throws {
        let snapshots = RetrySnapshotManager(firstInvalidationAction: .cancelAfterSuccess)
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: snapshots)
        )

        let task = Task { @MainActor in
            try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
                using: runtime,
                required: true
            ) {
                await runtime.withCaptureFocusMutation {}
                try await Task.sleep(for: .milliseconds(1))
                _ = try await snapshots.createSnapshot()
            }
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(snapshots.invalidationCalls == 2)
        #expect(snapshots.invalidationCutoffs[0] < snapshots.invalidationCutoffs[1])
        #expect(await snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Failed invalidation retries the original cutoff and preserves fresh observations`() async throws {
        let snapshots = RetrySnapshotManager()
        let tracker = InteractionMutationTracker()
        _ = try await snapshots.createSnapshot()
        tracker.begin()
        let targets = InteractionObservationInvalidator.MutationTargets(
            snapshots: snapshots,
            selectedRemoteSocketPath: nil,
            remoteSocketPaths: [],
            mutationTracker: tracker
        )

        let attemptedCutoff = Date()
        let firstSucceeded = await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: targets,
            logger: Logger.shared,
            reason: "test retry",
            through: attemptedCutoff
        )
        #expect(!firstSucceeded)
        #expect(tracker.mutationStartedAt != nil)

        let freshSnapshot = try await snapshots.createSnapshot()
        let retryCutoff = try #require(tracker.invalidationCutoff(
            commandCompletedAt: Date(),
            succeeded: true
        ))
        #expect(retryCutoff == attemptedCutoff)

        let retrySucceeded = await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: targets,
            logger: Logger.shared,
            reason: "test retry",
            through: retryCutoff
        )
        #expect(retrySucceeded)
        #expect(tracker.mutationStartedAt == nil)
        #expect(snapshots.invalidationCalls == 2)
        #expect(snapshots.invalidationCutoffs == [attemptedCutoff, attemptedCutoff])
        #expect(await snapshots.getMostRecentSnapshot() == freshSnapshot)
    }

    @Test
    func `Unavailable alternate endpoint is best effort while unsupported endpoint is ignored`() async throws {
        let localSnapshots = InMemorySnapshotManager()
        let remoteSnapshots = InMemorySnapshotManager()
        let tracker = InteractionMutationTracker()
        _ = try await localSnapshots.createSnapshot()
        let remoteLatest = try await remoteSnapshots.createSnapshot()
        tracker.begin()
        var probeAttempts = 0
        let targets = InteractionObservationInvalidator.MutationTargets(
            snapshots: localSnapshots,
            selectedRemoteSocketPath: nil,
            remoteSocketPaths: ["/tmp/transient.sock"],
            socketExists: { _ in true },
            makeRemoteSnapshotManager: { _ in
                probeAttempts += 1
                if probeAttempts == 1 {
                    throw TestCommandError.invalidationFailed
                }
                return remoteSnapshots
            },
            mutationTracker: tracker
        )
        let succeeded = await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: targets,
            logger: Logger.shared,
            reason: "test failed probe"
        )

        #expect(succeeded)
        #expect(tracker.mutationStartedAt == nil)
        #expect(probeAttempts == 1)
        #expect(await remoteSnapshots.getMostRecentSnapshot() == remoteLatest)

        let unsupportedSucceeded = await InteractionObservationInvalidator.invalidateLatestSnapshotsAcrossKnownHosts(
            using: InMemorySnapshotManager(),
            selectedRemoteSocketPath: nil,
            remoteSocketPaths: ["/tmp/legacy.sock"],
            logger: Logger.shared,
            reason: "test unsupported endpoint",
            socketExists: { _ in true },
            makeRemoteSnapshotManager: { _ in nil }
        )
        #expect(unsupportedSucceeded)
    }

    @Test
    func `Stale remote socket files do not fail invalidation`() async throws {
        let snapshots = InMemorySnapshotManager()
        let tracker = InteractionMutationTracker()
        _ = try await snapshots.createSnapshot()
        tracker.begin()
        var probedPaths: [String] = []
        let targets = InteractionObservationInvalidator.MutationTargets(
            snapshots: snapshots,
            selectedRemoteSocketPath: nil,
            remoteSocketPaths: [
                "/tmp/refused.sock",
                "/tmp/missing.sock",
                "/tmp/not-a-socket.sock",
            ],
            socketExists: { _ in true },
            makeRemoteSnapshotManager: { path in
                probedPaths.append(path)
                switch path {
                case "/tmp/refused.sock":
                    throw POSIXError(.ECONNREFUSED)
                case "/tmp/missing.sock":
                    throw POSIXError(.ENOENT)
                default:
                    throw POSIXError(.ENOTSOCK)
                }
            },
            mutationTracker: tracker
        )

        let succeeded = await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: targets,
            logger: Logger.shared,
            reason: "test stale sockets"
        )

        #expect(succeeded)
        #expect(probedPaths == [
            "/tmp/refused.sock",
            "/tmp/missing.sock",
            "/tmp/not-a-socket.sock",
        ])
        #expect(tracker.mutationStartedAt == nil)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Live alternate endpoint probe failures do not poison selected invalidation`() async throws {
        let snapshots = InMemorySnapshotManager()
        let tracker = InteractionMutationTracker()
        _ = try await snapshots.createSnapshot()
        tracker.begin()
        let targets = InteractionObservationInvalidator.MutationTargets(
            snapshots: snapshots,
            selectedRemoteSocketPath: nil,
            remoteSocketPaths: ["/tmp/live.sock"],
            socketExists: { _ in true },
            makeRemoteSnapshotManager: { _ in
                throw POSIXError(.ETIMEDOUT)
            },
            mutationTracker: tracker
        )

        let succeeded = await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: targets,
            logger: Logger.shared,
            reason: "test live endpoint failure"
        )

        #expect(succeeded)
        #expect(tracker.mutationStartedAt == nil)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Alternate endpoint invalidation failures do not poison selected invalidation`() async throws {
        let selectedSnapshots = InMemorySnapshotManager()
        let alternateSnapshots = RetrySnapshotManager(firstInvalidationAction: .alwaysFail)
        let tracker = InteractionMutationTracker()
        _ = try await selectedSnapshots.createSnapshot()
        tracker.begin()
        let targets = InteractionObservationInvalidator.MutationTargets(
            snapshots: selectedSnapshots,
            selectedRemoteSocketPath: nil,
            remoteSocketPaths: ["/tmp/live.sock"],
            socketExists: { _ in true },
            makeRemoteSnapshotManager: { _ in alternateSnapshots },
            mutationTracker: tracker
        )

        let succeeded = await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: targets,
            logger: Logger.shared,
            reason: "test alternate invalidation failure"
        )

        #expect(succeeded)
        #expect(tracker.mutationStartedAt == nil)
        #expect(alternateSnapshots.invalidationCalls == 1)
        #expect(await selectedSnapshots.getMostRecentSnapshot() == nil)
    }
}

private enum TestCommandError: Error {
    case failedBeforeMutation
    case failedAfterMutation
    case focusFailed
    case invalidationFailed
}

private enum SnapshotInvalidationTestError: Error {
    case failed
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func open() {
        guard !self.isOpen else { return }
        self.isOpen = true
        self.waiters.forEach { $0.resume() }
        self.waiters.removeAll()
    }
}

@MainActor
private final class RetrySnapshotManager: SnapshotManagerProtocol {
    enum FirstInvalidationAction: Equatable {
        case fail
        case alwaysFail
        case cancelAfterSuccess
    }

    let supportsImplicitLatestSnapshotInvalidation = true
    private let backing = InMemorySnapshotManager()
    private let firstInvalidationAction: FirstInvalidationAction
    private(set) var invalidationCalls = 0
    private(set) var invalidationCutoffs: [Date] = []

    init(firstInvalidationAction: FirstInvalidationAction = .fail) {
        self.firstInvalidationAction = firstInvalidationAction
    }

    func invalidateImplicitLatestSnapshot(through cutoff: Date) async throws -> String? {
        self.invalidationCalls += 1
        self.invalidationCutoffs.append(cutoff)
        if self.firstInvalidationAction == .alwaysFail ||
            (self.invalidationCalls == 1 && self.firstInvalidationAction == .fail) {
            throw SnapshotInvalidationTestError.failed
        }
        let invalidatedSnapshot = try await backing.invalidateImplicitLatestSnapshot(through: cutoff)
        if self.invalidationCalls == 1, self.firstInvalidationAction == .cancelAfterSuccess {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return invalidatedSnapshot
    }

    func createSnapshot() async throws -> String {
        try await self.backing.createSnapshot()
    }

    func storeDetectionResult(snapshotId: String, result: ElementDetectionResult) async throws {
        try await self.backing.storeDetectionResult(snapshotId: snapshotId, result: result)
    }

    func getDetectionResult(snapshotId: String) async throws -> ElementDetectionResult? {
        try await self.backing.getDetectionResult(snapshotId: snapshotId)
    }

    func getMostRecentSnapshot() async -> String? {
        await self.backing.getMostRecentSnapshot()
    }

    func getMostRecentSnapshot(applicationBundleId: String) async -> String? {
        await self.backing.getMostRecentSnapshot(applicationBundleId: applicationBundleId)
    }

    func listSnapshots() async throws -> [SnapshotInfo] {
        try await self.backing.listSnapshots()
    }

    func cleanSnapshot(snapshotId _: String) async throws {
        fatalError("unused")
    }

    func cleanSnapshotsOlderThan(days _: Int) async throws -> Int {
        fatalError("unused")
    }

    func cleanAllSnapshots() async throws -> Int {
        fatalError("unused")
    }

    func getSnapshotStoragePath() -> String {
        fatalError("unused")
    }

    func storeScreenshot(_: SnapshotScreenshotRequest) async throws {
        fatalError("unused")
    }

    func storeAnnotatedScreenshot(snapshotId _: String, annotatedScreenshotPath _: String) async throws {
        fatalError("unused")
    }

    func getElement(snapshotId _: String, elementId _: String) async throws -> UIElement? {
        fatalError("unused")
    }

    func findElements(snapshotId _: String, matching _: String) async throws -> [UIElement] {
        fatalError("unused")
    }

    func getUIAutomationSnapshot(snapshotId _: String) async throws -> UIAutomationSnapshot? {
        fatalError("unused")
    }
}
