import Darwin
import Dispatch
import Foundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct InMemorySnapshotManagerTests {
    @Test
    func `legacy protocol conformer gets non-destructive invalidation default`() async throws {
        let legacyManager: any SnapshotManagerProtocol = UnusedSnapshotManager()

        #expect(!legacyManager.supportsImplicitLatestSnapshotInvalidation)
        #expect(try await legacyManager.invalidateImplicitLatestSnapshot(through: Date()) == nil)
        #expect(InMemorySnapshotManager().supportsImplicitLatestSnapshotInvalidation)
        #expect(SnapshotManager().supportsImplicitLatestSnapshotInvalidation)
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
    func `disk clean all removes incomplete and corrupt snapshot directories`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-incomplete-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let corruptURL = storageURL.appendingPathComponent("corrupt-snapshot", isDirectory: true)
        let stagingURL = storageURL.appendingPathComponent(".pending-abandoned", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try Data("artifact".utf8).write(to: corruptURL.appendingPathComponent("raw.png"))

        let manager = SnapshotManager(snapshotStorageURL: storageURL)
        let count = try await manager.cleanAllSnapshots()

        #expect(count == 2)
        #expect(!FileManager.default.fileExists(atPath: corruptURL.path))
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
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
        try await manager.storeScreenshot(Self.screenshotRequest(snapshotId: "external", path: "/tmp/external.png"))

        let snapshots = try await manager.listSnapshots()
        #expect(snapshots.map(\.id) == ["external"])
        #expect(snapshots.contains { $0.id == first } == false)
    }

    @Test
    func `snapshot cleanup removes managed temporary artifacts`() async throws {
        let snapshotId = "managed-temp"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-see/\(snapshotId)", isDirectory: true)
        let raw = directory.appendingPathComponent("raw.png")
        let annotated = directory.appendingPathComponent("raw_annotated.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: raw)
        try Data("annotated".utf8).write(to: annotated)

        let manager = InMemorySnapshotManager()
        _ = try await manager.createSnapshot()
        try await manager.storeScreenshot(Self.screenshotRequest(snapshotId: snapshotId, path: raw.path))
        try await manager.storeAnnotatedScreenshot(snapshotId: snapshotId, annotatedScreenshotPath: annotated.path)

        try await manager.cleanSnapshot(snapshotId: snapshotId)

        #expect(!FileManager.default.fileExists(atPath: raw.path))
        #expect(!FileManager.default.fileExists(atPath: annotated.path))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
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
            windowBounds: CGRect(x: 10, y: 20, width: 300, height: 200))
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
