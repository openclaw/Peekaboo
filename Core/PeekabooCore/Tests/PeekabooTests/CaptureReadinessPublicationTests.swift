import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

@Suite(.serialized)
@MainActor
struct CaptureReadinessPublicationTests {
    @Test
    func `authenticated transport retains every preparation blocker`() async throws {
        let blockers: [ScreenCaptureKitOwnerLease.UncoordinatedProcess] = [
            .init(processIdentifier: 4242, processStartIdentity: 9001, executablePath: "/synthetic/first"),
            .init(processIdentifier: 4343, processStartIdentity: 9002, executablePath: "/synthetic/second"),
        ]
        let server = Self.server(hostIdentity: .current(), preparation: {
            throw ScreenCaptureKitOwnerLease.LeaseError.uncoordinatedProcesses(blockers)
        })
        let socket = FileManager.default.temporaryDirectory
            .appendingPathComponent("s-\(UUID().uuidString).sock").path
        let host = PeekabooBridgeHost(socketPath: socket, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socket, requestTimeoutSec: 2)
        let handshake = try await client.handshake(
            client: .init(bundleIdentifier: "synthetic.readiness", teamIdentifier: nil, processIdentifier: getpid()))
        #expect(handshake.operationAttestation != nil)
        let error = await #expect(throws: DesktopActionFailure.self) {
            _ = try await client.desktopObservation(.init(
                target: .screen(index: 0), capture: .init(engine: .modern), detection: .init(mode: .none)))
        }
        #expect(error?.standardErrorCode == .captureFailed)
        #expect(error?.screenCaptureKitOwnershipDiagnostic?.blockers.map(\.processIdentifier) == [4242, 4343])
        #expect(error?.screenCaptureKitOwnershipDiagnostic?.blockers.map(\.processStartIdentity) == [9001, 9002])
        await host.stop()
    }

    @Test
    func `blocked preparation preserves implementation proof`() async throws {
        let blocker = ScreenCaptureKitOwnerLease.UncoordinatedProcess(
            processIdentifier: 4242,
            processStartIdentity: 9001,
            executablePath: "/synthetic/PotentialHost.app/Contents/MacOS/PotentialHost")
        let server = Self.server(preparation: {
            throw ScreenCaptureKitOwnerLease.LeaseError.uncoordinatedProcesses([blocker])
        })
        try await server.prepareScreenCaptureKitOwnershipForServing()

        // This assertion also ran, and failed, against unchanged production code.
        #expect(server.hostCapabilities.contains("screenCaptureKitOwnershipEnforcement"))
        #expect(!server.hostCapabilities.contains(PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership))
        #expect(server.hostCapabilities.contains(PeekabooBridgeHostCapability.classicCaptureWithoutScreenCaptureKit))
        #expect(server.screenCaptureKitReadiness?.state == .blocked)
        #expect(server.screenCaptureKitReadiness?.failure?.blockers == [.init(
            processIdentifier: 4242,
            processStartIdentity: 9001,
            executablePath: "/synthetic/PotentialHost.app/Contents/MacOS/PotentialHost")])
    }

    @Test(arguments: [CaptureEnginePreference.auto, .modern, .legacy])
    func `blocked readiness only admits explicit classic`(engine: CaptureEnginePreference) async throws {
        let server = Self.server(preparation: {
            throw ScreenCaptureKitOwnerLease.LeaseError.preparationTimedOut(seconds: 1)
        })
        try await server.prepareScreenCaptureKitOwnershipForServing()
        let request = PeekabooBridgeRequest.desktopObservation(.init(
            target: .screen(index: 0), capture: .init(engine: engine), detection: .init(mode: .none)))
        if engine == .legacy {
            try server.validateOperationAccess(
                for: request,
                permissions: Self.permissions,
                effectiveOps: [.desktopObservation])
        } else {
            let error = #expect(throws: ScreenCaptureKitOwnershipDiagnostic.self) {
                try server.validateOperationAccess(
                    for: request, permissions: Self.permissions, effectiveOps: [.desktopObservation])
            }
            #expect(error?.kind == .timedOut)
        }
    }

    @Test
    func `caller capabilities cannot invent implementation or classic proof`() async throws {
        let claimed: Set<String> = [
            PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
            PeekabooBridgeHostCapability.screenCaptureKitOwnershipEnforcement,
            PeekabooBridgeHostCapability.classicCaptureWithoutScreenCaptureKit,
        ]
        for allowed in [Set<PeekabooBridgeOperation>(), [.desktopObservation]] {
            let server = Self.server(supportsCaptureContract: false, allowedOperations: allowed, capabilities: claimed)
            try await server.prepareScreenCaptureKitOwnershipForServing()
            #expect(server.hostCapabilities.isDisjoint(with: claimed))
        }
        let disabled = Self.server(allowedOperations: [], capabilities: claimed)
        #expect(disabled.hostCapabilities.isDisjoint(with: claimed))
    }

    @Test
    func `registration failure remains typed and classic capable`() async throws {
        let server = Self.server(registrar: {
            throw ScreenCaptureKitOwnerLease.LeaseError.systemCall(
                operation: "register",
                path: "/synthetic/marker",
                code: 13)
        })
        try await server.prepareScreenCaptureKitOwnershipForServing()
        #expect(server.screenCaptureKitReadiness?.failure?.stage == .registration)
        #expect(server.screenCaptureKitReadiness?.failure?.systemCode == 13)
        #expect(server.screenCaptureKitReadiness?.failure?.path == "/synthetic/marker")
        #expect(server.hostCapabilities.contains(PeekabooBridgeHostCapability.classicCaptureWithoutScreenCaptureKit))
    }

    @Test
    func `cancelled preparation publishes unavailable readiness while retaining classic proof`() async throws {
        let server = Self.server(preparation: { throw CancellationError() })
        try await server.prepareScreenCaptureKitOwnershipForServing()
        #expect(server.screenCaptureKitReadiness?.state == .unavailable)
        #expect(server.screenCaptureKitReadiness?.failure?.kind == .cancelled)
        #expect(server.screenCaptureKitReadiness?.failure?.stage == .preparation)
        #expect(server.hostCapabilities.contains(PeekabooBridgeHostCapability.classicCaptureWithoutScreenCaptureKit))
        #expect(!server.hostCapabilities.contains(PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership))
    }

    @Test
    func `handshake absent and future readiness decode without authority`() throws {
        let old = Self.handshake(readiness: nil)
        let encoded = try JSONEncoder().encode(old)
        #expect(try JSONDecoder().decode(PeekabooBridgeHandshakeResponse.self, from: encoded)
            .screenCaptureKitReadiness == nil)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["screenCaptureKitReadiness"] = ["state": "futureState"]
        let future = try JSONDecoder().decode(
            PeekabooBridgeHandshakeResponse.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(future.screenCaptureKitReadiness?.state == .unknown)
        #expect(future.screenCaptureKitReadiness?.permitsAttempt == false)
        object["screenCaptureKitReadiness"] = ["state": "ready"]
        let unobserved = try JSONDecoder().decode(
            PeekabooBridgeHandshakeResponse.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(unobserved.screenCaptureKitReadiness?.permitsAttempt == false)
        let oldPeer = try JSONDecoder().decode(OldHandshake.self, from: JSONEncoder().encode(Self.handshake(
            readiness: .init(state: .ready))))
        #expect(oldPeer.negotiatedVersion == PeekabooBridgeConstants.protocolVersion)
    }

    @Test
    func `multi blocker diagnostics survive wire and earlier mutation`() throws {
        let error = ScreenCaptureKitOwnerLease.LeaseError.uncoordinatedHosts([
            .init(
                socketPath: "/synthetic/a.sock",
                processIdentifier: 41,
                processStartIdentity: 51,
                buildIdentity: "build-a"),
            .init(
                socketPath: "/synthetic/b.sock",
                processIdentifier: 42,
                processStartIdentity: 52,
                buildIdentity: "build-b"),
        ])
        let diagnostic = ScreenCaptureKitOwnershipDiagnostic.capturing(error, stage: .entry)
        let readiness = ScreenCaptureKitReadiness.failed(error, stage: .preparation)
        let handshake = try JSONDecoder().decode(
            PeekabooBridgeHandshakeResponse.self, from: JSONEncoder().encode(Self.handshake(readiness: readiness)))
        #expect(handshake.screenCaptureKitReadiness == readiness)
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let failure = try #require(ObservationActionResultSemantics.preservingFailure(
            diagnostic, after: outcome, targetReceipt: nil, operation: "capture") as? DesktopActionFailure)
        #expect(failure.outcome.dispatchState.mutationDispatched)
        #expect(failure.screenCaptureKitOwnershipDiagnostic == diagnostic)
        let envelope = PeekabooBridgeServer.bridgeErrorEnvelope(for: failure, operation: .desktopObservation)
        let decoded = try JSONDecoder().decode(PeekabooBridgeErrorEnvelope.self, from: JSONEncoder().encode(envelope))
        #expect(decoded.desktopActionFailure?.screenCaptureKitOwnershipDiagnostic == diagnostic)
        #expect(decoded.operationMayHaveCompleted)
        #expect(decoded.legacyCompatible.screenCaptureKitOwnershipDiagnostic == nil)
        #expect(decoded.legacyCompatible.operationMayHaveCompleted)
    }

    private struct OldHandshake: Decodable {
        let negotiatedVersion: PeekabooBridgeProtocolVersion
        let supportedOperations: [PeekabooBridgeOperation]
    }

    private static let permissions = PermissionsStatus(
        screenRecording: true, accessibility: true, appleScript: false, postEvent: false)

    private static func handshake(readiness: ScreenCaptureKitReadiness?) -> PeekabooBridgeHandshakeResponse {
        .init(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: "fixture",
            supportedOperations: [.desktopObservation],
            screenCaptureKitReadiness: readiness)
    }

    static func server(
        supportsCaptureContract: Bool = true,
        allowedOperations: Set<PeekabooBridgeOperation> = [.desktopObservation],
        capabilities: Set<String> = [],
        hostIdentity: PeekabooBridgeHostIdentity? = nil,
        observation: (any DesktopObservationServiceProtocol)? = nil,
        registrar: @MainActor @Sendable () throws -> Void = {},
        preparation: @escaping @Sendable () async throws -> Void = {}) -> PeekabooBridgeServer
    {
        PeekabooBridgeServer(
            services: StubServices(
                snapshots: InMemorySnapshotManager(),
                desktopObservation: observation,
                supportsScreenCaptureKitProcessOwnership: supportsCaptureContract,
                supportsClassicCaptureWithoutScreenCaptureKit: supportsCaptureContract,
                supportsDesktopObservationCaptureEngine: supportsCaptureContract),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: allowedOperations,
            hostIdentity: hostIdentity,
            hostCapabilities: capabilities,
            desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("readiness-\(UUID().uuidString)")),
            screenCaptureKitProcessCapabilityRegistrar: registrar,
            screenCaptureKitOwnershipPreparer: preparation,
            screenCaptureKitOwnerClaimProvider: {
                Issue.record("Preparation must not claim ownership")
                throw ScreenCaptureKitOwnerLease.LeaseError.invalidOwnerIdentity("unexpected claim")
            },
            postEventAccessEvaluator: { false },
            postEventAccessRequester: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, appleScript: false, postEvent: false)
            },
            windowOwnerProcessIdentifierProvider: { _ in nil },
            windowBoundsProvider: { _ in nil },
            maximizedVisibleWorkAreaProvider: { _ in nil },
            processStartIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in false })
    }
}
