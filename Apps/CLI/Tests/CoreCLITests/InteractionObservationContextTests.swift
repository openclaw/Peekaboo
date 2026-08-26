import Commander
import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooCore
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct InteractionObservationContextTests {
    @Test
    func `Explicit canonical snapshot wins over latest`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let latest = try await snapshots.createSnapshot()
        let explicit = SnapshotReferenceFixtures.first.rawValue

        let context = await InteractionObservationContext.resolve(
            explicitSnapshot: explicit,
            fallbackToLatest: true,
            snapshots: snapshots
        )

        #expect(latest != explicit)
        #expect(context.explicitSnapshotId == explicit)
        #expect(context.snapshotId == explicit)
        #expect(context.source == .explicit)
    }

    @Test
    func `Latest snapshot is used only when requested`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let latest = try await snapshots.createSnapshot()

        let withoutFallback = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: false,
            snapshots: snapshots
        )
        let withFallback = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )

        #expect(withoutFallback.snapshotId == nil)
        #expect(withoutFallback.source == .none)
        #expect(withFallback.snapshotId == latest)
        #expect(withFallback.source == .latest)
    }

    @Test
    func `Explicit latest alias resolves to most recent snapshot`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let latest = try await snapshots.createSnapshot(id: SnapshotReferenceFixtures.second.rawValue)

        let context = await InteractionObservationContext.resolve(
            explicitSnapshot: "latest",
            fallbackToLatest: true,
            snapshots: snapshots
        )

        #expect(context.explicitSnapshotId == nil)
        #expect(context.snapshotId == latest)
        #expect(context.source == .latest)
    }

    @Test
    func `Explicit latest alias resolves even when omitted fallback is disabled`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let latest = try await snapshots.createSnapshot(id: SnapshotReferenceFixtures.second.rawValue)

        let context = await InteractionObservationContext.resolve(
            explicitSnapshot: "most-recent",
            fallbackToLatest: false,
            snapshots: snapshots
        )

        #expect(context.explicitSnapshotId == nil)
        #expect(context.snapshotId == latest)
        #expect(context.source == .latest)
    }

    @Test
    func `Focus snapshot is skipped for latest snapshot with explicit target`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let latest = try await snapshots.createSnapshot()
        var target = InteractionTargetOptions()
        target.app = "TextEdit"

        let latestContext = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let explicitContext = await InteractionObservationContext.resolve(
            explicitSnapshot: "explicit",
            fallbackToLatest: true,
            snapshots: snapshots
        )

        #expect(latestContext.snapshotId == latest)
        #expect(latestContext.focusSnapshotId(for: target) == nil)
        #expect(explicitContext.focusSnapshotId(for: target) == "explicit")
    }

    @Test
    func `Interaction observation target rejects title and index`() throws {
        var target = InteractionTargetOptions()
        target.app = "Preview"
        target.windowTitle = "Main"
        target.windowIndex = 2

        #expect(throws: ValidationError.self) {
            try target.observationTargetRequest()
        }
    }

    @Test
    func `Latest snapshot invalidates after mutation`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        _ = try await snapshots.createSnapshot(id: "older")
        let latest = try await snapshots.createSnapshot()

        let context = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )

        let invalidated = try await context.invalidateAfterMutation(using: snapshots)

        #expect(invalidated == latest)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(try await Set(snapshots.listSnapshots().map(\.id)) == ["older", latest])
    }

    @Test
    func `Explicit snapshot stays available after mutation`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let explicit = try await snapshots.createSnapshot(id: "explicit-snapshot")

        let context = await InteractionObservationContext.resolve(
            explicitSnapshot: "explicit-snapshot",
            fallbackToLatest: true,
            snapshots: snapshots
        )

        let invalidated = try await context.invalidateAfterMutation(using: snapshots)

        #expect(explicit == "explicit-snapshot")
        #expect(invalidated == nil)
        #expect(await snapshots.getMostRecentSnapshot() == "explicit-snapshot")
        #expect(try await snapshots.listSnapshots().map(\.id) == ["explicit-snapshot"])
    }

    @Test
    func `Latest snapshot can be invalidated after focus changes`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        _ = try await snapshots.createSnapshot(id: "older")
        let latest = try await snapshots.createSnapshot()

        let invalidated = try await InteractionObservationContext.invalidateLatestSnapshot(using: snapshots)

        #expect(invalidated == latest)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(try await Set(snapshots.listSnapshots().map(\.id)) == ["older", latest])
    }

    @Test
    func `Latest snapshot invalidation is a no-op when none exists`() async throws {
        let snapshots = CoreSnapshotManagerStub()

        let invalidated = try await InteractionObservationContext.invalidateLatestSnapshot(using: snapshots)

        #expect(invalidated == nil)
    }

    @Test
    func `Focus changes invalidate latest snapshots on every runtime host`() async throws {
        let guiSnapshots = CoreSnapshotManagerStub()
        let daemonSnapshots = CoreSnapshotManagerStub()
        _ = try await guiSnapshots.createSnapshot(id: "gui-older")
        _ = try await guiSnapshots.createSnapshot(id: "gui-latest")
        _ = try await daemonSnapshots.createSnapshot(id: "daemon-older")
        _ = try await daemonSnapshots.createSnapshot(id: "daemon-latest")

        await InteractionObservationInvalidator.invalidateLatestSnapshots(
            using: [guiSnapshots, daemonSnapshots],
            logger: Logger.shared,
            reason: "test focus"
        )

        #expect(await guiSnapshots.getMostRecentSnapshot() == nil)
        #expect(await daemonSnapshots.getMostRecentSnapshot() == nil)
        #expect(try await Set(guiSnapshots.listSnapshots().map(\.id)) == ["gui-older", "gui-latest"])
        #expect(try await Set(daemonSnapshots.listSnapshots().map(\.id)) == ["daemon-older", "daemon-latest"])
    }

    @Test
    func `Cross-host invalidation preserves snapshots created after the shared cutoff`() async throws {
        let immediateSnapshots = CoreSnapshotManagerStub()
        let delayedSnapshots = CoreSnapshotManagerStub()
        _ = try await immediateSnapshots.createSnapshot(id: "immediate-old")
        _ = try await delayedSnapshots.createSnapshot(id: "delayed-old")
        delayedSnapshots.snapshotIdToCreateDuringInvalidation = "delayed-fresh"
        delayedSnapshots.invalidationDelay = .milliseconds(5)

        await InteractionObservationInvalidator.invalidateLatestSnapshots(
            using: [immediateSnapshots, delayedSnapshots],
            logger: Logger.shared,
            reason: "test shared cutoff"
        )

        #expect(immediateSnapshots.invalidationCutoffs.count == 1)
        #expect(delayedSnapshots.invalidationCutoffs == immediateSnapshots.invalidationCutoffs)
        #expect(await immediateSnapshots.getMostRecentSnapshot() == nil)
        #expect(await delayedSnapshots.getMostRecentSnapshot() == "delayed-fresh")
        #expect(try await Set(delayedSnapshots.listSnapshots().map(\.id)) == ["delayed-old", "delayed-fresh"])
    }

    @Test
    func `Coordinate click invalidates implicit latest while preserving explicit history`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let older = try await snapshots.createSnapshot(id: "older")
        let latest = try await snapshots.createSnapshot(id: "latest")

        await InteractionObservationInvalidator.invalidateAfterClickMutation(
            targets: .init(
                snapshots: snapshots,
                selectedRemoteSocketPath: nil,
                remoteSocketPaths: []
            ),
            logger: Logger.shared,
            reason: "coordinate click"
        )

        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(try await Set(snapshots.listSnapshots().map(\.id)) == [older, latest])
    }

    @Test
    func `Element click invalidates latest snapshots on alternate hosts with one cutoff`() async throws {
        let selectedSnapshots = CoreSnapshotManagerStub()
        let alternateSnapshots = CoreSnapshotManagerStub()
        let selectedLatest = try await selectedSnapshots.createSnapshot(id: "selected-latest")
        let alternateLatest = try await alternateSnapshots.createSnapshot(id: "alternate-latest")
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: selectedSnapshots
        )

        await InteractionObservationInvalidator.invalidateAfterClickMutation(
            targets: .init(
                snapshots: selectedSnapshots,
                selectedRemoteSocketPath: nil,
                remoteSocketPaths: ["/tmp/alternate.sock"],
                socketExists: { _ in true },
                makeRemoteSnapshotManager: { _ in alternateSnapshots }
            ),
            logger: Logger.shared,
            reason: "element click"
        )

        #expect(observation.source == .latest)
        #expect(selectedSnapshots.invalidationCutoffs.count == 1)
        #expect(alternateSnapshots.invalidationCutoffs == selectedSnapshots.invalidationCutoffs)
        #expect(await selectedSnapshots.getMostRecentSnapshot() == nil)
        #expect(await alternateSnapshots.getMostRecentSnapshot() == nil)
        #expect(try await selectedSnapshots.listSnapshots().map(\.id) == [selectedLatest])
        #expect(try await alternateSnapshots.listSnapshots().map(\.id) == [alternateLatest])
    }

    @Test
    func `Explicit observation click preserves history while advancing every host watermark`() async throws {
        let selectedSnapshots = CoreSnapshotManagerStub()
        let alternateSnapshots = CoreSnapshotManagerStub()
        let explicit = try await selectedSnapshots.createSnapshot(id: "explicit")
        let selectedLatest = try await selectedSnapshots.createSnapshot(id: "selected-latest")
        let alternateLatest = try await alternateSnapshots.createSnapshot(id: "alternate-latest")
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: explicit,
            fallbackToLatest: true,
            snapshots: selectedSnapshots
        )

        await InteractionObservationInvalidator.invalidateAfterClickMutation(
            targets: .init(
                snapshots: selectedSnapshots,
                selectedRemoteSocketPath: nil,
                remoteSocketPaths: ["/tmp/alternate.sock"],
                socketExists: { _ in true },
                makeRemoteSnapshotManager: { _ in alternateSnapshots }
            ),
            logger: Logger.shared,
            reason: "explicit element click"
        )

        #expect(observation.source == .explicit)
        #expect(alternateSnapshots.invalidationCutoffs == selectedSnapshots.invalidationCutoffs)
        #expect(await selectedSnapshots.getMostRecentSnapshot() == nil)
        #expect(await alternateSnapshots.getMostRecentSnapshot() == nil)
        #expect(try await Set(selectedSnapshots.listSnapshots().map(\.id)) == [explicit, selectedLatest])
        #expect(try await alternateSnapshots.listSnapshots().map(\.id) == [alternateLatest])

        let fresh = try await selectedSnapshots.createSnapshot(id: "fresh")
        #expect(await selectedSnapshots.getMostRecentSnapshot() == fresh)
    }

    @Test
    func `Snapshot-less observation click invalidates latest snapshot on alternate host`() async throws {
        let selectedSnapshots = CoreSnapshotManagerStub()
        let alternateSnapshots = CoreSnapshotManagerStub()
        let alternateLatest = try await alternateSnapshots.createSnapshot(id: "alternate-latest")
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: selectedSnapshots
        )

        await InteractionObservationInvalidator.invalidateAfterClickMutation(
            targets: .init(
                snapshots: selectedSnapshots,
                selectedRemoteSocketPath: nil,
                remoteSocketPaths: ["/tmp/alternate.sock"],
                socketExists: { _ in true },
                makeRemoteSnapshotManager: { _ in alternateSnapshots }
            ),
            logger: Logger.shared,
            reason: "snapshot-less element click"
        )

        #expect(observation.source == .none)
        #expect(selectedSnapshots.invalidationCutoffs.count == 1)
        #expect(alternateSnapshots.invalidationCutoffs == selectedSnapshots.invalidationCutoffs)
        #expect(await alternateSnapshots.getMostRecentSnapshot() == nil)
        #expect(try await alternateSnapshots.listSnapshots().map(\.id) == [alternateLatest])
    }

    @Test
    func `Runtime hosts with matching snapshot IDs are each invalidated`() async throws {
        let guiSnapshots = CoreSnapshotManagerStub()
        let daemonSnapshots = CoreSnapshotManagerStub()
        _ = try await guiSnapshots.createSnapshot(id: "shared-id")
        _ = try await daemonSnapshots.createSnapshot(id: "shared-id")

        await InteractionObservationInvalidator.invalidateLatestSnapshots(
            using: [guiSnapshots, daemonSnapshots],
            logger: Logger.shared,
            reason: "test focus"
        )

        #expect(await guiSnapshots.getMostRecentSnapshot() == nil)
        #expect(await daemonSnapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    @MainActor
    func `Local fallback invalidates snapshots on every known remote endpoint`() async throws {
        let localSnapshots = CoreSnapshotManagerStub()
        let guiSnapshots = CoreSnapshotManagerStub()
        let daemonSnapshots = CoreSnapshotManagerStub()
        for snapshots in [localSnapshots, guiSnapshots, daemonSnapshots] {
            _ = try await snapshots.createSnapshot(id: "shared-id")
        }
        var connectedPaths: [String] = []

        await InteractionObservationInvalidator.invalidateLatestSnapshotsAcrossKnownHosts(
            using: localSnapshots,
            selectedRemoteSocketPath: nil,
            remoteSocketPaths: ["/tmp/gui.sock", "/tmp/daemon.sock", "/tmp/daemon.sock"],
            logger: Logger.shared,
            reason: "test local fallback",
            socketExists: { _ in true },
            makeRemoteSnapshotManager: { path in
                connectedPaths.append(path)
                return path == "/tmp/gui.sock" ? guiSnapshots : daemonSnapshots
            }
        )

        #expect(connectedPaths == ["/tmp/gui.sock", "/tmp/daemon.sock"])
        #expect(await localSnapshots.getMostRecentSnapshot() == nil)
        #expect(await guiSnapshots.getMostRecentSnapshot() == nil)
        #expect(await daemonSnapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    @MainActor
    func `Selected remote endpoint is not invalidated through a duplicate client`() async throws {
        let selectedSnapshots = CoreSnapshotManagerStub()
        let localSnapshots = CoreSnapshotManagerStub()
        let daemonSnapshots = CoreSnapshotManagerStub()
        _ = try await selectedSnapshots.createSnapshot(id: "selected")
        _ = try await localSnapshots.createSnapshot(id: "local")
        _ = try await daemonSnapshots.createSnapshot(id: "daemon")
        var connectedPaths: [String] = []

        await InteractionObservationInvalidator.invalidateLatestSnapshotsAcrossKnownHosts(
            using: selectedSnapshots,
            selectedRemoteSocketPath: "/tmp/gui.sock",
            remoteSocketPaths: ["/tmp/gui.sock", "/tmp/daemon.sock"],
            logger: Logger.shared,
            reason: "test selected endpoint",
            socketExists: { _ in true },
            makeLocalSnapshotManager: { localSnapshots },
            makeRemoteSnapshotManager: { path in
                connectedPaths.append(path)
                return daemonSnapshots
            }
        )

        #expect(connectedPaths == ["/tmp/daemon.sock"])
        #expect(await selectedSnapshots.getMostRecentSnapshot() == nil)
        #expect(await localSnapshots.getMostRecentSnapshot() == nil)
        #expect(await daemonSnapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Mutation invalidation without observation drops latest snapshot`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let latest = try await snapshots.createSnapshot()
        let context = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: false,
            snapshots: snapshots
        )

        await InteractionObservationInvalidator.invalidateAfterMutationOrLatest(
            context,
            snapshots: snapshots,
            logger: Logger.shared,
            reason: "test mutation"
        )

        #expect(latest.isEmpty == false)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Mutation invalidation preserves explicit snapshot`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let explicit = try await snapshots.createSnapshot(id: "explicit-snapshot")
        let context = await InteractionObservationContext.resolve(
            explicitSnapshot: "explicit-snapshot",
            fallbackToLatest: false,
            snapshots: snapshots
        )

        await InteractionObservationInvalidator.invalidateAfterMutationOrLatest(
            context,
            snapshots: snapshots,
            logger: Logger.shared,
            reason: "test mutation"
        )

        #expect(explicit == "explicit-snapshot")
        #expect(await snapshots.getMostRecentSnapshot() == "explicit-snapshot")
    }

    @Test
    func `Missing implicit element refreshes observation snapshot`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let freshDetection = Self.detectionResult(
            snapshotId: "fresh-snapshot",
            element: Self.buttonElement(id: "B2")
        )
        let desktopObservation = RecordingDesktopObservationService(elements: freshDetection, snapshots: snapshots)
        var target = InteractionTargetOptions()
        target.app = "TextEdit"

        let refreshed = try await InteractionObservationRefresher.refreshForMissingElementIfNeeded(
            observation,
            elementId: "B2",
            target: target,
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: desktopObservation,
                snapshots: snapshots
            ),
            logger: Logger.shared
        )

        let reservedSnapshotID = try #require(desktopObservation.requests.first?.output.snapshotID)
        #expect(refreshed.snapshotId == reservedSnapshotID)
        #expect(await snapshots.getMostRecentSnapshot() == reservedSnapshotID)
        #expect(refreshed.source == .latest)
        #expect(desktopObservation.requests.map(\.target) == [.app(identifier: "TextEdit", window: nil)])
    }

    @Test
    func `Certified remote refresh republishes through the host completion cutoff`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let freshDetection = Self.detectionResult(
            snapshotId: "fresh-snapshot",
            element: Self.buttonElement(id: "B2"),
            desktopMutationPreservationAllowed: true
        )
        let desktopObservation = RecordingDesktopObservationService(
            elements: freshDetection,
            snapshots: snapshots
        )
        desktopObservation.hostPublicationCutoffProvider = { Date() }

        let refreshed = try await InteractionObservationRefresher.refreshForMissingElementIfNeeded(
            observation,
            elementId: "B2",
            target: InteractionTargetOptions(),
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: desktopObservation,
                snapshots: snapshots
            ),
            logger: Logger.shared
        )

        let reservedSnapshotID = try #require(desktopObservation.requests.first?.output.snapshotID)
        let hostCutoff = try #require(desktopObservation.resolvedHostPublicationCutoff)
        #expect(refreshed.snapshotId == reservedSnapshotID)
        #expect(await snapshots.getMostRecentSnapshot() == reservedSnapshotID)
        #expect(snapshots.invalidationCutoffs == [hostCutoff, hostCutoff])
    }

    @Test
    func `Refresh rejected by host preservation certificate is never returned`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let freshDetection = Self.detectionResult(
            snapshotId: "fresh-snapshot",
            element: Self.buttonElement(id: "B2"),
            desktopMutationCompletedAt: Date(),
            desktopMutationPreservationAllowed: false
        )
        let desktopObservation = RecordingDesktopObservationService(
            elements: freshDetection,
            snapshots: snapshots
        )

        do {
            _ = try await InteractionObservationRefresher.refreshForMissingElementIfNeeded(
                observation,
                elementId: "B2",
                target: InteractionTargetOptions(),
                dependencies: InteractionObservationRefreshDependencies(
                    desktopObservation: desktopObservation,
                    snapshots: snapshots
                ),
                logger: Logger.shared
            )
            Issue.record("Expected rejected refresh certificate")
        } catch let PeekabooError.snapshotStale(reason) {
            #expect(reason.contains("overlapped another desktop mutation"))
        }

        let reservedSnapshotID = try #require(desktopObservation.requests.first?.output.snapshotID)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(try await snapshots.getDetectionResult(snapshotId: reservedSnapshotID) == nil)
    }

    @Test
    func `Timed out observation refresh keeps late snapshot writes hidden`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let template = Self.detectionResult(
            snapshotId: "unused",
            element: Self.buttonElement(id: "B2")
        )
        let desktopObservation = RecordingDesktopObservationService(elements: template)
        var lateWriteTask: Task<Void, Never>?
        desktopObservation.observeHandler = { request in
            let snapshotID = try #require(request.output.snapshotID)
            let result = ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: template.screenshotPath,
                elements: template.elements,
                metadata: template.metadata
            )
            let task = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                try? await snapshots.storeDetectionResult(snapshotId: snapshotID, result: result)
            }
            lateWriteTask = task
            throw POSIXError(.ETIMEDOUT)
        }

        do {
            _ = try await InteractionObservationRefresher.refreshForMissingElementIfNeeded(
                observation,
                elementId: "B2",
                target: InteractionTargetOptions(),
                dependencies: InteractionObservationRefreshDependencies(
                    desktopObservation: desktopObservation,
                    snapshots: snapshots
                ),
                logger: Logger.shared
            )
            Issue.record("Expected observation timeout")
        } catch let error as POSIXError {
            #expect(error.code == .ETIMEDOUT)
        }

        let task = try #require(lateWriteTask)
        await task.value
        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(try await snapshots.listSnapshots().isEmpty)
    }

    @Test
    func `Existing implicit element does not refresh observation snapshot`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let snapshotId = try await snapshots.createSnapshot(id: "latest-snapshot")
        try await snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: Self.detectionResult(snapshotId: snapshotId, element: Self.buttonElement(id: "B1"))
        )
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let desktopObservation = RecordingDesktopObservationService(
            elements: Self.detectionResult(snapshotId: "fresh-snapshot", element: Self.buttonElement(id: "B1"))
        )

        let refreshed = try await InteractionObservationRefresher.refreshForMissingElementIfNeeded(
            observation,
            elementId: "B1",
            target: InteractionTargetOptions(),
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: desktopObservation,
                snapshots: snapshots
            ),
            logger: Logger.shared
        )

        #expect(refreshed.snapshotId == "latest-snapshot")
        #expect(desktopObservation.requests.isEmpty)
    }

    @Test
    func `Explicit snapshot missing element does not refresh`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let explicit = try await snapshots.createSnapshot(id: "explicit-snapshot")
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: explicit,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let desktopObservation = RecordingDesktopObservationService(
            elements: Self.detectionResult(snapshotId: "fresh-snapshot", element: Self.buttonElement(id: "B2"))
        )

        let refreshed = try await InteractionObservationRefresher.refreshForMissingElementIfNeeded(
            observation,
            elementId: "B2",
            target: InteractionTargetOptions(),
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: desktopObservation,
                snapshots: snapshots
            ),
            logger: Logger.shared
        )

        #expect(refreshed.snapshotId == "explicit-snapshot")
        #expect(desktopObservation.requests.isEmpty)
    }

    @Test
    func `Targeted element action refreshes an implicit snapshot even when the element exists`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let snapshotId = try await snapshots.createSnapshot(id: "unrelated-latest")
        try await snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: Self.detectionResult(snapshotId: snapshotId, element: Self.buttonElement(id: "B1"))
        )
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let freshDetection = Self.detectionResult(
            snapshotId: "fresh-snapshot",
            element: Self.buttonElement(id: "B1")
        )
        let desktopObservation = RecordingDesktopObservationService(elements: freshDetection, snapshots: snapshots)
        var target = InteractionTargetOptions()
        target.app = "TargetApp"

        let refreshed = try await InteractionObservationRefresher.refreshForTargetIfNeeded(
            observation,
            options: TargetedElementObservationRefreshOptions(
                elementTarget: "B1",
                allowWebFocusFallback: false
            ),
            target: target,
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: desktopObservation,
                snapshots: snapshots
            ),
            logger: Logger.shared
        )

        let reservedSnapshotID = try #require(desktopObservation.requests.first?.output.snapshotID)
        #expect(refreshed.snapshotId == reservedSnapshotID)
        switch desktopObservation.requests.first?.target {
        case let .app(identifier, _):
            #expect(identifier == "TargetApp")
        default:
            Issue.record("Expected targeted app observation")
        }
    }

    @Test
    func `Targeted element action never retains an unrelated latest when refresh has no elements`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let unrelatedSnapshotID = try await snapshots.createSnapshot(id: "unrelated-latest")
        try await snapshots.storeDetectionResult(
            snapshotId: unrelatedSnapshotID,
            result: Self.detectionResult(
                snapshotId: unrelatedSnapshotID,
                element: Self.buttonElement(id: "B1")
            )
        )
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let desktopObservation = RecordingDesktopObservationService(
            elements: Self.detectionResult(
                snapshotId: "unused",
                element: Self.buttonElement(id: "B1")
            ),
            snapshots: snapshots
        )
        desktopObservation.observeHandler = { _ in
            DesktopObservationResult(
                target: ResolvedObservationTarget(kind: .frontmost),
                capture: CaptureResult(
                    imageData: Data(),
                    metadata: CaptureMetadata(size: CGSize(width: 1, height: 1), mode: .frontmost)
                ),
                elements: nil,
                diagnostics: DesktopObservationDiagnostics()
            )
        }
        var target = InteractionTargetOptions()
        target.app = "TargetApp"

        do {
            _ = try await InteractionObservationRefresher.refreshForTargetIfNeeded(
                observation,
                options: TargetedElementObservationRefreshOptions(
                    elementTarget: "B1",
                    allowWebFocusFallback: false
                ),
                target: target,
                dependencies: InteractionObservationRefreshDependencies(
                    desktopObservation: desktopObservation,
                    snapshots: snapshots
                ),
                logger: Logger.shared
            )
            Issue.record("Expected an unusable targeted refresh to fail")
        } catch let PeekabooError.snapshotNotAvailable(message) {
            #expect(message.contains("did not produce a usable UI snapshot"))
        }

        #expect(desktopObservation.requests.count == 1)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(try await snapshots.getDetectionResult(snapshotId: unrelatedSnapshotID) != nil)
        #expect(try await Set(snapshots.listSnapshots().map(\.id)) == [unrelatedSnapshotID])
    }

    @Test
    func `Targeted element action refresh preserves scope and explicit web focus policy`() async throws {
        var appTarget = InteractionTargetOptions()
        appTarget.app = "TargetApp"
        var pidTarget = InteractionTargetOptions()
        pidTarget.pid = 4242
        var windowTarget = InteractionTargetOptions()
        windowTarget.windowId = 7373

        let cases: [(InteractionTargetOptions, DesktopObservationTargetRequest)] = [
            (appTarget, .app(identifier: "TargetApp", window: nil)),
            (pidTarget, .pid(4242, window: nil)),
            (windowTarget, .windowID(7373)),
        ]

        for (target, expectedTarget) in cases {
            for allowWebFocusFallback in [false, true] {
                let snapshots = CoreSnapshotManagerStub()
                let observation = await InteractionObservationContext.resolve(
                    explicitSnapshot: nil,
                    fallbackToLatest: true,
                    snapshots: snapshots
                )
                let freshDetection = Self.detectionResult(
                    snapshotId: "fresh-snapshot",
                    element: Self.buttonElement(id: "B1")
                )
                let desktopObservation = RecordingDesktopObservationService(
                    elements: freshDetection,
                    snapshots: snapshots
                )

                let refreshed = try await InteractionObservationRefresher.refreshForTargetIfNeeded(
                    observation,
                    options: TargetedElementObservationRefreshOptions(
                        elementTarget: "B1",
                        allowWebFocusFallback: allowWebFocusFallback
                    ),
                    target: target,
                    dependencies: InteractionObservationRefreshDependencies(
                        desktopObservation: desktopObservation,
                        snapshots: snapshots
                    ),
                    logger: Logger.shared
                )

                let request = try #require(desktopObservation.requests.first)
                let refreshedSnapshotID = try #require(refreshed.snapshotId)
                #expect(request.target == expectedTarget)
                #expect(request.detection.allowWebFocusFallback == allowWebFocusFallback)
                #expect(request.output.snapshotID == refreshedSnapshotID)
                #expect(try await snapshots.getDetectionResult(snapshotId: refreshedSnapshotID) != nil)
            }
        }
    }

    @Test
    func `Targeted element action rejects an explicit snapshot`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let explicit = try await snapshots.createSnapshot(id: "explicit-snapshot")
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: explicit,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let desktopObservation = RecordingDesktopObservationService(
            elements: Self.detectionResult(snapshotId: "unused", element: Self.buttonElement(id: "B1"))
        )
        var target = InteractionTargetOptions()
        target.pid = 123

        await #expect(throws: PeekabooError.self) {
            _ = try await InteractionObservationRefresher.refreshForTargetIfNeeded(
                observation,
                options: TargetedElementObservationRefreshOptions(
                    elementTarget: "B1",
                    allowWebFocusFallback: false
                ),
                target: target,
                dependencies: InteractionObservationRefreshDependencies(
                    desktopObservation: desktopObservation,
                    snapshots: snapshots
                ),
                logger: Logger.shared
            )
        }
        #expect(desktopObservation.requests.isEmpty)
    }

    @Test
    func `Missing implicit query refreshes observation snapshot`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let staleSnapshotId = try await snapshots.createSnapshot(id: "latest-snapshot")
        try await snapshots.storeDetectionResult(
            snapshotId: staleSnapshotId,
            result: Self.detectionResult(snapshotId: staleSnapshotId, element: Self.buttonElement(id: "B1"))
        )
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let freshDetection = Self.detectionResult(
            snapshotId: "fresh-snapshot",
            element: Self.buttonElement(id: "B2", label: "Save")
        )
        let desktopObservation = RecordingDesktopObservationService(elements: freshDetection, snapshots: snapshots)

        let refreshed = try await InteractionObservationRefresher.refreshForMissingQueryIfNeeded(
            observation,
            query: "Save",
            target: InteractionTargetOptions(),
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: desktopObservation,
                snapshots: snapshots
            ),
            logger: Logger.shared
        )

        let reservedSnapshotID = try #require(desktopObservation.requests.first?.output.snapshotID)
        #expect(refreshed.snapshotId == reservedSnapshotID)
        #expect(await snapshots.getMostRecentSnapshot() == reservedSnapshotID)
        #expect(desktopObservation.requests.count == 1)
    }

    @Test
    func `Existing implicit query does not refresh observation snapshot`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let snapshotId = try await snapshots.createSnapshot(id: "latest-snapshot")
        try await snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: Self.detectionResult(snapshotId: snapshotId, element: Self.buttonElement(id: "B1", label: "Save"))
        )
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let desktopObservation = RecordingDesktopObservationService(
            elements: Self.detectionResult(snapshotId: "fresh-snapshot", element: Self.buttonElement(id: "B2"))
        )

        let refreshed = try await InteractionObservationRefresher.refreshForMissingQueryIfNeeded(
            observation,
            query: "Save",
            target: InteractionTargetOptions(),
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: desktopObservation,
                snapshots: snapshots
            ),
            logger: Logger.shared
        )

        #expect(refreshed.snapshotId == "latest-snapshot")
        #expect(desktopObservation.requests.isEmpty)
    }

    @Test
    func `Explicit snapshot missing query does not refresh`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let explicit = try await snapshots.createSnapshot(id: "explicit-snapshot")
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: explicit,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let desktopObservation = RecordingDesktopObservationService(
            elements: Self.detectionResult(snapshotId: "fresh-snapshot", element: Self.buttonElement(id: "B2"))
        )

        let refreshed = try await InteractionObservationRefresher.refreshForMissingQueryIfNeeded(
            observation,
            query: "Save",
            target: InteractionTargetOptions(),
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: desktopObservation,
                snapshots: snapshots
            ),
            logger: Logger.shared
        )

        #expect(refreshed.snapshotId == "explicit-snapshot")
        #expect(desktopObservation.requests.isEmpty)
    }

    @Test
    func `Element target point resolver adjusts moved window centers`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let snapshotId = try await snapshots.createSnapshot(id: "snapshot-with-window")
        try await snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: Self.detectionResult(
                snapshotId: snapshotId,
                element: DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Save",
                    bounds: CGRect(x: 50, y: 70, width: 100, height: 40)
                )
            )
        )
        snapshots.storeUIAutomationSnapshot(
            UIAutomationSnapshot(
                windowBounds: CGRect(x: 10, y: 20, width: 300, height: 200),
                windowID: 42
            ),
            snapshotId: snapshotId
        )
        let tracker = CoreWindowTracker(
            bounds: CGRect(x: 30, y: 25, width: 300, height: 200)
        )
        try await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let point = try await InteractionTargetPointResolver.elementCenter(
                elementId: "B1",
                snapshotId: snapshotId,
                snapshots: snapshots
            )

            #expect(point == CGPoint(x: 120, y: 95))

            let resolution = try await InteractionTargetPointResolver.elementCenterResolution(
                element: Self.buttonElement(id: "B1", label: "Save"),
                elementId: "B1",
                snapshotId: snapshotId,
                snapshots: snapshots
            )

            #expect(resolution.point == CGPoint(x: 70, y: 37))
            #expect(resolution.diagnostics.source == "element")
            #expect(resolution.diagnostics.elementId == "B1")
            #expect(resolution.diagnostics.snapshotId == snapshotId)
            #expect(resolution.diagnostics.original == InteractionPoint(CGPoint(x: 50, y: 32)))
            #expect(resolution.diagnostics.resolved == InteractionPoint(CGPoint(x: 70, y: 37)))
            #expect(resolution.diagnostics.windowAdjustment?.status == "adjusted")
            #expect(resolution.diagnostics.windowAdjustment?.delta == InteractionPoint(CGPoint(x: 20, y: 5)))
        }
    }

    @Test
    func `Element target point resolver refuses OCR evidence before coordinate resolution`() async {
        let snapshots = CoreSnapshotManagerStub()
        let element = DetectedElement(
            id: "ocr_1",
            type: .staticText,
            label: "August",
            bounds: CGRect(x: 50, y: 70, width: 100, height: 40),
            attributes: [
                "description": "ocr",
                "confidence": "0.93",
            ]
        )

        await #expect(throws: PeekabooError.self) {
            _ = try await InteractionTargetPointResolver.elementCenterResolution(
                element: element,
                elementId: "ocr_1",
                snapshotId: nil,
                snapshots: snapshots
            )
        }
    }

    @Test
    func `Target point diagnostics describe coordinate targets`() {
        let point = CGPoint(x: 10, y: 20)
        let resolution = InteractionTargetPointResolver.coordinate(point, source: .coordinates)

        #expect(resolution.point == point)
        #expect(resolution.diagnostics.source == "coordinates")
        #expect(resolution.diagnostics.original == InteractionPoint(point))
        #expect(resolution.diagnostics.resolved == InteractionPoint(point))
        #expect(resolution.diagnostics.windowAdjustment == nil)
    }

    private static func buttonElement(id: String) -> DetectedElement {
        self.buttonElement(id: id, label: "Button \(id)")
    }

    private static func buttonElement(id: String, label: String) -> DetectedElement {
        DetectedElement(
            id: id,
            type: .button,
            label: label,
            bounds: CGRect(x: 10, y: 20, width: 80, height: 24)
        )
    }

    private static func detectionResult(
        snapshotId: String,
        element: DetectedElement,
        desktopMutationCompletedAt: Date? = nil,
        desktopMutationPreservationAllowed: Bool? = nil
    ) -> ElementDetectionResult {
        ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/\(snapshotId).png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "test",
                truncationInfo: nil,
                desktopMutationCompletedAt: desktopMutationCompletedAt,
                desktopMutationPreservationAllowed: desktopMutationPreservationAllowed
            )
        )
    }
}

