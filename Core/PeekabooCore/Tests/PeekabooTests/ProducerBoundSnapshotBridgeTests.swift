import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooBridgeTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
struct ProducerBoundSnapshotBridgeTests {
    @Test
    @MainActor
    func `current 1 34 offer exposes signed producer ownership independently`() async throws {
        let snapshots = InMemorySnapshotManager()
        let ordinary = try await snapshots.createSnapshot()
        let pending = try await snapshots.createSnapshot(pendingAt: Date())
        let explicit = try await snapshots.createExplicitSnapshot()
        let socketPath = "/tmp/peekaboo-producer-snapshot-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: PeekabooServices(snapshotManager: snapshots),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        let handshake = try await client.handshake(client: Self.identity)
        #expect(handshake.negotiatedVersion == .init(major: 1, minor: 34))
        #expect(handshake.supportedOperations.contains(.ownsSnapshot))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.producerBoundSnapshotReferences) == true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery) == true)

        for snapshotID in [ordinary, pending, explicit] {
            #expect(try await client.ownsSnapshot(snapshotId: snapshotID))
            let receipt = try #require(await client.lastOperationReceipt())
            #expect(receipt.payload.operation == .ownsSnapshot)
            #expect(receipt.payload.outcome == nil)
        }
        #expect(try await !client.ownsSnapshot(snapshotId: SnapshotReferenceFixtures.id(99)))
        try await snapshots.cleanSnapshot(snapshotId: ordinary)
        #expect(try await !client.ownsSnapshot(snapshotId: ordinary))
        await host.stop()
    }

