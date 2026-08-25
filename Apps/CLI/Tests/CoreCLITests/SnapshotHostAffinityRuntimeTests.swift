import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct SnapshotHostAffinityRuntimeTests {
    @Test
    func `live authenticated probes retain the sole snapshot producer`() async throws {
        let snapshotID = "1787675983803-1514"
        let missingSnapshots = InMemorySnapshotManager()
        let ownerSnapshots = InMemorySnapshotManager()
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let identity = WindowMutationIdentity(
            windowID: 74,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: 7,
            capturedBounds: bounds
        )
        let window = ServiceWindowInfo(
            windowID: identity.windowID,
            title: "No Elements",
            bounds: bounds,
            mutationIdentity: identity
        )
        try await ownerSnapshots.storeObservationSnapshot(SnapshotObservationPublicationRequest(
            screenshot: SnapshotScreenshotRequest(
                snapshotId: snapshotID,
                screenshotPath: "/tmp/no-elements.png",
                applicationBundleId: "boo.peekaboo.fixture",
                applicationProcessId: identity.ownerProcessIdentifier,
                applicationName: "Fixture",
                windowTitle: window.title,
                windowBounds: bounds,
                windowID: identity.windowID,
                windowMutationIdentity: identity,
                captureCoordinateContext: CaptureCoordinateContext(
                    metadata: CaptureMetadata(
                        size: bounds.size,
                        mode: .window,
                        windowInfo: window
                    ),
                    referenceID: snapshotID
                )
            ),
            detectionResult: nil,
            annotatedScreenshotPath: nil
        ))
        let synthesized = try #require(try await ownerSnapshots.getDetectionResult(snapshotId: snapshotID))
        #expect(synthesized.elements.all.isEmpty)
        _ = try SnapshotTargetReceiptPlanner.assemble(
            snapshotID: snapshotID,
            detectionResult: synthesized
        ).receipt.requireCoordinateAuthority()

        let missingSocket = "/tmp/peekaboo-affinity-missing-\(UUID().uuidString).sock"
        let ownerSocket = "/tmp/peekaboo-affinity-owner-\(UUID().uuidString).sock"
        let missingHost = try await self.startHost(
            socketPath: missingSocket,
            hostKind: .gui,
            snapshots: missingSnapshots
        )
        let ownerHost = try await self.startHost(
            socketPath: ownerSocket,
            hostKind: .onDemand,
            snapshots: ownerSnapshots
        )
        defer {
            Task {
                await missingHost.stop()
                await ownerHost.stop()
            }
        }
        let candidates = [self.candidate(missingSocket), self.candidate(ownerSocket)]
        let cache = RuntimeHostResolver.RemoteHandshakeCache(identity: self.identity)

        let selected = try await RuntimeHostResolver.resolveSnapshotAffinity(
            snapshotID: snapshotID,
            candidates: candidates,
            identity: self.identity,
            handshakeCache: cache
        )

        #expect(selected.socketPath == ownerSocket)
        for candidate in candidates {
            #expect(cache.entry(for: candidate, identity: self.identity) != nil)
        }
        await missingHost.stop()
        await ownerHost.stop()
    }

    @Test
    func `concrete snapshot selects its sole owner among same-version hosts`() async throws {
        let hosts = [self.candidate("/tmp/current.sock"), self.candidate("/tmp/gui.sock")]
        var probes: [String] = []

        let selected = try await RuntimeHostResolver.resolveSnapshotAffinity(
            snapshotID: "1787675983803-1514",
            candidates: hosts,
            identity: self.identity,
            handshakeCache: RuntimeHostResolver.RemoteHandshakeCache(identity: self.identity),
            probe: { candidate, _, _, _ in
                probes.append(candidate.socketPath)
                return candidate.socketPath == "/tmp/gui.sock" ? .owner : .missing
            }
        )

        #expect(selected.socketPath == "/tmp/gui.sock")
        #expect(probes == ["/tmp/current.sock", "/tmp/gui.sock"])
    }

    @Test
    func `dead producer never replays snapshot on another live host`() async {
        let hosts = [self.candidate("/tmp/dead-producer.sock"), self.candidate("/tmp/other-live.sock")]

        await #expect(throws: PreDispatchActionError.self) {
            _ = try await RuntimeHostResolver.resolveSnapshotAffinity(
                snapshotID: "1787675983803-1514",
                candidates: hosts,
                identity: self.identity,
                handshakeCache: RuntimeHostResolver.RemoteHandshakeCache(identity: self.identity),
                probe: { candidate, _, _, _ in
                    candidate.socketPath == "/tmp/dead-producer.sock" ? .unavailable : .missing
                }
            )
        }
    }

    @Test
    func `unknown snapshot fails closed after every host denies ownership`() async {
        let hosts = [self.candidate("/tmp/current.sock"), self.candidate("/tmp/gui.sock")]
        var probes = 0

        await #expect(throws: PreDispatchActionError.self) {
            _ = try await RuntimeHostResolver.resolveSnapshotAffinity(
                snapshotID: "1787675983803-9999",
                candidates: hosts,
                identity: self.identity,
                handshakeCache: RuntimeHostResolver.RemoteHandshakeCache(identity: self.identity),
                probe: { _, _, _, _ in
                    probes += 1
                    return .missing
                }
            )
        }
        #expect(probes == hosts.count)
    }

    @Test
    func `tampered snapshot reference is rejected before any host probe`() async {
        var probes = 0

        await #expect(throws: PreDispatchActionError.self) {
            _ = try await RuntimeHostResolver.resolveSnapshotAffinity(
                snapshotID: "../1787675983803-1514",
                candidates: [self.candidate("/tmp/gui.sock")],
                identity: self.identity,
                handshakeCache: RuntimeHostResolver.RemoteHandshakeCache(identity: self.identity),
                probe: { _, _, _, _ in
                    probes += 1
                    return .owner
                }
            )
        }
        #expect(probes == 0)
    }

    @Test
    func `duplicate snapshot ownership is ambiguous instead of order dependent`() async {
        let hosts = [self.candidate("/tmp/current.sock"), self.candidate("/tmp/gui.sock")]

        for candidates in [hosts, Array(hosts.reversed())] {
            await #expect(throws: PreDispatchActionError.self) {
                _ = try await RuntimeHostResolver.resolveSnapshotAffinity(
                    snapshotID: "1787675983803-1514",
                    candidates: candidates,
                    identity: self.identity,
                    handshakeCache: RuntimeHostResolver.RemoteHandshakeCache(identity: self.identity),
                    probe: { _, _, _, _ in .owner }
                )
            }
        }
    }

    @Test
    func `explicit socket affinity stays on the asserted host`() {
        let explicit = self.candidate("/tmp/explicit.sock")
        let plan = RuntimeHostResolver.RemoteCandidatePlan(
            explicitSocket: explicit.socketPath,
            daemonSocketPath: "/tmp/daemon.sock",
            runtimeBuildIdentity: "build",
            buildScopedDaemonSocketPath: "/tmp/build.sock",
            historicalBuildScopedDaemonSocketPaths: ["/tmp/history.sock"],
            candidates: [explicit]
        )

        #expect(RuntimeHostResolver.snapshotAffinityCandidates(from: plan) == [explicit])
    }

    @Test
    func `unavailable affinity probes complete concurrently`() async {
        let hosts = (0..<4).map { self.candidate("/tmp/slow-\($0).sock") }
        let startedAt = ContinuousClock.now

        await #expect(throws: PreDispatchActionError.self) {
            _ = try await RuntimeHostResolver.resolveSnapshotAffinity(
                snapshotID: "1787675983803-1514",
                candidates: hosts,
                identity: self.identity,
                handshakeCache: RuntimeHostResolver.RemoteHandshakeCache(identity: self.identity),
                probe: { _, _, _, _ in
                    try await Task.sleep(for: .milliseconds(120))
                    return .unavailable
                }
            )
        }
        #expect(startedAt.duration(to: .now) < .milliseconds(350))
    }

    private var identity: PeekabooBridgeClientIdentity {
        PeekabooBridgeClientIdentity(
            bundleIdentifier: "boo.peekaboo.test.client",
            teamIdentifier: nil,
            processIdentifier: getpid()
        )
    }

    private func candidate(_ socketPath: String) -> RuntimeHostResolver.ImplicitRemoteCandidate {
        RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: socketPath,
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
    }

    private func startHost(
        socketPath: String,
        hostKind: PeekabooBridgeHostKind,
        snapshots: InMemorySnapshotManager
    ) async throws -> PeekabooBridgeHost {
        let server = PeekabooBridgeServer(
            services: PeekabooServices(snapshotManager: snapshots),
            hostKind: hostKind,
            allowlistedTeams: [],
            allowlistedBundles: []
        )
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2
        )
        try await host.startChecked()
        return host
    }
}