@MainActor
private final class RecordingDesktopObservationService: DesktopObservationServiceProtocol {
    private let elements: ElementDetectionResult
    private let snapshots: (any SnapshotManagerProtocol)?
    private(set) var requests: [DesktopObservationRequest] = []
    private(set) var resolvedHostPublicationCutoff: Date?
    var hostPublicationCutoffProvider: (() -> Date)?
    var observeHandler: (@MainActor (DesktopObservationRequest) async throws -> DesktopObservationResult)?

    init(elements: ElementDetectionResult, snapshots: (any SnapshotManagerProtocol)? = nil) {
        self.elements = elements
        self.snapshots = snapshots
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.requests.append(request)
        if let observeHandler {
            return try await observeHandler(request)
        }
        let snapshotID = request.output.snapshotID ?? self.elements.snapshotId
        let boundElements = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: self.elements.screenshotPath,
            elements: self.elements.elements,
            metadata: self.elements.metadata
        )
        if request.output.saveSnapshot, let snapshots {
            try await snapshots.storeDetectionResult(snapshotId: snapshotID, result: boundElements)
        }
        let hostPublicationCutoff = self.hostPublicationCutoffProvider?()
        self.resolvedHostPublicationCutoff = hostPublicationCutoff
        if let hostPublicationCutoff, let snapshots {
            _ = try await snapshots.invalidateImplicitLatestSnapshot(
                through: hostPublicationCutoff,
                preserving: snapshotID,
                preservedAt: hostPublicationCutoff
            )
        }
        return DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .frontmost),
            capture: CaptureResult(
                imageData: Data(),
                metadata: CaptureMetadata(size: CGSize(width: 1, height: 1), mode: .frontmost)
            ),
            elements: boundElements,
            diagnostics: DesktopObservationDiagnostics(
                desktopMutationCompletedAt: hostPublicationCutoff ??
                    boundElements.metadata.desktopMutationCompletedAt,
                desktopMutationPreservationAllowed: boundElements.metadata.desktopMutationPreservationAllowed
            )
        )
    }
}

