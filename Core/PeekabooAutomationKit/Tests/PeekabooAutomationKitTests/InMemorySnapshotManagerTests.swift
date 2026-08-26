import Darwin
import Dispatch
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct InMemorySnapshotManagerTests {
    @Test
    func `detection-only identifiers never claim producer-bound snapshot authority`() {
        let transient = SnapshotPublicationBinding.resultIdentifier(explicit: nil)
        let ocrTransient = SnapshotPublicationBinding.resultIdentifier(
            explicit: nil,
            transientPrefix: "ocr")
        let explicit = SnapshotReferenceFixtures.first.rawValue

        #expect(SnapshotReference(rawValue: transient) == nil)
        #expect(SnapshotReference(rawValue: ocrTransient) == nil)
        #expect(ocrTransient.hasPrefix("ocr-"))
        #expect(SnapshotPublicationBinding.resultIdentifier(explicit: explicit) == explicit)
    }

    @Test
    func `failed disk snapshot initialization rolls back producer ownership`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-reservation-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = SnapshotManager(snapshotStorageURL: storageURL)

        for failure in [SnapshotInitializationFailure.configure, .payload] {
            let reservation = try manager.reserveOwnedSnapshotDirectory()
            await #expect(throws: (any Error).self) {
                _ = try await manager.initializeReservedSnapshot(reservation) { snapshotPath in
                    switch failure {
                    case .configure:
                        throw failure
                    case .payload:
                        try FileManager.default.createDirectory(
                            at: snapshotPath.appendingPathComponent("snapshot.json"),
                            withIntermediateDirectories: false)
                    }
                }
            }
            #expect(!FileManager.default.fileExists(atPath: reservation.url.path))
            #expect(try await !manager.ownsSnapshot(snapshotId: reservation.snapshotId))
        }
    }

    @Test
    func `legacy protocol conformer gets non-destructive invalidation default`() async throws {
        let legacyManager: any SnapshotManagerProtocol = UnusedSnapshotManager()

        #expect(!legacyManager.supportsImplicitLatestSnapshotInvalidation)
        #expect(try await legacyManager.invalidateImplicitLatestSnapshot(through: Date()) == nil)
        #expect(InMemorySnapshotManager().supportsImplicitLatestSnapshotInvalidation)
        #expect(SnapshotManager().supportsImplicitLatestSnapshotInvalidation)
    }

    @Test
    func `exact focused element receipt persists in memory and on disk`() async throws {
        try await Self.verifyFocusedElementPersistence(InMemorySnapshotManager())

        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-focus-receipt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        try await Self.verifyFocusedElementPersistence(SnapshotManager(snapshotStorageURL: storageURL))
    }

    @Test
    func `implicit latest invalidation preserves explicit in-memory history`() async throws {
        let manager = InMemorySnapshotManager()
        let snapshotId = try await manager.createSnapshot()
        let result = Self.detectionResult(snapshotId: snapshotId, bundleId: "com.example.old")
        try await manager.storeDetectionResult(snapshotId: snapshotId, result: result)

        let invalidated = try await manager.invalidateImplicitLatestSnapshot()

        #expect(invalidated == snapshotId)
        #expect(await manager.getMostRecentSnapshot() == nil)
        #expect(await manager.getMostRecentSnapshot(applicationBundleId: "com.example.old") == nil)
        #expect(try await manager.listSnapshots().map(\.id) == [snapshotId])
        #expect(try await manager.getDetectionResult(snapshotId: snapshotId)?.snapshotId == snapshotId)

        try await Task.sleep(for: .milliseconds(2))
        let freshSnapshotId = try await manager.createSnapshot()
        #expect(await manager.getMostRecentSnapshot() == freshSnapshotId)
    }

    @Test
    func `implicit latest invalidation persists without deleting disk history`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-snapshot-watermark-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let manager = SnapshotManager(snapshotStorageURL: storageURL)
        let snapshotId = try await manager.createSnapshot()
        let result = Self.detectionResult(snapshotId: snapshotId, bundleId: "com.example.old")
        try await manager.storeDetectionResult(snapshotId: snapshotId, result: result)

        #expect(try await manager.invalidateImplicitLatestSnapshot() == snapshotId)

        let reloadedManager = SnapshotManager(snapshotStorageURL: storageURL)
        #expect(await reloadedManager.getMostRecentSnapshot() == nil)
        #expect(await reloadedManager.getMostRecentSnapshot(applicationBundleId: "com.example.old") == nil)
        #expect(try await reloadedManager.listSnapshots().map(\.id) == [snapshotId])
        #expect(try await reloadedManager.getDetectionResult(snapshotId: snapshotId)?.snapshotId == snapshotId)

        try await Task.sleep(for: .milliseconds(2))
        let freshSnapshotId = try await reloadedManager.createSnapshot()
        #expect(await reloadedManager.getMostRecentSnapshot() == freshSnapshotId)
    }

    @Test
    func `late snapshot writes stay hidden unless atomically preserved`() async throws {
        let memoryManager = InMemorySnapshotManager()
        try await Self.verifyAtomicSnapshotPreservation(memoryManager)

        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-refreshed-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let diskManager = SnapshotManager(snapshotStorageURL: storageURL)
        try await Self.verifyAtomicSnapshotPreservation(diskManager)
    }

    @Test
    func `pending snapshots stay hidden until successful publication`() async throws {
        try await Self.verifyPendingSnapshotPublication(InMemorySnapshotManager())

        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-pending-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        try await Self.verifyPendingSnapshotPublication(SnapshotManager(snapshotStorageURL: storageURL))
    }

    @Test
    func `explicit-only snapshots preserve implicit elements and mutation scope`() async throws {
        try await Self.verifyExplicitOnlySnapshot(InMemorySnapshotManager())

        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-explicit-only-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        try await Self.verifyExplicitOnlySnapshot(SnapshotManager(snapshotStorageURL: storageURL))
    }

    @Test
    func `newer mutation prevents pending snapshot publication`() async throws {
        try await Self.verifyNewerMutationWinsOverPendingSnapshot(InMemorySnapshotManager())

        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-stale-pending-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        try await Self.verifyNewerMutationWinsOverPendingSnapshot(SnapshotManager(snapshotStorageURL: storageURL))
    }

    @Test
    func `preservation timestamp stays stable across retries and app scopes`() async throws {
        let memoryManager = InMemorySnapshotManager()
        try await Self.verifyStablePreservationOrdering(memoryManager)

        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-stable-preservation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let diskManager = SnapshotManager(snapshotStorageURL: storageURL)
        try await Self.verifyStablePreservationOrdering(diskManager)
    }

    @Test
    func `explicit reads do not reorder in-memory latest snapshots`() async throws {
        let manager = InMemorySnapshotManager()
        let bundleId = "com.example.read-order"
        let olderSnapshotId = try await manager.createSnapshot()
        try await manager.storeDetectionResult(
            snapshotId: olderSnapshotId,
            result: Self.detectionResult(snapshotId: olderSnapshotId, bundleId: bundleId))

        try await Task.sleep(for: .milliseconds(2))
        let newerSnapshotId = try await manager.createSnapshot()
        try await manager.storeDetectionResult(
            snapshotId: newerSnapshotId,
            result: Self.detectionResult(snapshotId: newerSnapshotId, bundleId: bundleId))

        try await Task.sleep(for: .milliseconds(2))
        _ = try await manager.getDetectionResult(snapshotId: olderSnapshotId)

        #expect(await manager.getMostRecentSnapshot() == newerSnapshotId)
        #expect(await manager.getMostRecentSnapshot(applicationBundleId: bundleId) == newerSnapshotId)
        #expect(try await manager.invalidateImplicitLatestSnapshot(through: Date()) == newerSnapshotId)
    }

    @Test
    func `explicit reads do not outrank later in-memory preservation publication`() async throws {
        let manager = InMemorySnapshotManager()
        let bundleId = "com.example.preservation-read-order"
        let observationStart = Date()
        let preservedSnapshotId = try await manager.createSnapshot(pendingAt: observationStart)
        try await manager.storeDetectionResult(
            snapshotId: preservedSnapshotId,
            result: Self.detectionResult(snapshotId: preservedSnapshotId, bundleId: bundleId))

        try await Task.sleep(for: .milliseconds(2))
        let duringObservationSnapshotId = try await manager.createSnapshot()
        try await manager.storeDetectionResult(
            snapshotId: duringObservationSnapshotId,
            result: Self.detectionResult(snapshotId: duringObservationSnapshotId, bundleId: bundleId))
        let completedAt = Date()
        _ = try await manager.invalidateImplicitLatestSnapshot(
            through: observationStart,
            preserving: preservedSnapshotId,
            preservedAt: completedAt)

        try await Task.sleep(for: .milliseconds(2))
        _ = try await manager.getDetectionResult(snapshotId: duringObservationSnapshotId)

        #expect(await manager.getMostRecentSnapshot() == preservedSnapshotId)
        #expect(await manager.getMostRecentSnapshot(applicationBundleId: bundleId) == preservedSnapshotId)
        #expect(try await manager.invalidateImplicitLatestSnapshot(through: Date()) == preservedSnapshotId)
    }

    @Test
    func `disk preservation rejects invalid IDs and clears on cleanup`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-safe-preservation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = SnapshotManager(snapshotStorageURL: storageURL)
        let cutoff = Date()
        let completedAt = Date()

        _ = try await manager.invalidateImplicitLatestSnapshot(
            through: cutoff,
            preserving: "",
            preservedAt: completedAt)
        #expect(manager.implicitLatestPreservation() == nil)
        _ = try await manager.invalidateImplicitLatestSnapshot(
            through: cutoff,
            preserving: "../escape",
            preservedAt: completedAt)
        #expect(manager.implicitLatestPreservation() == nil)

        let snapshotId = try await manager.createSnapshot()
        _ = try await manager.invalidateImplicitLatestSnapshot(
            through: Date(),
            preserving: snapshotId,
            preservedAt: Date())
        #expect(manager.implicitLatestPreservation()?.snapshotId == snapshotId)
        try await manager.cleanSnapshot(snapshotId: snapshotId)
        #expect(manager.implicitLatestPreservation() == nil)
    }

    @Test
    func `disk cleanup rejects traversal and terminal symlinks without touching targets`() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-safe-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let storageURL = container.appendingPathComponent("snapshots", isDirectory: true)
        let outsideURL = container.appendingPathComponent("outside", isDirectory: true)
        let siblingURL = storageURL.appendingPathComponent("sibling", isDirectory: true)
        let outsideSentinel = outsideURL.appendingPathComponent("outside-sentinel")
        let siblingSentinel = siblingURL.appendingPathComponent("snapshot.json")
        let outsideContents = Data("outside".utf8)
        let siblingContents = Data("sibling".utf8)

        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingURL, withIntermediateDirectories: true)
        try outsideContents.write(to: outsideSentinel)
        try siblingContents.write(to: siblingSentinel)

        let outsideLink = storageURL.appendingPathComponent("outside-link")
        let siblingLink = storageURL.appendingPathComponent("sibling-link")
        let danglingLink = storageURL.appendingPathComponent("dangling-link")
        let missingTarget = container.appendingPathComponent("missing-target", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: outsideLink, withDestinationURL: outsideURL)
        try FileManager.default.createSymbolicLink(at: siblingLink, withDestinationURL: siblingURL)
        try FileManager.default.createSymbolicLink(at: danglingLink, withDestinationURL: missingTarget)
        let manager = SnapshotManager(snapshotStorageURL: storageURL)

        for snapshotID in [
            "../outside",
            outsideLink.lastPathComponent,
            siblingLink.lastPathComponent,
            danglingLink.lastPathComponent,
        ] {
            await #expect(throws: SnapshotError.self) {
                try await manager.cleanSnapshot(snapshotId: snapshotID)
            }
            #expect(try Data(contentsOf: outsideSentinel) == outsideContents)
            #expect(try Data(contentsOf: siblingSentinel) == siblingContents)
        }

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: outsideLink.path) == outsideURL.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: siblingLink.path) == siblingURL.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: danglingLink.path) == missingTarget.path)
        #expect(!FileManager.default.fileExists(atPath: missingTarget.path))
    }

    @Test
    func `disk clean all removes only producer-owned snapshot directories`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-incomplete-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let corruptURL = storageURL.appendingPathComponent("corrupt-snapshot", isDirectory: true)
        let malformedPendingURL = storageURL.appendingPathComponent(".pending-abandoned", isDirectory: true)
        let legacyPendingURL = storageURL.appendingPathComponent(
            ".pending-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: corruptURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: malformedPendingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyPendingURL, withIntermediateDirectories: true)
        try Data("artifact".utf8).write(to: corruptURL.appendingPathComponent("raw.png"))
        try Data("legacy pending artifact".utf8).write(to: legacyPendingURL.appendingPathComponent("raw.png"))

        let manager = SnapshotManager(snapshotStorageURL: storageURL)
        let owned = try await manager.createSnapshot()
        let count = try await manager.cleanAllSnapshots()

        #expect(count == 2)
        #expect(!FileManager.default.fileExists(atPath: storageURL.appendingPathComponent(owned).path))
        #expect(!FileManager.default.fileExists(atPath: legacyPendingURL.path))
        #expect(FileManager.default.fileExists(atPath: corruptURL.path))
        #expect(FileManager.default.fileExists(atPath: malformedPendingURL.path))
    }

    @Test
    func `out-of-order invalidation cutoffs do not regress watermarks`() async throws {
        let laterCutoff = Date().addingTimeInterval(60)
        let earlierCutoff = laterCutoff.addingTimeInterval(-30)
        let memoryManager = InMemorySnapshotManager()

        _ = try await memoryManager.invalidateImplicitLatestSnapshot(through: laterCutoff)
        _ = try await memoryManager.invalidateImplicitLatestSnapshot(through: earlierCutoff)

        #expect(memoryManager.implicitLatestInvalidatedAt == laterCutoff)

        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-monotonic-watermark-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let diskManager = SnapshotManager(snapshotStorageURL: storageURL)

        _ = try await diskManager.invalidateImplicitLatestSnapshot(through: laterCutoff)
        _ = try await diskManager.invalidateImplicitLatestSnapshot(through: earlierCutoff)

        #expect(diskManager.implicitLatestInvalidationWatermark() == laterCutoff)
        #expect(FileManager.default.fileExists(
            atPath: storageURL.appendingPathComponent(".implicit-latest-invalidation.lock").path))
    }

    @Test
    func `corrupt disk watermark hides old snapshots but allows fresh snapshots`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-corrupt-watermark-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let manager = SnapshotManager(snapshotStorageURL: storageURL)
        let oldSnapshotId = try await manager.createSnapshot()
        try Data("invalid".utf8).write(
            to: storageURL.appendingPathComponent(".implicit-latest-invalidated-at"),
            options: .atomic)

        #expect(await manager.getMostRecentSnapshot() == nil)
        #expect(try await manager.listSnapshots().map(\.id) == [oldSnapshotId])

        try await Task.sleep(for: .milliseconds(2))
        let freshSnapshotId = try await manager.createSnapshot()
        #expect(await manager.getMostRecentSnapshot() == freshSnapshotId)
    }

    @Test
    func `disk latest reader waits for atomic snapshot publication`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-publication-read-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = SnapshotManager(snapshotStorageURL: storageURL)
        let observationStart = Date()
        let snapshotId = try await manager.createSnapshot(pendingAt: observationStart)
        try await manager.storeDetectionResult(
            snapshotId: snapshotId,
            result: Self.detectionResult(snapshotId: snapshotId, bundleId: "com.example.publication"))
        let publication = try Self.beginInterruptedDiskPublication(
            storageURL: storageURL,
            snapshotId: snapshotId,
            cutoff: observationStart,
            preservedAt: Date())

        let latest = await manager.getMostRecentSnapshot()
        try await publication.value

        #expect(latest == snapshotId)
    }

    @Test
    func `disk app-scoped latest reader waits for atomic snapshot publication`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-app-publication-read-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = SnapshotManager(snapshotStorageURL: storageURL)
        let observationStart = Date()
        let snapshotId = try await manager.createSnapshot(pendingAt: observationStart)
        try await manager.storeDetectionResult(
            snapshotId: snapshotId,
            result: Self.detectionResult(snapshotId: snapshotId, bundleId: "com.example.publication"))
        let publication = try Self.beginInterruptedDiskPublication(
            storageURL: storageURL,
            snapshotId: snapshotId,
            cutoff: observationStart,
            preservedAt: Date())

        let latest = await manager.getMostRecentSnapshot(applicationBundleId: "com.example.publication")
        try await publication.value

        #expect(latest == snapshotId)
    }

    @Test
    func `disk preservation reader waits for atomic snapshot publication`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-preservation-read-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = SnapshotManager(snapshotStorageURL: storageURL)
        let observationStart = Date()
        let snapshotId = try await manager.createSnapshot(pendingAt: observationStart)
        let publication = try Self.beginInterruptedDiskPublication(
            storageURL: storageURL,
            snapshotId: snapshotId,
            cutoff: observationStart,
            preservedAt: Date())

        let preservation = manager.implicitLatestPreservation()
        try await publication.value

        #expect(preservation?.snapshotId == snapshotId)
    }

    @Test
    func `createSnapshot prunes overflow immediately and deletes artifacts`() async throws {
        let artifact = try Self.createTemporaryArtifact(named: "overflow-prune.png")
        let manager = InMemorySnapshotManager(options: .init(maxSnapshots: 1, deleteArtifactsOnCleanup: true))

        let first = try await manager.createSnapshot()
        try await manager.storeScreenshot(Self.screenshotRequest(snapshotId: first, path: artifact.path))
        try await Task.sleep(nanoseconds: 1_000_000)

        let second = try await manager.createSnapshot()

        let snapshots = try await manager.listSnapshots()
        #expect(snapshots.map(\.id) == [second])
        #expect(!FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test
    func `storeScreenshot prunes overflow immediately`() async throws {
        let manager = InMemorySnapshotManager(options: .init(maxSnapshots: 1))

        let first = try await manager.createSnapshot()
        try await Task.sleep(nanoseconds: 1_000_000)
        let second = try await manager.createSnapshot()
        try await manager.storeScreenshot(Self.screenshotRequest(snapshotId: second, path: "/tmp/external.png"))

        let snapshots = try await manager.listSnapshots()
        #expect(snapshots.map(\.id) == [second])
        #expect(snapshots.contains { $0.id == first } == false)
    }

    @Test
    func `snapshot cleanup removes managed temporary artifacts`() async throws {
        let manager = InMemorySnapshotManager()
        let snapshotId = try await manager.createSnapshot()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-see/\(snapshotId)", isDirectory: true)
        let raw = directory.appendingPathComponent("raw.png")
        let annotated = directory.appendingPathComponent("raw_annotated.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: raw)
        try Data("annotated".utf8).write(to: annotated)

        try await manager.storeScreenshot(Self.screenshotRequest(snapshotId: snapshotId, path: raw.path))
        try await manager.storeAnnotatedScreenshot(snapshotId: snapshotId, annotatedScreenshotPath: annotated.path)

        try await manager.cleanSnapshot(snapshotId: snapshotId)

        #expect(!FileManager.default.fileExists(atPath: raw.path))
        #expect(!FileManager.default.fileExists(atPath: annotated.path))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test
    func `producer-bound references own only explicitly created snapshots`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-owned-snapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let managers: [any SnapshotManagerProtocol] = [
            InMemorySnapshotManager(),
            SnapshotManager(snapshotStorageURL: storageURL),
        ]

        for manager in managers {
            let owned = try await manager.createSnapshot()
            #expect(SnapshotReference(rawValue: owned) != nil)
            #expect(try await manager.ownsSnapshot(snapshotId: owned))
            #expect(try await !manager.ownsSnapshot(snapshotId: SnapshotReferenceFixtures.id(99)))
            try await manager.cleanSnapshot(snapshotId: owned)
            #expect(try await !manager.ownsSnapshot(snapshotId: owned))
            await #expect(throws: SnapshotError.self) {
                _ = try await manager.ownsSnapshot(snapshotId: "snapshot-1")
            }
        }
    }

    @Test
    func `disk ownership survives manager restart`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-owned-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let snapshotID = try await SnapshotManager(snapshotStorageURL: storageURL).createSnapshot()
        let restarted = SnapshotManager(snapshotStorageURL: storageURL)

        #expect(try await restarted.ownsSnapshot(snapshotId: snapshotID))
        #expect(try await restarted.listSnapshots().map(\.id) == [snapshotID])
    }

    @Test
    func `disk caller local namespace is one producer across manager instances`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-owned-namespace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let first = SnapshotManager(snapshotStorageURL: storageURL)
        let second = SnapshotManager(snapshotStorageURL: storageURL)
        let snapshotID = try await first.createSnapshot()

        #expect(try await first.ownsSnapshot(snapshotId: snapshotID))
        #expect(try await second.ownsSnapshot(snapshotId: snapshotID))

        let lease = try await first.beginSnapshotMutation(snapshotId: snapshotID)
        await #expect(throws: PeekabooError.self) {
            _ = try await second.beginSnapshotMutation(snapshotId: snapshotID)
        }
        try await first.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    func `containing factory seeds one fixture and remains reusable`() async throws {
        let fixture = AutomationTestFixtures.detectionResult(snapshotID: SnapshotReferenceFixtures.first.rawValue)
        let manager = try await InMemorySnapshotManager.containing(fixture)

        #expect(try await manager.ownsSnapshot(snapshotId: SnapshotReferenceFixtures.first.rawValue))
        let next = try await manager.createSnapshot()
        #expect(next != SnapshotReferenceFixtures.first.rawValue)
        #expect(SnapshotReference(rawValue: next) != nil)
    }

    @Test
    func `legacy seeded initializer remains source compatible and rejects malformed authority`() async throws {
        let fixture = AutomationTestFixtures.detectionResult(snapshotID: SnapshotReferenceFixtures.first.rawValue)
        let manager = InMemorySnapshotManager(detectionResult: fixture)

        #expect(try await manager.ownsSnapshot(snapshotId: SnapshotReferenceFixtures.first.rawValue))
        let next = try await manager.createSnapshot()
        #expect(next != SnapshotReferenceFixtures.first.rawValue)

        let malformed = AutomationTestFixtures.detectionResult(snapshotID: "snapshot-1")
        let rejected = InMemorySnapshotManager(detectionResult: malformed)
        #expect(try await rejected.listSnapshots().isEmpty)
    }

    @Test
    func `legacy seeded initializer rejects mismatched embedded coordinate authority`() async throws {
        let snapshotID = SnapshotReferenceFixtures.first.rawValue
        let malformed = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "fixture",
                truncationInfo: nil,
                captureCoordinateContext: CaptureCoordinateContext(
                    metadata: CaptureMetadata(size: .init(width: 10, height: 10), mode: .screen),
                    referenceID: SnapshotReferenceFixtures.second.rawValue)))

        let manager = InMemorySnapshotManager(detectionResult: malformed)

        #expect(try await manager.listSnapshots().isEmpty)
        #expect(try await !manager.ownsSnapshot(snapshotId: snapshotID))
    }

    @Test
    func `stores require prior ownership and exact embedded references`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-store-authority-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let managers: [any SnapshotManagerProtocol] = [
            InMemorySnapshotManager(),
            SnapshotManager(snapshotStorageURL: storageURL),
        ]

        for manager in managers {
            let foreign = SnapshotReferenceFixtures.id(81)
            await #expect(throws: SnapshotError.self) {
                try await manager.storeScreenshot(Self.screenshotRequest(
                    snapshotId: foreign,
                    path: "/tmp/foreign.png"))
            }

            let owned = try await manager.createSnapshot()
            let mismatched = ElementDetectionResult(
                snapshotId: SnapshotReferenceFixtures.id(82),
                screenshotPath: "",
                elements: DetectedElements(),
                metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "fixture"))
            await #expect(throws: SnapshotError.self) {
                try await manager.storeDetectionResult(snapshotId: owned, result: mismatched)
            }
            await #expect(throws: SnapshotError.self) {
                try await manager.storeObservationSnapshot(.init(
                    screenshot: Self.screenshotRequest(snapshotId: owned, path: "/tmp/owned.png"),
                    detectionResult: mismatched,
                    annotatedScreenshotPath: nil))
            }
            let mismatchedCoordinateResult = ElementDetectionResult(
                snapshotId: owned,
                screenshotPath: "",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "fixture",
                    truncationInfo: nil,
                    captureCoordinateContext: CaptureCoordinateContext(
                        metadata: CaptureMetadata(size: .init(width: 10, height: 10), mode: .screen),
                        referenceID: SnapshotReferenceFixtures.id(83))))
            await #expect(throws: SnapshotError.self) {
                try await manager.storeDetectionResult(snapshotId: owned, result: mismatchedCoordinateResult)
            }
            let persistedDetection = try await manager.getDetectionResult(snapshotId: owned)
            #expect(persistedDetection?.snapshotId != mismatched.snapshotId)
            #expect(persistedDetection?.elements.all.isEmpty ?? true)
            #expect(try await manager.getUIAutomationSnapshot(snapshotId: owned)?.screenshotPath == nil)
        }
    }

    @Test
    func `reference generators retry collisions and fail after a bounded exhaustion`() async throws {
        let retrySequence = SnapshotReferenceSequence([
            SnapshotReferenceFixtures.first,
            SnapshotReferenceFixtures.first,
            SnapshotReferenceFixtures.second,
        ])
        let retrying = InMemorySnapshotManager(snapshotReferenceGenerator: { retrySequence.next() })
        #expect(try await retrying.createSnapshot() == SnapshotReferenceFixtures.first.rawValue)
        #expect(try await retrying.createSnapshot() == SnapshotReferenceFixtures.second.rawValue)

        let exhausted = InMemorySnapshotManager(
            snapshotReferenceGenerator: { SnapshotReferenceFixtures.third })
        #expect(try await exhausted.createSnapshot() == SnapshotReferenceFixtures.third.rawValue)
        await #expect(throws: SnapshotError.self) {
            _ = try await exhausted.createSnapshot()
        }

        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-collision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let disk = SnapshotManager(
            snapshotStorageURL: storageURL,
            snapshotReferenceGenerator: { SnapshotReferenceFixtures.first })
        #expect(try await disk.createSnapshot() == SnapshotReferenceFixtures.first.rawValue)
        await #expect(throws: SnapshotError.self) {
            _ = try await disk.createSnapshot()
        }

        let retryStorageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-disk-collision-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: retryStorageURL) }
        let diskRetrySequence = SnapshotReferenceSequence([
            SnapshotReferenceFixtures.first,
            SnapshotReferenceFixtures.first,
            SnapshotReferenceFixtures.second,
        ])
        let retryingDisk = SnapshotManager(
            snapshotStorageURL: retryStorageURL,
            snapshotReferenceGenerator: { diskRetrySequence.next() })
        #expect(try await retryingDisk.createSnapshot() == SnapshotReferenceFixtures.first.rawValue)
        #expect(try await retryingDisk.createSnapshot() == SnapshotReferenceFixtures.second.rawValue)
    }

    @Test
    func `legacy timestamp directories are cleanup-only for disk managers`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-legacy-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let legacyID = "1787675983803-1514"
        let legacyURL = storageURL.appendingPathComponent(legacyID, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: legacyURL.appendingPathComponent("snapshot.json"))
        let manager = SnapshotManager(snapshotStorageURL: storageURL)

        #expect(try await manager.listSnapshots().isEmpty)
        await #expect(throws: SnapshotError.self) {
            _ = try await manager.ownsSnapshot(snapshotId: legacyID)
        }
        #expect(try await manager.cleanAllSnapshots() == 1)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test
    func `legacy and unowned directories cannot shadow latest owned snapshot`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-latest-ownership-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let manager = SnapshotManager(
            snapshotStorageURL: storageURL,
            snapshotReferenceGenerator: { SnapshotReferenceFixtures.first })
        let owned = try await manager.createSnapshot()
        try await Task.sleep(for: .milliseconds(2))

        for snapshotID in ["1787675983803-1514", SnapshotReferenceFixtures.id(88)] {
            let directory = storageURL.appendingPathComponent(snapshotID, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("{}".utf8).write(to: directory.appendingPathComponent("snapshot.json"))
        }

        #expect(await manager.getMostRecentSnapshot() == owned)
        #expect(try await manager.listSnapshots().map(\.id) == [owned])
    }

    @Test
    func `disk payload symlink is never actionable or followed`() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-payload-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let storageURL = container.appendingPathComponent("snapshots", isDirectory: true)
        let outsideURL = container.appendingPathComponent("outside.json")
        let outsideContents = Data("outside".utf8)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        try outsideContents.write(to: outsideURL)
        let manager = SnapshotManager(snapshotStorageURL: storageURL)
        let snapshotID = try await manager.createSnapshot()
        let payloadURL = storageURL.appendingPathComponent(snapshotID).appendingPathComponent("snapshot.json")
        try FileManager.default.removeItem(at: payloadURL)
        try FileManager.default.createSymbolicLink(at: payloadURL, withDestinationURL: outsideURL)

        #expect(try await manager.ownsSnapshot(snapshotId: snapshotID))
        #expect(try await manager.getDetectionResult(snapshotId: snapshotID) == nil)
        #expect(await manager.getMostRecentSnapshot() == nil)
        #expect(try await manager.listSnapshots().isEmpty)
        #expect(try Data(contentsOf: outsideURL) == outsideContents)

        #expect(try await manager.cleanAllSnapshots() == 1)
        #expect(try Data(contentsOf: outsideURL) == outsideContents)
    }

    @Test
    func `disk store cannot resurrect a snapshot cleaned after ownership load`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-store-clean-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let entered = SnapshotTestLatch()
        let resume = SnapshotTestLatch()
        let manager = SnapshotManager(
            snapshotStorageURL: storageURL,
            postLoadBarrier: {
                await entered.open()
                await resume.wait()
            })
        let snapshotID = try await manager.createSnapshot()
        let store = Task { @MainActor in
            try await manager.storeDetectionResult(
                snapshotId: snapshotID,
                result: AutomationTestFixtures.detectionResult(snapshotID: snapshotID))
        }

        await entered.wait()
        try FileManager.default.removeItem(at: storageURL.appendingPathComponent(snapshotID))
        await resume.open()
        await #expect(throws: SnapshotError.self) {
            try await store.value
        }
        #expect(!FileManager.default.fileExists(atPath: storageURL.appendingPathComponent(snapshotID).path))
        #expect(try await !manager.ownsSnapshot(snapshotId: snapshotID))
    }

    @Test
    func `snapshot cleanup preserves borrowed screenshot artifacts`() async throws {
        let artifact = try Self.createTemporaryArtifact(named: "borrowed-screenshot.png")
        defer { try? FileManager.default.removeItem(at: artifact) }
        let manager = InMemorySnapshotManager()
        let snapshotId = try await manager.createSnapshot()
        try await manager.storeScreenshot(Self.screenshotRequest(snapshotId: snapshotId, path: artifact.path))

        try await manager.cleanSnapshot(snapshotId: snapshotId)

        #expect(FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test
    func `getDetectionResult preserves window context for action re-resolution`() async throws {
        let manager = InMemorySnapshotManager()
        let snapshotId = try await manager.createSnapshot()
        let context = WindowContext(
            applicationName: "Calculator",
            applicationBundleId: "com.apple.calculator",
            applicationProcessId: 123,
            windowTitle: "Calculator",
            windowID: 456,
            windowBounds: CGRect(x: 10, y: 20, width: 300, height: 200),
            windowMutationIdentity: WindowMutationIdentity(
                windowID: 456,
                ownerProcessIdentifier: 123,
                ownerProcessStartIdentity: 789))
        let element = DetectedElement(
            id: "elem_1",
            type: .button,
            label: "Clear",
            bounds: CGRect(x: 30, y: 40, width: 50, height: 30),
            attributes: ["identifier": "Clear"])
        let result = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/calc.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: context))

        try await manager.storeDetectionResult(snapshotId: snapshotId, result: result)

        let hydrated = try await manager.getDetectionResult(snapshotId: snapshotId)
        #expect(hydrated?.metadata.windowContext?.applicationBundleId == "com.apple.calculator")
        #expect(hydrated?.metadata.windowContext?.applicationProcessId == 123)
        #expect(hydrated?.metadata.windowContext?.windowTitle == "Calculator")
        #expect(hydrated?.metadata.windowContext?.windowID == 456)
        #expect(hydrated?.metadata.windowContext?.windowBounds == CGRect(x: 10, y: 20, width: 300, height: 200))
        #expect(hydrated?.metadata.windowContext?.windowMutationIdentity == WindowMutationIdentity(
            windowID: 456,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 789))
    }

    private static func screenshotRequest(snapshotId: String, path: String) -> SnapshotScreenshotRequest {
        SnapshotScreenshotRequest(
            snapshotId: snapshotId,
            screenshotPath: path,
            applicationBundleId: nil,
            applicationProcessId: nil,
            applicationName: nil,
            windowTitle: nil,
            windowBounds: nil)
    }

    private static func verifyAtomicSnapshotPreservation(
        _ manager: any SnapshotManagerProtocol) async throws
    {
        let snapshotId = try await manager.createSnapshot()
        try await manager.storeDetectionResult(
            snapshotId: snapshotId,
            result: self.detectionResult(snapshotId: snapshotId, bundleId: "com.example.refreshed"))
        _ = try await manager.invalidateImplicitLatestSnapshot()
        #expect(await manager.getMostRecentSnapshot() == nil)

        try await Task.sleep(for: .milliseconds(2))
        try await manager.storeDetectionResult(
            snapshotId: snapshotId,
            result: self.detectionResult(snapshotId: snapshotId, bundleId: "com.example.refreshed"))

        #expect(await manager.getMostRecentSnapshot() == nil)

        let observationStart = Date()
        let preservedAt = observationStart.addingTimeInterval(60)
        _ = try await manager.invalidateImplicitLatestSnapshot(
            through: observationStart,
            preserving: snapshotId,
            preservedAt: preservedAt)
        #expect(await manager.getMostRecentSnapshot() == snapshotId)
        #expect(await manager.getMostRecentSnapshot(applicationBundleId: "com.example.refreshed") == snapshotId)

        let laterMutation = observationStart.addingTimeInterval(1)
        _ = try await manager.invalidateImplicitLatestSnapshot(through: laterMutation)
        #expect(await manager.getMostRecentSnapshot() == nil)

        _ = try await manager.invalidateImplicitLatestSnapshot(
            through: observationStart,
            preserving: snapshotId,
            preservedAt: preservedAt)
        #expect(await manager.getMostRecentSnapshot() == nil)

        let reservedSnapshotId = try await manager.createSnapshot()
        try await Task.sleep(for: .milliseconds(2))
        _ = try await manager.invalidateImplicitLatestSnapshot(through: Date())
        try await manager.storeDetectionResult(
            snapshotId: reservedSnapshotId,
            result: self.detectionResult(snapshotId: reservedSnapshotId, bundleId: "com.example.delayed"))
        #expect(await manager.getMostRecentSnapshot() == nil)
    }

    private static func verifyPendingSnapshotPublication(
        _ manager: any SnapshotManagerProtocol) async throws
    {
        let observationStart = Date()
        let snapshotId = try await manager.createSnapshot(pendingAt: observationStart)
        try await manager.storeDetectionResult(
            snapshotId: snapshotId,
            result: self.detectionResult(snapshotId: snapshotId, bundleId: "com.example.pending"))

        #expect(await manager.getMostRecentSnapshot() == nil)
        #expect(try await manager.listSnapshots().isEmpty)
        #expect(try await manager.getDetectionResult(snapshotId: snapshotId)?.snapshotId == snapshotId)

        _ = try await manager.invalidateImplicitLatestSnapshot(
            through: observationStart,
            preserving: snapshotId,
            preservedAt: Date())

        #expect(await manager.getMostRecentSnapshot() == snapshotId)
        #expect(await manager.getMostRecentSnapshot(applicationBundleId: "com.example.pending") == snapshotId)
        #expect(try await manager.listSnapshots().map(\.id) == [snapshotId])
    }

    private static func verifyExplicitOnlySnapshot(
        _ manager: any SnapshotManagerProtocol) async throws
    {
        let priorSnapshotID = try await manager.createSnapshot()
        let priorElement = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 20, y: 30, width: 80, height: 30))
        try await manager.storeDetectionResult(
            snapshotId: priorSnapshotID,
            result: ElementDetectionResult(
                snapshotId: priorSnapshotID,
                screenshotPath: "/tmp/prior.png",
                elements: DetectedElements(buttons: [priorElement]),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 1,
                    method: "test",
                    windowContext: WindowContext(applicationBundleId: "com.example.prior"))))

        let artifact = try self.createTemporaryArtifact(named: "explicit-only.png")
        defer { try? FileManager.default.removeItem(at: artifact.deletingLastPathComponent()) }
        let explicitSnapshotID = try await manager.createExplicitSnapshot()
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 456,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 789,
            capturedBounds: bounds)
        try await manager.storeScreenshot(SnapshotScreenshotRequest(
            snapshotId: explicitSnapshotID,
            screenshotPath: artifact.path,
            applicationBundleId: "com.example.explicit",
            applicationProcessId: 123,
            applicationName: "Explicit",
            windowTitle: "Explicit Window",
            windowBounds: bounds,
            windowID: 456,
            windowMutationIdentity: identity))

        #expect(await manager.getMostRecentSnapshot() == priorSnapshotID)
        #expect(await manager.getMostRecentSnapshot(applicationBundleId: "com.example.prior") == priorSnapshotID)
        #expect(await manager.getMostRecentSnapshot(applicationBundleId: "com.example.explicit") == nil)
        #expect(try await Set(manager.listSnapshots().map(\.id)) == [priorSnapshotID, explicitSnapshotID])
        let explicit = try #require(try await manager.getDetectionResult(snapshotId: explicitSnapshotID))
        #expect(explicit.elements.all.isEmpty)
        #expect(explicit.metadata.windowContext?.windowMutationIdentity == identity)

        let lease = try await manager.beginSnapshotMutation(snapshotId: explicitSnapshotID)
        try await manager.finishSnapshotMutation(lease, requiresFreshObservation: true)
        await #expect(throws: PeekabooError.self) {
            _ = try await manager.beginSnapshotMutation(snapshotId: explicitSnapshotID)
        }
        #expect(await manager.getMostRecentSnapshot() == priorSnapshotID)

        #expect(try await manager.invalidateImplicitLatestSnapshot(through: Date()) == priorSnapshotID)
        #expect(await manager.getMostRecentSnapshot() == nil)
        #expect(try await manager.getDetectionResult(snapshotId: explicitSnapshotID)?.snapshotId == explicitSnapshotID)
    }

    private static func verifyNewerMutationWinsOverPendingSnapshot(
        _ manager: any SnapshotManagerProtocol) async throws
    {
        let observationStart = Date()
        let snapshotId = try await manager.createSnapshot(pendingAt: observationStart)
        try await manager.storeDetectionResult(
            snapshotId: snapshotId,
            result: self.detectionResult(snapshotId: snapshotId, bundleId: "com.example.stale"))
        _ = try await manager.invalidateImplicitLatestSnapshot(
            through: observationStart.addingTimeInterval(1))
        _ = try await manager.invalidateImplicitLatestSnapshot(
            through: observationStart,
            preserving: snapshotId,
            preservedAt: Date())

        #expect(await manager.getMostRecentSnapshot() == nil)
        #expect(try await manager.listSnapshots().map(\.id) == [snapshotId])
    }

    private static func verifyStablePreservationOrdering(
        _ manager: any SnapshotManagerProtocol) async throws
    {
        let oldSnapshotId = try await manager.createSnapshot()
        try await manager.storeDetectionResult(
            snapshotId: oldSnapshotId,
            result: self.detectionResult(snapshotId: oldSnapshotId, bundleId: "com.example.old"))
        let observationStart = Date()
        let completedAt = Date()
        _ = try await manager.invalidateImplicitLatestSnapshot(
            through: observationStart,
            preserving: oldSnapshotId,
            preservedAt: completedAt)

        try await Task.sleep(for: .milliseconds(2))
        let newSnapshotId = try await manager.createSnapshot()
        try await manager.storeDetectionResult(
            snapshotId: newSnapshotId,
            result: self.detectionResult(snapshotId: newSnapshotId, bundleId: "com.example.new"))

        _ = try await manager.invalidateImplicitLatestSnapshot(
            through: observationStart,
            preserving: oldSnapshotId,
            preservedAt: completedAt)

        #expect(await manager.getMostRecentSnapshot() == newSnapshotId)
        #expect(await manager.getMostRecentSnapshot(applicationBundleId: "com.example.old") == oldSnapshotId)
    }

    private static func detectionResult(snapshotId: String, bundleId: String) -> ElementDetectionResult {
        ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/\(snapshotId).png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "test",
                windowContext: WindowContext(applicationBundleId: bundleId)))
    }

    private static func verifyFocusedElementPersistence(
        _ manager: any SnapshotManagerProtocol) async throws
    {
        let snapshotID = try await manager.createSnapshot()
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let focused = FocusedElementIdentity(
            processIdentifier: 701,
            windowID: 43,
            role: "AXTextField",
            identifier: "editor",
            frame: CGRect(x: 40, y: 60, width: 200, height: 30))
        let identity = WindowMutationIdentity(
            windowID: 43,
            ownerProcessIdentifier: 701,
            ownerProcessStartIdentity: 100,
            capturedBounds: bounds)
        try await manager.storeDetectionResult(
            snapshotId: snapshotID,
            result: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "/tmp/\(snapshotID).png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "test",
                    windowContext: WindowContext(
                        applicationName: "Editor",
                        applicationProcessId: 701,
                        windowTitle: "Document",
                        windowID: 43,
                        windowBounds: bounds,
                        windowMutationIdentity: identity,
                        focusedElement: focused))))

        let stored = try #require(try await manager.getUIAutomationSnapshot(snapshotId: snapshotID))
        #expect(stored.focusedElement == focused)
        #expect(try await manager.getDetectionResult(snapshotId: snapshotID)?.metadata.windowContext?.focusedElement ==
            focused)
    }

    private static func beginInterruptedDiskPublication(
        storageURL: URL,
        snapshotId: String,
        cutoff: Date,
        preservedAt: Date) throws -> Task<Void, any Error>
    {
        let ready = DispatchSemaphore(value: 0)
        let task = Task.detached {
            var signaled = false
            defer {
                if !signaled {
                    ready.signal()
                }
            }

            let lockURL = storageURL.appendingPathComponent(".implicit-latest-invalidation.lock")
            let descriptor = open(
                lockURL.path,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: lockURL.path])
            }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: lockURL.path])
            }
            defer { _ = flock(descriptor, LOCK_UN) }

            try JSONEncoder().encode(cutoff).write(
                to: storageURL.appendingPathComponent(".implicit-latest-invalidated-at"),
                options: .atomic)
            try FileManager.default.removeItem(
                at: storageURL.appendingPathComponent(snapshotId).appendingPathComponent(".pending"))
            signaled = true
            ready.signal()

            try await Task.sleep(for: .milliseconds(100))
            let preservation = SnapshotImplicitLatestPreservation(
                snapshotId: snapshotId,
                invalidatedThrough: cutoff,
                preservedAt: preservedAt)
            try JSONEncoder().encode(preservation).write(
                to: storageURL.appendingPathComponent(".implicit-latest-preserved-snapshot"),
                options: .atomic)
        }

        guard ready.wait(timeout: .now() + 2) == .success else {
            task.cancel()
            throw NSError(
                domain: "PeekabooSnapshotPublicationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for partial snapshot publication"])
        }
        return task
    }

    private static func createTemporaryArtifact(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("artifact".utf8).write(to: url)
        return url
    }
}

private enum SnapshotInitializationFailure: Error {
    case configure
    case payload
}

@MainActor
private final class SnapshotReferenceSequence: @unchecked Sendable {
    private let references: [SnapshotReference]
    private var index = 0

    init(_ references: [SnapshotReference]) {
        self.references = references
    }

    func next() -> SnapshotReference {
        let reference = self.references[min(self.index, self.references.count - 1)]
        self.index += 1
        return reference
    }
}

private actor SnapshotTestLatch {
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
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
