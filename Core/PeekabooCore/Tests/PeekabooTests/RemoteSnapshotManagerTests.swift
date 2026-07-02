import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import Testing

struct RemoteSnapshotManagerTests {
    @Test
    @MainActor
    func `remote snapshot storage owns copied screenshot artifacts`() {
        let remote = RemoteSnapshotManager(
            client: PeekabooBridgeClient(socketPath: "/tmp/unused.sock", requestTimeoutSec: 1))

        #expect(remote.copiesScreenshotArtifactsIntoStorage)
    }

    @Test
    func `bridge invalidation payload preserves subsecond cutoff`() throws {
        let cutoff = Date(timeIntervalSinceReferenceDate: 123_456_789.123_456)
        let preservedAt = Date(timeIntervalSinceReferenceDate: 123_456_790.654_321)
        let payload = PeekabooBridgeInvalidateImplicitLatestSnapshotRequest(
            cutoff: cutoff,
            preservingSnapshotId: "snapshot-1",
            preservedAt: preservedAt)

        let data = try JSONEncoder.peekabooBridgeEncoder().encode(payload)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeInvalidateImplicitLatestSnapshotRequest.self,
            from: data)

        #expect(decoded.cutoff == cutoff)
        #expect(decoded.preservingSnapshotId == "snapshot-1")
        #expect(decoded.preservedAt == preservedAt)
    }

    @Test
    func `bridge pending snapshot payload preserves subsecond start`() throws {
        let pendingAt = Date(timeIntervalSinceReferenceDate: 123_456_789.123_456)
        let payload = PeekabooBridgeCreateSnapshotRequest(pendingAt: pendingAt)

        let data = try JSONEncoder.peekabooBridgeEncoder().encode(payload)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeCreateSnapshotRequest.self,
            from: data)

        #expect(decoded.pendingAt == pendingAt)
    }

    @Test
    func `snapshot watermark operation is advertised from protocol 1_9`() {
        let operations: Set<PeekabooBridgeOperation> = [.invalidateImplicitLatestSnapshot]

        #expect(PeekabooBridgeOperation.compatible(
            operations,
            with: .init(major: 1, minor: 8)).isEmpty)
        #expect(PeekabooBridgeOperation.compatible(
            operations,
            with: .init(major: 1, minor: 9)) == operations)
    }

    @Test
    @MainActor
    func `bridge cutoff preserves explicit history and post-mutation snapshots`() async throws {
        let snapshots = InMemorySnapshotManager()
        let olderSnapshotId = try await snapshots.createSnapshot()
        try await snapshots.storeDetectionResult(
            snapshotId: olderSnapshotId,
            result: ElementDetectionResult(
                snapshotId: olderSnapshotId,
                screenshotPath: "/tmp/\(olderSnapshotId).png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "test")))
        let cutoff = Date()
        try await Task.sleep(for: .milliseconds(2))
        let freshSnapshotId = try await snapshots.createSnapshot()
        let server = PeekabooBridgeServer(
            services: PeekabooServices(snapshotManager: snapshots),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let socketPath = "/tmp/peekaboo-snapshot-watermark-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemoteSnapshotManager(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2))

        let invalidatedSnapshotId = try await remote.invalidateImplicitLatestSnapshot(through: cutoff)

        #expect(invalidatedSnapshotId == olderSnapshotId)
        #expect(try await Set(remote.listSnapshots().map(\.id)) == [olderSnapshotId, freshSnapshotId])
        #expect(await remote.getMostRecentSnapshot() == freshSnapshotId)
        #expect(try await remote.getDetectionResult(snapshotId: olderSnapshotId) != nil)
    }

    @Test
    @MainActor
    func `bridge atomically preserves refreshed snapshot unless newer mutation wins`() async throws {
        let snapshots = InMemorySnapshotManager()
        let snapshotId = try await snapshots.createSnapshot()
        let server = PeekabooBridgeServer(
            services: PeekabooServices(snapshotManager: snapshots),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let socketPath = "/tmp/peekaboo-snapshot-preservation-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemoteSnapshotManager(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2))
        let observationStart = Date()

        _ = try await remote.invalidateImplicitLatestSnapshot(
            through: observationStart,
            preserving: snapshotId)
        #expect(await remote.getMostRecentSnapshot() == snapshotId)

        try await Task.sleep(for: .milliseconds(2))
        _ = try await remote.invalidateImplicitLatestSnapshot(through: Date())
        _ = try await remote.invalidateImplicitLatestSnapshot(
            through: observationStart,
            preserving: snapshotId)
        #expect(await remote.getMostRecentSnapshot() == nil)
    }

    @Test
    @MainActor
    func `bridge pending snapshot remains hidden until publication`() async throws {
        let snapshots = InMemorySnapshotManager()
        let server = PeekabooBridgeServer(
            services: PeekabooServices(snapshotManager: snapshots),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let socketPath = "/tmp/peekaboo-pending-snapshot-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemoteSnapshotManager(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2))
        let observationStart = Date()

        let snapshotId = try await remote.createSnapshot(pendingAt: observationStart)
        #expect(try await remote.listSnapshots().isEmpty)
        #expect(await remote.getMostRecentSnapshot() == nil)

        _ = try await remote.invalidateImplicitLatestSnapshot(
            through: observationStart,
            preserving: snapshotId,
            preservedAt: Date())

        #expect(try await remote.listSnapshots().map(\.id) == [snapshotId])
        #expect(await remote.getMostRecentSnapshot() == snapshotId)
    }

    @Test
    @MainActor
    func `legacy bridge rejection preserves all snapshot history`() async throws {
        let snapshots = InMemorySnapshotManager()
        let olderSnapshotId = try await snapshots.createSnapshot()
        let cutoff = Date()
        try await Task.sleep(for: .milliseconds(2))
        let freshSnapshotId = try await snapshots.createSnapshot()
        let services = PeekabooServices(snapshotManager: snapshots)
        var allowedOperations = PeekabooBridgeOperation.remoteDefaultAllowlist
        allowedOperations.remove(.invalidateImplicitLatestSnapshot)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: allowedOperations)
        let socketPath = "/tmp/peekaboo-legacy-snapshot-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemoteSnapshotManager(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2))

        do {
            _ = try await remote.invalidateImplicitLatestSnapshot(through: cutoff)
            Issue.record("Expected unsupported invalidation operation")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .operationNotSupported)
            #expect(envelope.message.contains("update or relaunch"))
        }

        #expect(try await snapshots.listSnapshots().map(\.id) == [freshSnapshotId, olderSnapshotId])
        #expect(await snapshots.getMostRecentSnapshot() == freshSnapshotId)
    }
}