private final class CoreSnapshotManagerStub: SnapshotManagerProtocol, @unchecked Sendable {
    let supportsImplicitLatestSnapshotInvalidation = true
    private var snapshotInfos: [String: SnapshotInfo] = [:]
    private var detectionResults: [String: ElementDetectionResult] = [:]
    private var automationSnapshots: [String: UIAutomationSnapshot] = [:]
    private var mostRecentSnapshotId: String?
    private var implicitLatestInvalidatedAt: Date?
    private var pendingSnapshotIDs: Set<String> = []
    private(set) var invalidationCutoffs: [Date] = []
    var snapshotIdToCreateDuringInvalidation: String?
    var invalidationDelay: Duration?

    func createSnapshot() async throws -> String {
        try await self.createSnapshot(id: UUID().uuidString)
    }

    func createSnapshot(pendingAt observationStartedAt: Date) async throws -> String {
        try await self.createSnapshot(
            id: UUID().uuidString,
            createdAt: observationStartedAt,
            pending: true
        )
    }

    func createSnapshot(id snapshotId: String) async throws -> String {
        try await self.createSnapshot(id: snapshotId, createdAt: Date(), pending: false)
    }

    private func createSnapshot(
        id snapshotId: String,
        createdAt: Date,
        pending: Bool
    ) async throws -> String {
        self.snapshotInfos[snapshotId] = SnapshotInfo(
            id: snapshotId,
            processId: 0,
            createdAt: createdAt,
            lastAccessedAt: Date(),
            sizeInBytes: 0,
            screenshotCount: 0,
            isActive: true
        )
        if pending {
            self.pendingSnapshotIDs.insert(snapshotId)
        } else {
            self.mostRecentSnapshotId = snapshotId
        }
        return snapshotId
    }

