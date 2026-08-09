import Foundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DesktopMutationWatermarkStoreTests {
    @Test
    func `watermark persists across store instances and never regresses`() throws {
        let root = Self.temporaryDirectory(named: "restart")
        defer { try? FileManager.default.removeItem(at: root) }
        let earlier = Date().addingTimeInterval(-60)
        let later = Date()

        let first = DesktopMutationWatermarkStore(directoryURL: root)
        #expect(try first.advance(through: later) == later)
        #expect(try first.advance(through: earlier) == later)

        let restarted = DesktopMutationWatermarkStore(directoryURL: root)
        #expect(restarted.effectiveWatermark() == later)
    }

    @Test
    func `concurrent writers persist the greatest cutoff`() async throws {
        let root = Self.temporaryDirectory(named: "concurrent")
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = Date().addingTimeInterval(-100)
        let cutoffs = (0..<32).map { baseline.addingTimeInterval(TimeInterval($0)) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for cutoff in cutoffs {
                group.addTask {
                    let writer = DesktopMutationWatermarkStore(directoryURL: root)
                    _ = try writer.advance(through: cutoff)
                }
            }
            try await group.waitForAll()
        }

        let restarted = DesktopMutationWatermarkStore(directoryURL: root)
        #expect(restarted.effectiveWatermark() == cutoffs.last)
    }

    @Test
    func `corrupt watermark fails closed`() throws {
        let root = Self.temporaryDirectory(named: "corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let oldCutoff = Date().addingTimeInterval(-120)
        _ = try store.advance(through: oldCutoff)
        try Data("not-json".utf8).write(to: store.watermarkURL, options: .atomic)

        let recovered = try #require(store.effectiveWatermark())
        #expect(recovered > oldCutoff)
    }

    @Test
    func `pending mutation hides interim snapshots until host completion`() async throws {
        let root = Self.temporaryDirectory(named: "pending")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let manager = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let mutation = try store.beginMutation()
        let interimSnapshotID = try await manager.createSnapshot()

        let beforeRead = Date()
        let pendingWatermark = try #require(store.effectiveWatermark())
        let afterRead = Date()
        #expect(pendingWatermark >= beforeRead)
        #expect(pendingWatermark <= afterRead)
        #expect(await manager.getMostRecentSnapshot() == nil)

        let completedAt = Date()
        let completion = try store.completeMutation(mutation, through: completedAt)
        #expect(completion.cutoff == completedAt)
        #expect(completion.allowsObservationPreservation)
        #expect(store.effectiveWatermark() == completedAt)
        #expect(await manager.getMostRecentSnapshot() == nil)
        #expect(try await manager.getUIAutomationSnapshot(snapshotId: interimSnapshotID) != nil)

        try await Task.sleep(for: .milliseconds(1))
        let freshSnapshotID = try await manager.createSnapshot()
        #expect(await manager.getMostRecentSnapshot() == freshSnapshotID)
    }

    @Test
    func `caller can read through only its own pending mutation barrier`() async throws {
        let root = Self.temporaryDirectory(named: "caller-visible")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = DesktopMutationWatermarkStore(directoryURL: root)
        let reader = DesktopMutationWatermarkStore(directoryURL: root)
        let manager = InMemorySnapshotManager(desktopMutationWatermarkStore: reader)
        let snapshotID = try await manager.createSnapshot()
        let callerMutation = try writer.beginMutation()

        #expect(await manager.getMostRecentSnapshot() == nil)
        try await DesktopMutationWatermarkStore.withPendingMutationVisible(callerMutation) {
            #expect(await manager.getMostRecentSnapshot() == snapshotID)

            let competingMutation = try writer.beginMutation()
            #expect(await manager.getMostRecentSnapshot() == nil)
            try writer.cancelMutation(competingMutation)
            #expect(await manager.getMostRecentSnapshot() == snapshotID)
        }
        #expect(await manager.getMostRecentSnapshot() == nil)
        try writer.cancelMutation(callerMutation)
    }

    @Test
    func `overlapping mutation barriers remain pending until every host operation completes`() throws {
        let root = Self.temporaryDirectory(named: "overlap")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let first = try store.beginMutation()
        let second = try store.beginMutation()
        let firstCompletion = Date()

        let firstResult = try store.completeMutation(first, through: firstCompletion)
        #expect(!firstResult.allowsObservationPreservation)
        let beforePendingRead = Date()
        #expect(try #require(store.effectiveWatermark()) >= beforePendingRead)

        let secondCompletion = Date()
        let secondResult = try store.completeMutation(second, through: secondCompletion)
        #expect(!secondResult.allowsObservationPreservation)
        #expect(store.effectiveWatermark() == secondCompletion)
    }

    @Test
    func `plain watermark advance invalidates an in-flight preservation certificate`() throws {
        let root = Self.temporaryDirectory(named: "advance-during-mutation")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let mutation = try store.beginMutation()
        let interveningCutoff = Date()

        _ = try store.advance(through: interveningCutoff)
        let completion = try store.completeMutation(
            mutation,
            through: interveningCutoff.addingTimeInterval(1))

        #expect(!completion.allowsObservationPreservation)
        #expect(completion.cutoff == interveningCutoff.addingTimeInterval(1))
    }

    @Test
    func `duplicate watermark propagation does not invalidate an in-flight certificate`() throws {
        let root = Self.temporaryDirectory(named: "duplicate-advance-during-mutation")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let baseline = Date()
        _ = try store.advance(through: baseline)
        let mutation = try store.beginMutation()

        #expect(try store.advance(through: baseline) == baseline)
        #expect(try store.advance(through: baseline.addingTimeInterval(-1)) == baseline)
        let completion = try store.completeMutation(
            mutation,
            through: baseline.addingTimeInterval(1))

        #expect(completion.allowsObservationPreservation)
        #expect(completion.cutoff == baseline.addingTimeInterval(1))
    }

    @Test
    func `real equal-cutoff completions still invalidate overlapping certificates`() throws {
        let root = Self.temporaryDirectory(named: "equal-cutoff-overlap")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let cutoff = Date()
        _ = try store.advance(through: cutoff)
        let first = try store.beginMutation()
        let second = try store.beginMutation()

        let firstCompletion = try store.completeMutation(first, through: cutoff)
        let secondCompletion = try store.completeMutation(second, through: cutoff)

        #expect(!firstCompletion.allowsObservationPreservation)
        #expect(!secondCompletion.allowsObservationPreservation)
    }

    @Test
    func `completed record cannot poison snapshots when pending cleanup fails`() async throws {
        let root = Self.temporaryDirectory(named: "completion-cleanup-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let remover = PendingRecordRemovalController(failing: true)
        let store = DesktopMutationWatermarkStore(
            directoryURL: root,
            processStartIdentityProvider: { _ in 1 },
            pendingRecordRemover: { try remover.remove($0) })
        let mutation = try store.beginMutation()
        let cutoff = Date()

        let completion = try store.completeMutation(mutation, through: cutoff)

        #expect(completion.cutoff == cutoff)
        #expect(completion.allowsObservationPreservation)
        #expect(store.effectiveWatermark() == cutoff)
        let pendingDirectory = root.appendingPathComponent("desktop-mutation-pending", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil).count == 1)

        try FileManager.default.removeItem(at: store.watermarkURL)
        await DesktopMutationWatermarkStore.withPendingMutationVisible(mutation) {
            #expect(store.effectiveWatermark() == cutoff)
        }

        remover.failing = false
        #expect(store.effectiveWatermark() == cutoff)
        #expect(try FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil).isEmpty)
    }

    @Test
    func `canceled record cannot poison snapshots when pending cleanup fails`() throws {
        let root = Self.temporaryDirectory(named: "cancel-cleanup-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let remover = PendingRecordRemovalController(failing: true)
        let store = DesktopMutationWatermarkStore(
            directoryURL: root,
            processStartIdentityProvider: { _ in 1 },
            pendingRecordRemover: { try remover.remove($0) })
        let mutation = try store.beginMutation()

        try store.cancelMutation(mutation)

        #expect(store.effectiveWatermark() == nil)
        let pendingDirectory = root.appendingPathComponent("desktop-mutation-pending", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil).count == 1)

        remover.failing = false
        #expect(store.effectiveWatermark() == nil)
        #expect(try FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil).isEmpty)
    }

    @Test
    func `orphaned mutation barrier recovers to a fresh persisted cutoff`() async throws {
        let root = Self.temporaryDirectory(named: "orphan")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let manager = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let staleSnapshotID = try await manager.createSnapshot()
        _ = try store.beginMutation(at: Date(), ownerProcessIdentifier: pid_t.max)

        let beforeRecovery = Date()
        let recovered = try #require(store.effectiveWatermark())
        #expect(recovered >= beforeRecovery)
        #expect(store.effectiveWatermark() == recovered)
        #expect(await manager.getMostRecentSnapshot() == nil)
        #expect(try await manager.getUIAutomationSnapshot(snapshotId: staleSnapshotID) != nil)
    }

    @Test
    func `orphan recovery survives watermark publication failure`() throws {
        let root = Self.temporaryDirectory(named: "orphan-publication-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        _ = try store.beginMutation(at: Date(), ownerProcessIdentifier: pid_t.max)
        try FileManager.default.createDirectory(
            at: store.watermarkURL,
            withIntermediateDirectories: false)
        let beforeRecovery = Date()

        #expect(try #require(store.effectiveWatermark()) >= beforeRecovery)
        let pendingDirectory = root.appendingPathComponent("desktop-mutation-pending", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil).count == 1)

        try FileManager.default.removeItem(at: store.watermarkURL)
        #expect(try #require(store.effectiveWatermark()) >= beforeRecovery)
        #expect(try FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil).isEmpty)
    }

    @Test
    func `overlapping orphan recovers at detection time instead of older completion cutoff`() throws {
        let root = Self.temporaryDirectory(named: "overlap-orphan-cutoff")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let completingMutation = try store.beginMutation()
        _ = try store.beginMutation(at: Date(), ownerProcessIdentifier: pid_t.max)
        let olderCompletionCutoff = Date().addingTimeInterval(-60)
        let beforeRecovery = Date()

        let completion = try store.completeMutation(
            completingMutation,
            through: olderCompletionCutoff)

        // Orphan recovery advances the completion generation, so preservation is still denied
        // for a different reason than "peer still pending".
        #expect(!completion.allowsObservationPreservation)
        #expect(completion.cutoff >= beforeRecovery)
        #expect(store.effectiveWatermark() == completion.cutoff)
    }

    @Test
    func `orphan peers are not counted as other live pending mutations`() throws {
        let root = Self.temporaryDirectory(named: "orphan-not-live-peer")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let live = try store.beginMutation()
        _ = try store.beginMutation(at: Date(), ownerProcessIdentifier: pid_t.max)

        // Before the fix, hasOtherPendingMutationUnlocked set foundOtherMutation=true before
        // resolving the orphan, so this returned true even after cleanup.
        let hasOther = try store.hasOtherLivePendingMutation(excluding: live)
        #expect(hasOther == false)

        let pendingDirectory = root.appendingPathComponent("desktop-mutation-pending", isDirectory: true)
        let pendingFiles = try FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil)
        #expect(pendingFiles.count == 1)
    }

    @Test
    func `reused process identifier cannot keep an orphaned barrier alive`() throws {
        let root = Self.temporaryDirectory(named: "pid-reuse")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = ProcessStartIdentityBox(100)
        let store = DesktopMutationWatermarkStore(
            directoryURL: root,
            processStartIdentityProvider: { _ in identity.value })
        _ = try store.beginMutation(at: Date(), ownerProcessIdentifier: getpid())
        identity.value = 200

        let beforeRecovery = Date()
        #expect(try #require(store.effectiveWatermark()) >= beforeRecovery)
        #expect(try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("desktop-mutation-pending", isDirectory: true),
            includingPropertiesForKeys: nil).isEmpty)
    }

    @Test
    func `external cutoff hides stale disk snapshots after manager restart`() async throws {
        let root = Self.temporaryDirectory(named: "disk-restart")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotsURL = root.appendingPathComponent("snapshots", isDirectory: true)
        let store = DesktopMutationWatermarkStore(
            directoryURL: root.appendingPathComponent("shared", isDirectory: true))
        let first = SnapshotManager(
            snapshotStorageURL: snapshotsURL,
            desktopMutationWatermarkStore: store)
        let snapshotID = try await first.createSnapshot()
        let cutoff = Date()

        // Models a remote mutation that completed while its cleanup response timed out.
        _ = try store.advance(through: cutoff)
        let restarted = SnapshotManager(
            snapshotStorageURL: snapshotsURL,
            desktopMutationWatermarkStore: DesktopMutationWatermarkStore(
                directoryURL: store.directoryURL))

        #expect(await restarted.getMostRecentSnapshot() == nil)
        #expect(try await restarted.listSnapshots().map(\.id) == [snapshotID])
        #expect(try await restarted.getUIAutomationSnapshot(snapshotId: snapshotID) != nil)
    }

    @Test
    func `equal external cutoff preserves fresh observation and newer cutoff suppresses it`() async throws {
        let root = Self.temporaryDirectory(named: "preservation")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let manager = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let observationStartedAt = Date()
        let snapshotID = try await manager.createSnapshot(pendingAt: observationStartedAt)

        _ = try await manager.invalidateImplicitLatestSnapshot(
            through: observationStartedAt,
            preserving: snapshotID,
            preservedAt: Date())
        _ = try store.advance(through: observationStartedAt)
        #expect(await manager.getMostRecentSnapshot() == snapshotID)

        _ = try store.advance(through: observationStartedAt.addingTimeInterval(1))
        #expect(await manager.getMostRecentSnapshot() == nil)
        #expect(try await manager.getUIAutomationSnapshot(snapshotId: snapshotID) != nil)
    }

    @Test
    func `snapshot cleanup does not reset desktop watermark`() async throws {
        let root = Self.temporaryDirectory(named: "cleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(
            directoryURL: root.appendingPathComponent("shared", isDirectory: true))
        let manager = SnapshotManager(
            snapshotStorageURL: root.appendingPathComponent("snapshots", isDirectory: true),
            desktopMutationWatermarkStore: store)
        let cutoff = Date()
        _ = try await manager.invalidateImplicitLatestSnapshot(through: cutoff)

        _ = try await manager.cleanAllSnapshots()

        #expect(manager.effectiveImplicitLatestInvalidationWatermark == cutoff)
        #expect(DesktopMutationWatermarkStore(directoryURL: store.directoryURL).effectiveWatermark() == cutoff)
    }

    @Test
    func `Target watermarks follow global process and window hierarchy`() throws {
        let root = Self.temporaryDirectory(named: "target-hierarchy")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let process = ApplicationProcessIdentity(processIdentifier: 810, processStartIdentity: 10)
        let otherProcess = ApplicationProcessIdentity(processIdentifier: 811, processStartIdentity: 20)
        let firstWindow = Self.window(windowID: 1, process: process)
        let secondWindow = Self.window(windowID: 2, process: process)
        let otherWindow = Self.window(windowID: 1, process: otherProcess)
        let windowCutoff = Date().addingTimeInterval(-3)
        let processCutoff = Date().addingTimeInterval(-2)
        let globalCutoff = Date().addingTimeInterval(-1)

        let windowMutation = try store.beginMutation(at: windowCutoff, target: .window(firstWindow))
        _ = try store.completeMutation(windowMutation, through: windowCutoff)

        #expect(store.effectiveWatermark() == windowCutoff)
        #expect(store.effectiveWatermark(for: .window(firstWindow)) == windowCutoff)
        #expect(store.effectiveWatermark(for: .window(secondWindow)) == nil)
        #expect(store.effectiveWatermark(for: .process(process)) == windowCutoff)
        #expect(store.effectiveWatermark(for: .window(otherWindow)) == nil)

        let processMutation = try store.beginMutation(at: processCutoff, target: .process(process))
        _ = try store.completeMutation(processMutation, through: processCutoff)

        #expect(store.effectiveWatermark(for: .window(firstWindow)) == processCutoff)
        #expect(store.effectiveWatermark(for: .window(secondWindow)) == processCutoff)
        #expect(store.effectiveWatermark(for: .process(process)) == processCutoff)
        #expect(store.effectiveWatermark(for: .window(otherWindow)) == nil)

        let globalMutation = try store.beginMutation(at: globalCutoff, target: .global)
        _ = try store.completeMutation(globalMutation, through: globalCutoff)

        #expect(store.effectiveWatermark(for: .window(firstWindow)) == globalCutoff)
        #expect(store.effectiveWatermark(for: .window(otherWindow)) == globalCutoff)
    }

    @Test
    func `Sibling window mutations keep independent preservation fences`() throws {
        let root = Self.temporaryDirectory(named: "sibling-preservation")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let process = ApplicationProcessIdentity(processIdentifier: 820, processStartIdentity: 10)
        let first = try store.beginMutation(target: .window(Self.window(windowID: 1, process: process)))
        let second = try store.beginMutation(target: .window(Self.window(windowID: 2, process: process)))

        let firstCompletion = try store.completeMutation(first, through: Date())
        let secondCompletion = try store.completeMutation(second, through: Date().addingTimeInterval(1))

        #expect(firstCompletion.allowsObservationPreservation)
        #expect(secondCompletion.allowsObservationPreservation)
        #expect(store.isPreservationFenceCurrent(firstCompletion.preservationFence))
        #expect(store.isPreservationFenceCurrent(secondCompletion.preservationFence))

        let laterFirst = try store.beginMutation(target: firstCompletion.preservationFence.target)
        _ = try store.completeMutation(laterFirst, through: Date().addingTimeInterval(2))
        #expect(!store.isPreservationFenceCurrent(firstCompletion.preservationFence))
        #expect(store.isPreservationFenceCurrent(secondCompletion.preservationFence))
    }

    @Test
    func `Same window and process-wide peers invalidate preservation fences`() throws {
        let root = Self.temporaryDirectory(named: "relevant-preservation")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let process = ApplicationProcessIdentity(processIdentifier: 830, processStartIdentity: 10)
        let window = Self.window(windowID: 1, process: process)
        let first = try store.beginMutation(target: .window(window))
        let sameWindow = try store.beginMutation(target: .window(window))

        #expect(try !(store.completeMutation(first, through: Date()).allowsObservationPreservation))
        #expect(try !(store.completeMutation(sameWindow, through: Date()).allowsObservationPreservation))

        let nextWindow = try store.beginMutation(target: .window(window))
        let processMutation = try store.beginMutation(target: .process(process))
        #expect(try !(store.completeMutation(nextWindow, through: Date()).allowsObservationPreservation))
        #expect(try !(store.completeMutation(processMutation, through: Date()).allowsObservationPreservation))
    }

    @Test
    func `Legacy writer drift is reconciled as a conservative global cutoff`() throws {
        let root = Self.temporaryDirectory(named: "legacy-writer")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let process = ApplicationProcessIdentity(processIdentifier: 840, processStartIdentity: 10)
        let window = Self.window(windowID: 1, process: process)
        let baseline = Date().addingTimeInterval(-10)
        _ = try store.advance(through: baseline, target: .window(window))

        let foreignCutoff = Date()
        let legacyRecord: [String: Any] = [
            "version": 1,
            "cutoffReferenceDateSeconds": foreignCutoff.timeIntervalSinceReferenceDate,
            "completionGeneration": 99,
        ]
        try JSONSerialization.data(withJSONObject: legacyRecord).write(to: store.watermarkURL, options: .atomic)

        let unrelatedWindow = Self.window(
            windowID: 99,
            process: ApplicationProcessIdentity(processIdentifier: 999, processStartIdentity: 999))
        #expect(store.effectiveWatermark(for: .window(unrelatedWindow)) == foreignCutoff)
        #expect(store.effectiveWatermark(for: .process(process)) == foreignCutoff)
    }

    @Test
    func `Resolved journal rebuilds exact target ledger after legacy publication crash`() throws {
        let root = Self.temporaryDirectory(named: "target-journal-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let remover = PendingRecordRemovalController(failing: true)
        let process = ApplicationProcessIdentity(processIdentifier: 850, processStartIdentity: 10)
        let target = Self.window(windowID: 1, process: process)
        let sibling = Self.window(windowID: 2, process: process)
        let store = DesktopMutationWatermarkStore(
            directoryURL: root,
            processStartIdentityProvider: { _ in 10 },
            pendingRecordRemover: { try remover.remove($0) })
        let mutation = try store.beginMutation(target: .window(target))
        let cutoff = Date()
        _ = try store.completeMutation(mutation, through: cutoff)
        try FileManager.default.removeItem(at: store.scopedLedgerURL)

        let restarted = DesktopMutationWatermarkStore(
            directoryURL: root,
            processStartIdentityProvider: { _ in 10 })
        #expect(restarted.effectiveWatermark(for: .window(target)) == cutoff)
        #expect(restarted.effectiveWatermark(for: .window(sibling)) == nil)
    }

    @Test
    func `Expired generation entries compact to a conservative global tombstone`() throws {
        let root = Self.temporaryDirectory(named: "target-pruning")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let oldProcess = ApplicationProcessIdentity(processIdentifier: 860, processStartIdentity: 10)
        let recentProcess = ApplicationProcessIdentity(processIdentifier: 861, processStartIdentity: 20)
        let unrelatedProcess = ApplicationProcessIdentity(processIdentifier: 862, processStartIdentity: 30)
        let oldWindow = Self.window(windowID: 1, process: oldProcess)
        let recentWindow = Self.window(windowID: 2, process: recentProcess)
        let unrelatedWindow = Self.window(windowID: 3, process: unrelatedProcess)
        let oldCutoff = Date().addingTimeInterval(-7200)
        let preMutationSnapshotDate = oldCutoff.addingTimeInterval(-1)

        _ = try store.advance(through: oldCutoff, target: .window(oldWindow))
        let recentCutoff = try store.advance(through: Date(), target: .window(recentWindow))

        let restarted = DesktopMutationWatermarkStore(directoryURL: root)
        let compactedCutoff = try #require(restarted.effectiveWatermark(for: .window(oldWindow)))
        #expect(compactedCutoff >= oldCutoff)
        #expect(preMutationSnapshotDate <= compactedCutoff)
        #expect(restarted.effectiveWatermark(for: .process(oldProcess)) == compactedCutoff)
        #expect(restarted.effectiveWatermark(for: .window(unrelatedWindow)) == compactedCutoff)
        #expect(restarted.effectiveWatermark(for: .window(recentWindow)) == recentCutoff)
    }

    @Test
    func `Default watermark root is fixed runtime coordination storage`() {
        let store = DesktopMutationWatermarkStore()

        #expect(store.directoryURL == DesktopCoordinationRuntimeRoot.defaultURL)
        #expect(store.directoryURL.lastPathComponent == ".peekaboo")
    }

    @Test
    func `Production coordination root ignores configurable home temp and config paths`() {
        let expected = DesktopCoordinationRuntimeRoot.defaultURL
        let names = ["HOME", "TMPDIR", "CFFIXED_USER_HOME", "PEEKABOO_CONFIG_DIR"]
        let previous = names.reduce(into: [String: String]()) { values, name in
            values[name] = getenv(name).map { String(cString: $0) }
        }
        defer {
            for name in names {
                if let value = previous[name] {
                    setenv(name, value, 1)
                } else {
                    unsetenv(name)
                }
            }
        }
        for name in names {
            setenv(name, "/tmp/peekaboo-untrusted-root", 1)
        }

        #expect(DesktopCoordinationRuntimeRoot.defaultURL == expected)
        #expect(DesktopMutationWatermarkStore().directoryURL == expected)
    }

    private static func temporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-watermark-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private static func window(
        windowID: Int,
        process: ApplicationProcessIdentity) -> WindowMutationIdentity
    {
        WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: process.processIdentifier,
            ownerProcessStartIdentity: process.processStartIdentity,
            capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            isMinimized: false)
    }
}

private final class ProcessStartIdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UInt64

    init(_ value: UInt64) {
        self.storedValue = value
    }

    var value: UInt64 {
        get { self.lock.withLock { self.storedValue } }
        set { self.lock.withLock { self.storedValue = newValue } }
    }
}

private final class PendingRecordRemovalController: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailing: Bool

    init(failing: Bool) {
        self.storedFailing = failing
    }

    var failing: Bool {
        get { self.lock.withLock { self.storedFailing } }
        set { self.lock.withLock { self.storedFailing = newValue } }
    }

    func remove(_ url: URL) throws {
        if self.failing {
            throw POSIXError(.EACCES)
        }
        try FileManager.default.removeItem(at: url)
    }
}
