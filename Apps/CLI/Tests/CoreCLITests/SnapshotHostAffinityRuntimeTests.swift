import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooBridge
import PeekabooBridgeTestSupport
import PeekabooCore
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct SnapshotHostAffinityRuntimeTests {
    @Test
    func `live authenticated probes retain the sole snapshot producer`() async throws {
        try await CLIBridgeHostFixture.withHosts { hosts in
            let missingSnapshots = InMemorySnapshotManager()
            let ownerSnapshots = InMemorySnapshotManager()
            let snapshotID = try await ownerSnapshots.createSnapshot()
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

            let missingSocket = hosts.desktop.root.appendingPathComponent("missing.sock").path
            let ownerSocket = hosts.desktop.root.appendingPathComponent("owner.sock").path
            try await self.startHost(
                hosts: hosts,
                socketPath: missingSocket,
                hostKind: .gui,
                snapshots: missingSnapshots
            )
            try await self.startHost(
                hosts: hosts,
                socketPath: ownerSocket,
                hostKind: .onDemand,
                snapshots: ownerSnapshots
            )
            let candidates = [self.candidate(missingSocket), self.candidate(ownerSocket)]
            let cache = RuntimeHostResolver.RemoteHandshakeCache(
                identity: self.identity,
                clientFactory: { BridgeTestFixtures.authenticatedClient(socketPath: $0) }
            )
            for candidate in candidates {
                let handshake = try await cache.handshake(candidate, identity: self.identity).response
                #expect(handshake.supportedOperations.contains(.ownsSnapshot))
                #expect(BridgeCapabilityPolicy.supportsProducerBoundSnapshotReferences(for: handshake))
                #expect(Set(handshake.supportedOperations).isSubset(of: CLISnapshotBridgeServices.snapshotOperations))
                #expect(handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership
                ) != true)
            }

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
        }
    }

    @Test
    func `concrete snapshot selects its sole owner among same-version hosts`() async throws {
        let hosts = [self.candidate("/tmp/current.sock"), self.candidate("/tmp/gui.sock")]
        var probes: [String] = []

        let selected = try await RuntimeHostResolver.resolveSnapshotAffinity(
            snapshotID: SnapshotReferenceFixtures.first.rawValue,
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
    func `candidate aliases count as one snapshot owner`() async throws {
        let aliases = [
            self.candidate("/tmp/peekaboo-affinity-alias.sock"),
            self.candidate("/tmp/../tmp/peekaboo-affinity-alias.sock"),
        ]

        let selected = try await RuntimeHostResolver.resolveSnapshotAffinity(
            snapshotID: SnapshotReferenceFixtures.first.rawValue,
            candidates: aliases,
            identity: self.identity,
            handshakeCache: RuntimeHostResolver.RemoteHandshakeCache(identity: self.identity),
            probe: { _, _, _, _ in .owner }
        )

        #expect(selected.socketPath == aliases[0].socketPath)
    }

    @Test
    func `two authenticated endpoints from one process count as one snapshot owner`() async throws {
        try await CLIBridgeHostFixture.withHosts { hosts in
            let snapshots = InMemorySnapshotManager()
            let snapshotID = try await snapshots.createSnapshot()
            let firstSocket = hosts.desktop.root.appendingPathComponent("first.sock").path
            let secondSocket = hosts.desktop.root.appendingPathComponent("second.sock").path
            try await self.startHost(
                hosts: hosts,
                socketPath: firstSocket,
                hostKind: .onDemand,
                snapshots: snapshots
            )
            try await self.startHost(
                hosts: hosts,
                socketPath: secondSocket,
                hostKind: .onDemand,
                snapshots: snapshots
            )
            let cache = RuntimeHostResolver.RemoteHandshakeCache(
                identity: self.identity,
                clientFactory: { BridgeTestFixtures.authenticatedClient(socketPath: $0) }
            )

            let selected = try await RuntimeHostResolver.resolveSnapshotAffinity(
                snapshotID: snapshotID,
                candidates: [self.candidate(firstSocket), self.candidate(secondSocket)],
                identity: self.identity,
                handshakeCache: cache
            )

            #expect(selected.socketPath == firstSocket)
        }
    }

    @Test
    func `same-producer affinity tries every alias for command capability`() async throws {
        try await CLIBridgeHostFixture.withHosts { hosts in
            let snapshots = InMemorySnapshotManager()
            let snapshotID = try await snapshots.createSnapshot()
            let firstSocket = hosts.desktop.root.appendingPathComponent("limited.sock").path
            let secondSocket = hosts.desktop.root.appendingPathComponent("capable.sock").path
            try await self.startHost(
                hosts: hosts,
                socketPath: firstSocket,
                hostKind: .onDemand,
                snapshots: snapshots,
                allowedOperations: [.ownsSnapshot]
            )
            try await self.startHost(
                hosts: hosts,
                socketPath: secondSocket,
                hostKind: .onDemand,
                snapshots: snapshots,
                allowedOperations: [.ownsSnapshot, .targetedClick]
            )
            var options = CommandRuntimeOptions()
            options.explicitSnapshotID = snapshotID
            options.requiresProducerBoundSnapshotReferences = true
            options.requiresProcessGenerationPinnedClicks = true
            let dependencies = RuntimeHostResolver.Dependencies(
                makeLocalServices: { _ in PeekabooServices(snapshotManager: InMemorySnapshotManager()) },
                claimScreenCaptureKitOwner: { throw POSIXError(.EPERM) },
                inspectScreenCaptureKitOwner: { nil },
                remoteCandidatePlan: { _, _ in
                    self.plan(candidates: [self.candidate(firstSocket), self.candidate(secondSocket)])
                },
                makeRemoteHandshakeCache: { self.authenticatedHandshakeCache() }
            )

            let resolution = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: [:],
                configurationInput: nil,
                dependencies: dependencies
            )

            #expect(resolution.selectedRemoteSocketPath == secondSocket)
        }
    }

    @Test
    func `dead producer never replays snapshot on another live host`() async {
        let hosts = [self.candidate("/tmp/dead-producer.sock"), self.candidate("/tmp/other-live.sock")]

        await #expect(throws: PreDispatchActionError.self) {
            _ = try await RuntimeHostResolver.resolveSnapshotAffinity(
                snapshotID: SnapshotReferenceFixtures.first.rawValue,
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
                snapshotID: SnapshotReferenceFixtures.second.rawValue,
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
                snapshotID: "../\(SnapshotReferenceFixtures.first.rawValue)",
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
                    snapshotID: SnapshotReferenceFixtures.first.rawValue,
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
    func `full runtime accepts an explicit socket only when that host owns the snapshot`() async throws {
        try await CLIBridgeHostFixture.withHosts { hosts in
            let snapshots = InMemorySnapshotManager()
            let snapshotID = try await snapshots.createSnapshot()
            let socketPath = hosts.desktop.root.appendingPathComponent("owner.sock").path
            try await self.startHost(
                hosts: hosts,
                socketPath: socketPath,
                hostKind: .onDemand,
                snapshots: snapshots
            )
            var options = CommandRuntimeOptions()
            options.bridgeSocketPath = socketPath
            options.explicitSnapshotID = snapshotID
            let dependencies = RuntimeHostResolver.Dependencies(
                makeLocalServices: { _ in PeekabooServices(snapshotManager: InMemorySnapshotManager()) },
                claimScreenCaptureKitOwner: { throw POSIXError(.EPERM) },
                inspectScreenCaptureKitOwner: { nil },
                remoteCandidatePlan: { _, _ in self.explicitPlan(socketPath: socketPath) },
                makeRemoteHandshakeCache: { self.authenticatedHandshakeCache() }
            )

            let resolution = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: [:],
                configurationInput: nil,
                dependencies: dependencies
            )

            #expect(resolution.selectedRemoteSocketPath == socketPath)
            #expect(try await resolution.services.snapshots.ownsSnapshot(snapshotId: snapshotID))
        }
    }

    @Test
    func `full runtime refuses an explicit socket that does not own the snapshot`() async throws {
        try await CLIBridgeHostFixture.withHosts { hosts in
            let socketPath = hosts.desktop.root.appendingPathComponent("nonowner.sock").path
            try await self.startHost(
                hosts: hosts,
                socketPath: socketPath,
                hostKind: .onDemand,
                snapshots: InMemorySnapshotManager()
            )
            var options = CommandRuntimeOptions()
            options.bridgeSocketPath = socketPath
            options.explicitSnapshotID = SnapshotReferenceFixtures.first.rawValue
            let dependencies = RuntimeHostResolver.Dependencies(
                makeLocalServices: { _ in PeekabooServices(snapshotManager: InMemorySnapshotManager()) },
                claimScreenCaptureKitOwner: { throw POSIXError(.EPERM) },
                inspectScreenCaptureKitOwner: { nil },
                remoteCandidatePlan: { _, _ in self.explicitPlan(socketPath: socketPath) },
                makeRemoteHandshakeCache: { self.authenticatedHandshakeCache() }
            )

            do {
                _ = try await RuntimeHostResolver.resolveServices(
                    options: options,
                    environment: [:],
                    configurationInput: nil,
                    dependencies: dependencies
                )
                Issue.record("Expected explicit non-owner refusal")
            } catch let error as PreDispatchActionError {
                #expect(error.code == .SNAPSHOT_NOT_FOUND)
                #expect(error.localizedDescription.contains("no unique live host affinity"))
            }
        }
    }

    @Test
    func `unavailable affinity probes complete concurrently`() async {
        let hosts = (0..<4).map { self.candidate("/tmp/slow-\($0).sock") }
        let startedAt = ContinuousClock.now

        await #expect(throws: PreDispatchActionError.self) {
            _ = try await RuntimeHostResolver.resolveSnapshotAffinity(
                snapshotID: SnapshotReferenceFixtures.first.rawValue,
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

    @Test
    func `dishonest ownership capability is classified as incompatible`() async throws {
        try await CLIBridgeHostFixture.withHosts { hosts in
            let snapshots = SnapshotMutationRecordingManager(wrapping: InMemorySnapshotManager())
            snapshots.ownsSnapshotError = PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Injected dishonest capability"
            )
            let socketPath = hosts.desktop.root.appendingPathComponent("dishonest.sock").path
            try await self.startHost(
                hosts: hosts,
                socketPath: socketPath,
                hostKind: .onDemand,
                snapshots: snapshots
            )
            let candidate = self.candidate(socketPath)
            let cache = self.authenticatedHandshakeCache()

            let result = try await RuntimeHostResolver.liveSnapshotAffinityProbe(
                candidate,
                SnapshotReferenceFixtures.first.rawValue,
                self.identity,
                cache
            )

            #expect(result == .incompatible)
            #expect(snapshots.ownsCalls == [SnapshotReferenceFixtures.first.rawValue])
        }
    }

    @Test
    func `automatic runtime selects a caller-local snapshot owner before remote policy`() async throws {
        let snapshots = InMemorySnapshotManager()
        let snapshotID = try await snapshots.createSnapshot()
        let services = PeekabooServices(snapshotManager: snapshots)
        var probes: [String] = []
        var options = CommandRuntimeOptions()
        options.explicitSnapshotID = snapshotID
        options.inputStrategy = .actionFirst
        let remote = self.candidate("/tmp/nonowner.sock")
        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: self.dependencies(
                localServices: services,
                candidates: [remote],
                probe: { candidate, _, _, _ in
                    probes.append(candidate.socketPath)
                    return .missing
                }
            )
        )

        #expect(resolution.selectedRemoteSocketPath == nil)
        #expect(resolution.hostDescription == "local (snapshot producer)")
        #expect(Set(probes) == Set([
            remote.socketPath,
            "/tmp/daemon.sock",
            PeekabooBridgeConstants.peekabooSocketPath,
            PeekabooBridgeConstants.claudeSocketPath,
            PeekabooBridgeConstants.clawdbotSocketPath,
        ]))
    }

    @Test
    func `force-local snapshot routing verifies only local ownership`() async throws {
        let snapshots = InMemorySnapshotManager()
        let owned = try await snapshots.createSnapshot()
        let services = PeekabooServices(snapshotManager: snapshots)
        var probeCount = 0
        var planCount = 0
        var options = CommandRuntimeOptions()
        options.explicitSnapshotID = owned
        let dependencies = RuntimeHostResolver.Dependencies(
            makeLocalServices: { _ in services },
            claimScreenCaptureKitOwner: { throw POSIXError(.EPERM) },
            inspectScreenCaptureKitOwner: { nil },
            remoteCandidatePlan: { _, _ in
                planCount += 1
                return self.plan(candidates: [self.candidate("/tmp/unused.sock")])
            },
            snapshotAffinityProbe: { _, _, _, _ in
                probeCount += 1
                return .owner
            }
        )
        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: ["PEEKABOO_NO_REMOTE": "1"],
            configurationInput: nil,
            dependencies: dependencies
        )

        #expect(resolution.selectedRemoteSocketPath == nil)
        #expect(try await resolution.services.snapshots.ownsSnapshot(snapshotId: owned))
        #expect(planCount == 0)
        #expect(probeCount == 0)

        options.explicitSnapshotID = SnapshotReferenceFixtures.second.rawValue
        await #expect(throws: PreDispatchActionError.self) {
            _ = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: ["PEEKABOO_NO_REMOTE": "1"],
                configurationInput: nil,
                dependencies: dependencies
            )
        }
        #expect(planCount == 0)
        #expect(probeCount == 0)
    }

    @Test
    func `malformed concrete runtime reference is validation error before policy or probes`() async {
        let services = PeekabooServices(snapshotManager: InMemorySnapshotManager())
        var probeCount = 0
        var options = CommandRuntimeOptions()
        options.explicitSnapshotID = "1787675983803-1514"
        do {
            _ = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: ["PEEKABOO_NO_REMOTE": "1"],
                configurationInput: nil,
                dependencies: self.dependencies(
                    localServices: services,
                    candidates: [],
                    probe: { _, _, _, _ in
                        probeCount += 1
                        return .owner
                    }
                )
            )
            Issue.record("Expected malformed snapshot refusal")
        } catch let error as PreDispatchActionError {
            #expect(error.code == .VALIDATION_ERROR)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(probeCount == 0)
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

    private func plan(
        candidates: [RuntimeHostResolver.ImplicitRemoteCandidate]
    ) -> RuntimeHostResolver.RemoteCandidatePlan {
        RuntimeHostResolver.RemoteCandidatePlan(
            explicitSocket: nil,
            daemonSocketPath: "/tmp/daemon.sock",
            runtimeBuildIdentity: "snapshot-tests",
            buildScopedDaemonSocketPath: nil,
            historicalBuildScopedDaemonSocketPaths: [],
            candidates: candidates
        )
    }

    private func explicitPlan(socketPath: String) -> RuntimeHostResolver.RemoteCandidatePlan {
        let explicit = self.candidate(socketPath)
        return RuntimeHostResolver.RemoteCandidatePlan(
            explicitSocket: socketPath,
            daemonSocketPath: "/tmp/daemon.sock",
            runtimeBuildIdentity: "snapshot-tests",
            buildScopedDaemonSocketPath: nil,
            historicalBuildScopedDaemonSocketPaths: [],
            candidates: [explicit]
        )
    }

    private func authenticatedHandshakeCache() -> RuntimeHostResolver.RemoteHandshakeCache {
        RuntimeHostResolver.RemoteHandshakeCache(
            identity: self.identity,
            clientFactory: { BridgeTestFixtures.authenticatedClient(socketPath: $0) }
        )
    }

    private func dependencies(
        localServices: PeekabooServices,
        candidates: [RuntimeHostResolver.ImplicitRemoteCandidate],
        probe: @escaping RuntimeHostResolver.SnapshotAffinityProbe
    ) -> RuntimeHostResolver.Dependencies {
        RuntimeHostResolver.Dependencies(
            makeLocalServices: { _ in localServices },
            claimScreenCaptureKitOwner: { throw POSIXError(.EPERM) },
            inspectScreenCaptureKitOwner: { nil },
            remoteCandidatePlan: { _, _ in self.plan(candidates: candidates) },
            snapshotAffinityProbe: probe
        )
    }

    private func startHost(
        hosts: CLIBridgeHostFixture,
        socketPath: String,
        hostKind: PeekabooBridgeHostKind,
        snapshots: any SnapshotManagerProtocol,
        allowedOperations: Set<PeekabooBridgeOperation>? = nil
    ) async throws {
        let services = CLISnapshotBridgeServices(snapshots: snapshots, directory: hosts.desktop.root)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: hostKind,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: allowedOperations ?? CLISnapshotBridgeServices.snapshotOperations,
            desktopOperationLaneCoordinator: hosts.desktop.laneCoordinator,
            screenCaptureKitProcessCapabilityRegistrar: {},
            screenCaptureKitOwnershipPreparer: {},
            screenCaptureKitOwnerClaimProvider: CLISnapshotBridgeServices.unexpectedScreenCaptureKitClaim,
            permissionStatusEvaluator: { _ in CLISnapshotBridgeServices.grantedPermissions() }
        )
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2
        )
        try await hosts.start(host)
    }
}
