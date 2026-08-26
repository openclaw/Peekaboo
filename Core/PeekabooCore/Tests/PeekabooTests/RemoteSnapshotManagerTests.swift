import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing

struct RemoteSnapshotManagerTests {
    @Test
    @MainActor
    func `remote snapshot storage owns copied screenshot artifacts`() {
        let legacy = RemoteSnapshotManager(
            client: PeekabooBridgeClient(socketPath: "/tmp/unused.sock", requestTimeoutSec: 1))
        let current = RemoteSnapshotManager(
            client: PeekabooBridgeClient(socketPath: "/tmp/unused.sock", requestTimeoutSec: 1),
            supportsSnapshotMutationLeases: true,
            supportsProducerBoundSnapshotReferences: true)

        #expect(legacy.copiesScreenshotArtifactsIntoStorage)
        #expect(!legacy.supportsSnapshotMutationLeases)
        #expect(current.supportsSnapshotMutationLeases)
        #expect(current.supportsProducerBoundSnapshotReferences)
    }

    @Test
    @MainActor
    func `new client refuses explicit-only publication on an old host before transport`() async {
        let oldHost = RemoteSnapshotManager(
            client: PeekabooBridgeClient(socketPath: "/tmp/unused.sock", requestTimeoutSec: 1),
            supportsExplicitSnapshotPublication: false)

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await oldHost.createExplicitSnapshot()
        }
    }

    @Test
    @MainActor
    func `new client refuses ordinary publication on an old host before transport`() async {
        let oldHost = RemoteSnapshotManager(
            client: PeekabooBridgeClient(socketPath: "/tmp/unused.sock", requestTimeoutSec: 1),
            supportsProducerBoundSnapshotReferences: false)

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await oldHost.createSnapshot()
        }
    }

    @Test
    func `bridge invalidation payload preserves subsecond cutoff`() throws {
        let cutoff = Date(timeIntervalSinceReferenceDate: 123_456_789.123_456)
        let preservedAt = Date(timeIntervalSinceReferenceDate: 123_456_790.654_321)
        let payload = PeekabooBridgeInvalidateImplicitLatestSnapshotRequest(
            cutoff: cutoff,
            preservingSnapshotId: SnapshotReferenceFixtures.first.rawValue,
            preservedAt: preservedAt)

        let data = try JSONEncoder.peekabooBridgeEncoder().encode(payload)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeInvalidateImplicitLatestSnapshotRequest.self,
            from: data)

        #expect(decoded.cutoff == cutoff)
        #expect(decoded.preservingSnapshotId == SnapshotReferenceFixtures.first.rawValue)
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
    func `bridge explicit-only snapshot payload round trips additive fields`() throws {
        let payload = PeekabooBridgeCreateSnapshotRequest(explicitOnly: true)

        let data = try JSONEncoder.peekabooBridgeEncoder().encode(payload)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeCreateSnapshotRequest.self,
            from: data)

        #expect(decoded.pendingAt == nil)
        #expect(decoded.explicitOnly == true)
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
    func `snapshot mutation leases are advertised from protocol 1_24`() {
        let operations: Set<PeekabooBridgeOperation> = [.beginSnapshotMutation, .finishSnapshotMutation]

        #expect(PeekabooBridgeOperation.compatible(
            operations,
            with: .init(major: 1, minor: 23)).isEmpty)
        #expect(PeekabooBridgeOperation.compatible(
            operations,
            with: .init(major: 1, minor: 24)) == operations)
    }

    @Test
    @MainActor
    func `remote manager forwards canonical ownership and creation`() async throws {
        let snapshots = InMemorySnapshotManager()
        let owned = try await snapshots.createSnapshot()
        let server = PeekabooBridgeServer(
            services: PeekabooServices(snapshotManager: snapshots),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let socketPath = "/tmp/peekaboo-remote-snapshot-owner-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = try await RemoteSnapshotManager(
            client: Self.currentClient(socketPath: socketPath),
            supportsProducerBoundSnapshotReferences: true)

        #expect(try await remote.ownsSnapshot(snapshotId: owned))
        #expect(try await !remote.ownsSnapshot(snapshotId: SnapshotReferenceFixtures.id(99)))
        let created = try await remote.createSnapshot()
        #expect(SnapshotReference(rawValue: created) != nil)
        #expect(try await snapshots.ownsSnapshot(snapshotId: created))
        await host.stop()
    }

    @Test
    @MainActor
    func `bridge mutation lease blocks reuse without deleting snapshot evidence`() async throws {
        let snapshots = InMemorySnapshotManager()
        let snapshotId = try await snapshots.createSnapshot()
        try await snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: ElementDetectionResult(
                snapshotId: snapshotId,
                screenshotPath: "/tmp/\(snapshotId).png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "test")))
        let server = PeekabooBridgeServer(
            services: PeekabooServices(snapshotManager: snapshots),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let socketPath = "/tmp/peekaboo-snapshot-lease-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = try await RemoteSnapshotManager(
            client: Self.currentClient(socketPath: socketPath),
            supportsProducerBoundSnapshotReferences: true)

        let lease = try await remote.beginSnapshotMutation(snapshotId: snapshotId)
        try await remote.finishSnapshotMutation(lease, requiresFreshObservation: true)

        #expect(try await remote.getDetectionResult(snapshotId: snapshotId) != nil)
        do {
            _ = try await remote.beginSnapshotMutation(snapshotId: snapshotId)
            Issue.record("Expected Bridge to refuse a consumed snapshot")
        } catch let PeekabooError.snapshotStale(message) {
            #expect(message.contains("fresh observation"))
        }
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
        let remote = try await RemoteSnapshotManager(
            client: Self.currentClient(socketPath: socketPath))

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
        let remote = try await RemoteSnapshotManager(
            client: Self.currentClient(socketPath: socketPath))
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
        let remote = try await RemoteSnapshotManager(
            client: Self.currentClient(socketPath: socketPath),
            supportsProducerBoundSnapshotReferences: true)
        let observationStart = Date()

        let snapshotId = try await remote.createSnapshot(pendingAt: observationStart)
        #expect(SnapshotReference(rawValue: snapshotId) != nil)
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
    func `bridge explicit-only snapshot remains listed but never implicit latest`() async throws {
        let snapshots = InMemorySnapshotManager()
        let priorSnapshotID = try await snapshots.createSnapshot()
        let server = PeekabooBridgeServer(
            services: PeekabooServices(snapshotManager: snapshots),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let socketPath = "/tmp/peekaboo-explicit-only-snapshot-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let clientIdentity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "boo.peekaboo.tests",
            teamIdentifier: nil,
            processIdentifier: getpid())
        let currentClient = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let remote = RemoteSnapshotManager(
            client: currentClient,
            supportsImplicitLatestSnapshotInvalidation: true,
            supportsSnapshotMutationLeases: true,
            supportsExplicitSnapshotPublication: true,
            supportsProducerBoundSnapshotReferences: true)

        let handshake = try await currentClient.handshake(client: clientIdentity)
        #expect(handshake.negotiatedVersion == PeekabooBridgeConstants.protocolVersion)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.explicitSnapshotPublication) == true)

        let explicitSnapshotID = try await remote.createExplicitSnapshot()
        try await remote.storeDetectionResult(
            snapshotId: explicitSnapshotID,
            result: ElementDetectionResult(
                snapshotId: explicitSnapshotID,
                screenshotPath: "",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "test")))

        #expect(await remote.getMostRecentSnapshot() == priorSnapshotID)
        #expect(try await Set(remote.listSnapshots().map(\.id)) == [priorSnapshotID, explicitSnapshotID])
        #expect(try await remote.getDetectionResult(snapshotId: explicitSnapshotID)?.snapshotId == explicitSnapshotID)

        let lease = try await remote.beginSnapshotMutation(snapshotId: explicitSnapshotID)
        try await remote.finishSnapshotMutation(lease, requiresFreshObservation: true)
        await #expect(throws: PeekabooError.self) {
            _ = try await remote.beginSnapshotMutation(snapshotId: explicitSnapshotID)
        }
        #expect(await remote.getMostRecentSnapshot() == priorSnapshotID)
        #expect(try await remote.invalidateImplicitLatestSnapshot(through: Date()) == priorSnapshotID)
        #expect(await remote.getMostRecentSnapshot() == nil)
        #expect(try await remote.getDetectionResult(snapshotId: explicitSnapshotID)?.snapshotId == explicitSnapshotID)
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
        let remote = try await RemoteSnapshotManager(
            client: Self.currentClient(socketPath: socketPath))

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

    private static func currentClient(socketPath: String) async throws -> PeekabooBridgeClient {
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "boo.peekaboo.snapshot-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        return client
    }
}