    func storeDetectionResult(snapshotId: String, result: ElementDetectionResult) async throws {
        self.detectionResults[snapshotId] = result
        if !self.pendingSnapshotIDs.contains(snapshotId) {
            self.mostRecentSnapshotId = snapshotId
        }
    }

    func storeUIAutomationSnapshot(_ snapshot: UIAutomationSnapshot, snapshotId: String) {
        self.automationSnapshots[snapshotId] = snapshot
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
        preservedAt: Date?
    ) async throws -> String? {
        self.invalidationCutoffs.append(cutoff)
        if let invalidationDelay {
            try await Task.sleep(for: invalidationDelay)
        }
        if let snapshotIdToCreateDuringInvalidation {
            self.snapshotIdToCreateDuringInvalidation = nil
            _ = try await self.createSnapshot(id: snapshotIdToCreateDuringInvalidation)
        }

        let previousWatermark = self.implicitLatestInvalidatedAt
        let invalidatedSnapshotId = self.snapshotInfos.values
            .filter { info in
                !self.pendingSnapshotIDs.contains(info.id) && info.createdAt <= cutoff &&
                    (previousWatermark.map { info.createdAt > $0 } ?? true)
            }
            .max(by: { $0.createdAt < $1.createdAt })?
            .id
        let watermark = max(previousWatermark ?? cutoff, cutoff)
        self.implicitLatestInvalidatedAt = watermark
        if let snapshotId {
            self.pendingSnapshotIDs.remove(snapshotId)
        }
        let normalLatest = self.snapshotInfos.values
            .filter { $0.createdAt > watermark }
            .max(by: { $0.createdAt < $1.createdAt })?
            .id
        if let snapshotId,
           let preservedAt,
           self.snapshotInfos[snapshotId] != nil,
           previousWatermark.map({ $0 <= cutoff }) ?? true,
           normalLatest.flatMap({ self.snapshotInfos[$0]?.createdAt }).map({ $0 <= preservedAt }) ?? true {
            self.mostRecentSnapshotId = snapshotId
        } else {
            self.mostRecentSnapshotId = normalLatest
        }
        return invalidatedSnapshotId
    }