    @Test
    @MainActor
    func `legacy 1 34 client offer omits only new same-minor operations and capabilities`() async throws {
        let socketPath = "/tmp/peekaboo-legacy-134-snapshot-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: PeekabooServices(snapshotManager: InMemorySnapshotManager()),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        let response = try await client.send(.handshake(.init(
            protocolVersion: .init(major: 1, minor: 34),
            client: Self.identity,
            operationClientInstanceID: client.operationClientInstanceID,
            clientCapabilities: nil)))
        let handshake: PeekabooBridgeHandshakeResponse
        guard case let .handshake(value) = response else {
            Issue.record("Expected handshake response")
            return
        }
        handshake = value
        #expect(!handshake.supportedOperations.contains(.ownsSnapshot))
        #expect(handshake.enabledOperations?.contains(.ownsSnapshot) != true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.producerBoundSnapshotReferences) != true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery) != true)
        // #622 remains independent at the already-shipped 1.34 floor.
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.nativeBrowserConnectionBinding) == true)
        await host.stop()
    }

    @Test
    @MainActor
    func `same minor browser snapshot and value capabilities negotiate independently`() async throws {
        let browserOnlyServer = PeekabooBridgeServer(
            services: PeekabooServices(snapshotManager: InMemorySnapshotManager()),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let browserOnly = try await Self.rawLiveHandshake(
            server: browserOnlyServer,
            clientCapabilities: [])
        #expect(browserOnly.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.nativeBrowserConnectionBinding) == true)
        #expect(browserOnly.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.producerBoundSnapshotReferences) != true)
        #expect(browserOnly.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery) != true)

        let snapshotOnlyServer = PeekabooBridgeServer(
            services: NonBrowserCapabilityServices(
                base: StubServices(snapshots: InMemorySnapshotManager())),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let snapshotOnly = try await Self.rawLiveHandshake(
            server: snapshotOnlyServer,
            clientCapabilities: [PeekabooBridgeClientCapability.producerBoundSnapshotReferences])
        #expect(snapshotOnly.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.nativeBrowserConnectionBinding) != true)
        #expect(snapshotOnly.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.producerBoundSnapshotReferences) == true)
        #expect(snapshotOnly.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery) != true)

        let valueOnlySnapshots = SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager(),
            supportsProducerBoundSnapshotReferences: false)
        let valueOnlyBase = StubServices(snapshots: valueOnlySnapshots)
        valueOnlyBase.automationStub.supportsTargetedClickAccessibilityValueDelivery = true
        let valueOnlyServices = NonBrowserCapabilityServices(base: valueOnlyBase)
        let valueOnlyServer = PeekabooBridgeServer(
            services: valueOnlyServices,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let valueOnly = try await Self.rawLiveHandshake(
            server: valueOnlyServer,
            clientCapabilities: [PeekabooBridgeClientCapability.targetedClickAccessibilityValueDelivery])
        #expect(valueOnly.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.nativeBrowserConnectionBinding) != true)
        #expect(valueOnly.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.producerBoundSnapshotReferences) != true)
        #expect(valueOnly.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery) == true)
    }

    @Test
    @MainActor
    func `new client refuses old same minor snapshot creation before a second wire request`() async throws {
        let snapshots = SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager(),
            supportsProducerBoundSnapshotReferences: false)
        let server = PeekabooBridgeServer(
            services: StubServices(snapshots: snapshots),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let socketPath = "/tmp/peekaboo-old-134-create-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        let handshake = try await client.handshake(client: Self.identity)
        #expect(handshake.negotiatedVersion == .init(major: 1, minor: 34))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.producerBoundSnapshotReferences) != true)

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await client.createSnapshot()
        }
        #expect(snapshots.createCalls.isEmpty)
        await host.stop()
    }

    @Test
    @MainActor
    func `current client refuses snapshot publication without breaking legacy server carriage`() async throws {
        let snapshots = SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager(),
            supportsProducerBoundSnapshotReferences: false)
        let server = PeekabooBridgeServer(
            services: StubServices(snapshots: snapshots),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let socketPath = "/tmp/peekaboo-old-134-publication-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        let handshake = try await client.handshake(client: Self.identity)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.producerBoundSnapshotReferences) != true)

        let snapshotID = SnapshotReferenceFixtures.first.rawValue
        let detection = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "fixture"))
        let screenshot = SnapshotScreenshotRequest(
            snapshotId: snapshotID,
            screenshotPath: "/tmp/unused.png",
            applicationBundleId: nil,
            applicationProcessId: nil,
            applicationName: nil,
            windowTitle: nil,
            windowBounds: nil)
        let publication = SnapshotObservationPublicationRequest(
            screenshot: screenshot,
            detectionResult: detection,
            annotatedScreenshotPath: nil)

        let requests: [PeekabooBridgeRequest] = [
            .createSnapshot(.init()),
            .storeDetectionResult(.init(snapshotId: snapshotID, result: detection)),
            .storeScreenshot(.init(screenshot)),
            .storeObservationSnapshot(.init(publication)),
            .storeAnnotatedScreenshot(.init(
                snapshotId: snapshotID,
                annotatedScreenshotPath: "/tmp/unused-annotated.png")),
        ]
        let allCreateOrPublish = requests.allSatisfy(\.createsOrPublishesSnapshotState)
        let allRemainLegacyServerCompatible = requests.allSatisfy {
            !$0.requiresProducerBoundSnapshotReferences
        }
        #expect(allCreateOrPublish)
        #expect(allRemainLegacyServerCompatible)

        for request in requests {
            do {
                _ = try await client.send(request)
                Issue.record("Expected snapshot publication capability refusal for \(request.operation.rawValue)")
            } catch let envelope as PeekabooBridgeErrorEnvelope {
                #expect(envelope.code == .operationNotSupported)
            }
        }

        #expect(snapshots.createCalls.isEmpty)
        #expect(try await snapshots.listSnapshots().isEmpty)
        await host.stop()
    }

    @Test
    @MainActor
    func `new client refuses explicit value delivery policy on old same minor host before click`() async throws {
        let services = StubServices(snapshots: InMemorySnapshotManager())
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let socketPath = "/tmp/peekaboo-old-134-click-policy-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        let handshake = try await client.handshake(client: Self.identity)
        #expect(handshake.negotiatedVersion == .init(major: 1, minor: 34))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery) != true)

        let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 7)
        do {
            _ = try await client.clickWithOutcome(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue,
                expectedProcessIdentity: identity,
                allowsAccessibilityValueDelivery: false)
            Issue.record("Expected an old-host policy refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.message.contains("accessibility-value click policy"))
        }
        #expect(services.automationStub.lastClick == nil)
        await host.stop()
    }

    @Test
    @MainActor
    func `client rejects noncanonical references from a capability claiming host`() async throws {
        let snapshots = SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager(),
            createdSnapshotReferenceOverride: "1787675983803-1514")
        let server = PeekabooBridgeServer(
            services: StubServices(snapshots: snapshots),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let socketPath = "/tmp/peekaboo-hostile-snapshot-reference-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        _ = try await client.handshake(client: Self.identity)

        do {
            _ = try await client.createSnapshot()
            Issue.record("Expected the client to reject a noncanonical snapshot reference")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .invalidRequest)
            #expect(envelope.message.contains("non-canonical"))
        }
        #expect(snapshots.createCalls.count == 1)
        await host.stop()
    }

    @Test
    @MainActor
    func `provider claims and protocol floor gate the two additions independently`() async throws {
        let wrappedSnapshots = SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager(),
            supportsProducerBoundSnapshotReferences: false)
        let legacyServer = PeekabooBridgeServer(
            services: StubServices(snapshots: wrappedSnapshots),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let legacy = try await Self.liveHandshake(server: legacyServer, version: .init(major: 1, minor: 34))
        #expect(!legacy.supportedOperations.contains(.ownsSnapshot))
        #expect(legacy.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.producerBoundSnapshotReferences) != true)
        #expect(legacy.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery) != true)

        let currentServer = PeekabooBridgeServer(
            services: PeekabooServices(snapshotManager: InMemorySnapshotManager()),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let downgraded = try await Self.liveHandshake(server: currentServer, version: .init(major: 1, minor: 33))
        #expect(!downgraded.supportedOperations.contains(.ownsSnapshot))
        #expect(downgraded.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.producerBoundSnapshotReferences) != true)
        #expect(downgraded.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery) != true)
        #expect(downgraded.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.nativeBrowserConnectionBinding) != true)
    }

    @Test
    func `new optional client offer decodes in a legacy handshake payload`() throws {
        let payload = PeekabooBridgeHandshake(
            protocolVersion: .init(major: 1, minor: 34),
            client: Self.identity,
            operationClientInstanceID: UUID(),
            clientCapabilities: [
                PeekabooBridgeClientCapability.producerBoundSnapshotReferences,
                PeekabooBridgeClientCapability.targetedClickAccessibilityValueDelivery,
            ])
        let legacy = try JSONDecoder.peekabooBridgeDecoder().decode(
            LegacyHandshakePayload.self,
            from: JSONEncoder.peekabooBridgeEncoder().encode(payload))
        #expect(legacy.protocolVersion == payload.protocolVersion)
        #expect(legacy.client.processIdentifier == payload.client.processIdentifier)
    }

    @Test
    func `direct client refuses receiptless capability claims before a second request`() async throws {
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 34),
            supportedOperations: [.ownsSnapshot, .targetedClick],
            hostCapabilities: [
                PeekabooBridgeHostCapability.producerBoundSnapshotReferences,
                PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery,
            ])
        let peer = try ScriptedBridgePeer(responses: [.handshake(handshake)])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await client.handshake(client: Self.identity, protocolVersion: .init(major: 1, minor: 34))
        }
        #expect(await peer.requests.count == 1)
        await peer.waitUntilFinished()
    }

    @Test
    @MainActor
    func `hostile missing and contradictory sessions refuse before snapshot or click providers`() throws {
        let snapshots = SnapshotMutationRecordingManager(wrapping: InMemorySnapshotManager())
        let services = StubServices(snapshots: snapshots)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let snapshotID = SnapshotReferenceFixtures.first.rawValue
        let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 7)
        let owns = PeekabooBridgeRequest.ownsSnapshot(.init(snapshotId: snapshotID))
        let click = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("field"),
            clickType: .single,
            snapshotId: snapshotID,
            targetProcessIdentifier: identity.processIdentifier,
            expectedProcessIdentity: identity,
            allowsAccessibilityValueDelivery: true))
        let permissions = PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
        let enabled = server.effectiveAllowedOperations(permissions: permissions)
        let hostileSessions = [
            PeekabooBridgeNegotiatedSessionCapabilities(
                protocolVersion: .init(major: 1, minor: 34),
                statelessClickVariants: true,
                exactWindowHeldPointerLifecycle: true,
                producerBoundSnapshotReferences: false,
                targetedClickAccessibilityValueDelivery: false),
            PeekabooBridgeNegotiatedSessionCapabilities(
                protocolVersion: .init(major: 1, minor: 33),
                statelessClickVariants: true,
                exactWindowHeldPointerLifecycle: true,
                producerBoundSnapshotReferences: true,
                targetedClickAccessibilityValueDelivery: true),
        ]

        for session in hostileSessions {
            for request in [owns, click] {
                #expect(throws: PeekabooBridgeErrorEnvelope.self) {
                    try PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(session) {
                        try server.validateOperationAccess(
                            for: request,
                            permissions: permissions,
                            effectiveOps: enabled)
                    }
                }
            }
        }
        #expect(snapshots.ownsCalls.isEmpty)
        #expect(services.automationStub.lastClick == nil)
    }

    @Test
    @MainActor
    func `omitted legacy click policy preserves value delivery on a current host`() async throws {
        let services = StubServices(snapshots: InMemorySnapshotManager())
        services.automationStub.supportsTargetedClickAccessibilityValueDelivery = true
        services.automationStub.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            unitCount: .one)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 7)
        let request = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("field"),
            clickType: .single,
            snapshotId: SnapshotReferenceFixtures.first.rawValue,
            targetProcessIdentifier: identity.processIdentifier,
            expectedProcessIdentity: identity))
        let legacySession = PeekabooBridgeNegotiatedSessionCapabilities(
            protocolVersion: .init(major: 1, minor: 34),
            statelessClickVariants: true,
            exactWindowHeldPointerLifecycle: true)
        let permissions = PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)

        let handled = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(legacySession) {
                try await server.handleAuthorized(request, peer: nil, permissions: permissions)
            }
        }

        guard case .ok = handled.response else {
            Issue.record("Expected legacy targeted click success")
            return
        }
        #expect(handled.outcome?.delivery?.mechanism == .accessibilityValue)
        #expect(services.automationStub.lastAllowsAccessibilityValueDelivery == true)
    }

    @Test
    @MainActor
    func `explicit value policy without pinned identity refuses before click provider`() async throws {
        let services = StubServices(snapshots: InMemorySnapshotManager())
        services.automationStub.supportsTargetedClickAccessibilityValueDelivery = true
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let permissions = PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)

        for policy in [false, true] {
            do {
                _ = try await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(.current) {
                    try await server.handleAuthorized(
                        .targetedClick(.init(
                            target: .elementId("field"),
                            clickType: .single,
                            snapshotId: SnapshotReferenceFixtures.first.rawValue,
                            targetProcessIdentifier: 42,
                            allowsAccessibilityValueDelivery: policy)),
                        peer: nil,
                        permissions: permissions)
                }
                Issue.record("Expected explicit policy \(policy) without a pinned identity to be refused")
            } catch let error as PeekabooBridgeErrorEnvelope {
                #expect(error.code == .invalidRequest)
            }
        }

        #expect(services.automationStub.lastClick == nil)
        #expect(services.automationStub.lastProcessTargetedClick == nil)
        #expect(services.automationStub.lastAllowsAccessibilityValueDelivery == nil)
    }

    @Test
    @MainActor
    func `malformed owns and policy blind value provider refuse before service entry`() async throws {
        let snapshots = SnapshotMutationRecordingManager(wrapping: InMemorySnapshotManager())
        let services = StubServices(snapshots: snapshots)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let permissions = PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(.current) {
                try await server.handleAuthorized(
                    .ownsSnapshot(.init(snapshotId: "snapshot-1")),
                    peer: nil,
                    permissions: permissions)
            }
        }
        #expect(snapshots.ownsCalls.isEmpty)

        let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 7)
        await #expect(throws: (any Error).self) {
            _ = try await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(.current) {
                try await server.handleAuthorized(
                    .targetedClick(.init(
                        target: .elementId("field"),
                        clickType: .single,
                        snapshotId: SnapshotReferenceFixtures.first.rawValue,
                        targetProcessIdentifier: identity.processIdentifier,
                        expectedProcessIdentity: identity,
                        allowsAccessibilityValueDelivery: false)),
                    peer: nil,
                    permissions: permissions)
            }
        }
        #expect(services.automationStub.lastClick == nil)
    }

    @MainActor
    private static func liveHandshake(
        server: PeekabooBridgeServer,
        version: PeekabooBridgeProtocolVersion) async throws -> PeekabooBridgeHandshakeResponse
    {
        let socketPath = "/tmp/peekaboo-capability-matrix-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        do {
            let handshake = try await client.handshake(client: Self.identity, protocolVersion: version)
            await host.stop()
            return handshake
        } catch {
            await host.stop()
            throw error
        }
    }

    @MainActor
    private static func rawLiveHandshake(
        server: PeekabooBridgeServer,
        clientCapabilities: [String]) async throws -> PeekabooBridgeHandshakeResponse
    {
        let socketPath = "/tmp/peekaboo-raw-capability-matrix-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        do {
            let response = try await client.send(.handshake(.init(
                protocolVersion: .init(major: 1, minor: 34),
                client: Self.identity,
                operationClientInstanceID: client.operationClientInstanceID,
                clientCapabilities: clientCapabilities)))
            await host.stop()
            guard case let .handshake(handshake) = response else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .invalidRequest,
                    message: "Expected capability-matrix handshake response")
            }
            return handshake
        } catch {
            await host.stop()
            throw error
        }
    }

    private static var identity: PeekabooBridgeClientIdentity {
        PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.snapshot-capability-tests",
            teamIdentifier: nil,
            processIdentifier: getpid())
    }
}

private struct LegacyHandshakePayload: Codable {
    let protocolVersion: PeekabooBridgeProtocolVersion
    let client: PeekabooBridgeClientIdentity
    let requestedHostKind: PeekabooBridgeHostKind?
    let operationClientInstanceID: UUID?
    let replacingOperationSessionID: UUID?
}

@MainActor
private final class NonBrowserCapabilityServices: PeekabooBridgeServiceProviding {
    private let base: StubServices

    init(base: StubServices) {
        self.base = base
    }

    var permissions: PermissionsService {
        self.base.permissions
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.base.screenCapture
    }

    var automation: any UIAutomationServiceProtocol {
        self.base.automation
    }

    var windows: any WindowManagementServiceProtocol {
        self.base.windows
    }

    var applications: any ApplicationServiceProtocol {
        self.base.applications
    }

    var menu: any MenuServiceProtocol {
        self.base.menu
    }

    var dock: any DockServiceProtocol {
        self.base.dock
    }

    var dialogs: any DialogServiceProtocol {
        self.base.dialogs
    }

    var snapshots: any SnapshotManagerProtocol {
        self.base.snapshots
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        self.base.desktopObservation
    }
}