    func listSnapshots() async throws -> [SnapshotInfo] {
        self.snapshotInfos.values.filter { !self.pendingSnapshotIDs.contains($0.id) }
    }

    func cleanSnapshot(snapshotId: String) async throws {
        self.snapshotInfos.removeValue(forKey: snapshotId)
        self.detectionResults.removeValue(forKey: snapshotId)
        self.automationSnapshots.removeValue(forKey: snapshotId)
        self.pendingSnapshotIDs.remove(snapshotId)
        if self.mostRecentSnapshotId == snapshotId {
            self.mostRecentSnapshotId = nil
        }
    }

    func cleanSnapshotsOlderThan(days _: Int) async throws -> Int {
        0
    }

    func cleanAllSnapshots() async throws -> Int {
        let count = self.snapshotInfos.count
        self.snapshotInfos.removeAll()
        self.detectionResults.removeAll()
        self.automationSnapshots.removeAll()
        self.pendingSnapshotIDs.removeAll()
        self.mostRecentSnapshotId = nil
        self.implicitLatestInvalidatedAt = nil
        return count
    }

    func getSnapshotStoragePath() -> String {
        "/tmp/peekaboo-snapshots"
    }

    func storeScreenshot(_: SnapshotScreenshotRequest) async throws {}

    func storeAnnotatedScreenshot(snapshotId _: String, annotatedScreenshotPath _: String) async throws {}

    func getElement(snapshotId _: String, elementId _: String) async throws -> PeekabooCore.UIElement? {
        nil
    }

    func findElements(snapshotId _: String, matching _: String) async throws -> [PeekabooCore.UIElement] {
        []
    }

    func getUIAutomationSnapshot(snapshotId: String) async throws -> UIAutomationSnapshot? {
        self.automationSnapshots[snapshotId]
    }
}

@MainActor
private final class CoreWindowTracker: WindowTrackingProviding {
    private let bounds: CGRect?

    init(bounds: CGRect?) {
        self.bounds = bounds
    }

    func windowBounds(for _: CGWindowID) -> CGRect? {
        self.bounds
    }
}
