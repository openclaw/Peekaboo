import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@_spi(Testing) @testable import PeekabooAutomationKit
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct AutoScreenCaptureConcurrencyTests {
    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.auto-screen-concurrency-tests",
        teamIdentifier: nil,
        processIdentifier: getpid(),
        hostname: nil)

    @Test
    func `Bridge publication deadline reserves the process preparation boundary`() {
        let processPreparation = ScreenCaptureKitOwnerLease.defaultProcessCapabilityPreparationTimeoutSeconds
        let bridgePublication = PeekabooBridgeServer.defaultScreenCaptureKitOwnershipPreparationTimeoutSeconds

        #expect(bridgePublication >= processPreparation + 1)
        #expect(bridgePublication < processPreparation + 2)
    }

    @Test
    func `Bridge registration failure refuses automatic capture with its diagnostic`() async throws {
        let socketPath = Self.fixtureSocketPath()
        let ownerReceipt = try #require(Self.currentProcessOwnerReceipt())
        let claimCounter = BridgeOwnerClaimCounter()
        let observation = BridgeAutoScreenObservationService(failSlowAutomaticCapture: false)
        let services = StubServices(
            snapshots: InMemorySnapshotManager(),
            desktopObservation: observation,
            supportsScreenCaptureKitProcessOwnership: true)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            hostCapabilities: [PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership],
            desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: URL(fileURLWithPath: socketPath + ".coordination")),
            screenCaptureKitProcessCapabilityRegistrar: {
                throw OperationError.captureFailed(reason: "Fixture registration failure")
            },
            screenCaptureKitOwnershipPreparer: {},
            screenCaptureKitOwnerClaimProvider: {
                claimCounter.record()
                return ownerReceipt
            },
            postEventAccessEvaluator: { true },
            postEventAccessRequester: { false },
            permissionStatusEvaluator: Self.grantedPermissions,
            windowOwnerProcessIdentifierProvider: { _ in nil },
            windowBoundsProvider: { _ in nil },
            maximizedVisibleWorkAreaProvider: { _ in nil },
            processStartIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in false })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 0.5)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = try await self.makeNegotiatedClient(
            socketPath: socketPath,
            requestTimeoutSec: 2)

        let error = await #expect(throws: DesktopActionFailure.self) {
            _ = try await client.desktopObservation(Self.backgroundAutoScreenRequest)
        }
        #expect(error?.screenCaptureKitOwnershipDiagnostic?.stage == .registration)
        #expect(error?.standardErrorCode == .captureFailed)
        #expect(observation.requests.isEmpty)
        #expect(!claimCounter.didRecord)
        await host.stop()
    }

    @Test
    func `Bridge prepares screen ownership before serving concurrent captures inside its envelope`() async throws {
        let socketPath = Self.fixtureSocketPath()
        let ownerReceipt = try #require(Self.currentProcessOwnerReceipt())
        let claimCounter = BridgeOwnerClaimCounter()
        let preparation = BridgeOwnerPreparationGate()
        let captureLane = BridgeSyntheticCaptureLane(
            captureDelay: .milliseconds(20),
            settlementDelay: .milliseconds(5))
        let observation = BridgeAutoScreenObservationService(captureLane: captureLane)
        let services = StubServices(
            snapshots: InMemorySnapshotManager(),
            desktopObservation: observation,
            supportsScreenCaptureKitProcessOwnership: true)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: URL(fileURLWithPath: socketPath + ".coordination")),
            screenCaptureKitProcessCapabilityRegistrar: {},
            screenCaptureKitOwnershipPreparer: {
                await preparation.prepare()
            },
            screenCaptureKitOwnerClaimProvider: {
                claimCounter.record()
                return ownerReceipt
            },
            postEventAccessEvaluator: { true },
            postEventAccessRequester: { false },
            permissionStatusEvaluator: Self.grantedPermissions,
            windowOwnerProcessIdentifierProvider: { _ in nil },
            windowBoundsProvider: { _ in nil },
            maximizedVisibleWorkAreaProvider: { _ in nil },
            processStartIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in false })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        let start = Task { try await host.startChecked() }
        await preparation.waitUntilStarted()
        #expect(!claimCounter.didRecord)
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        await preparation.release()
        try await start.value
        defer { Task { await host.stop() } }
        let firstClient = try await self.makeNegotiatedClient(
            socketPath: socketPath,
            requestTimeoutSec: 2)
        let secondClient = try await self.makeNegotiatedClient(
            socketPath: socketPath,
            requestTimeoutSec: 2)

        async let first = firstClient.desktopObservation(Self.backgroundAutoScreenRequest)
        async let second = secondClient.desktopObservation(Self.backgroundAutoScreenRequest)
        _ = try await (first, second)

        #expect(observation.requests.count == 2)
        #expect(observation.requests.allSatisfy { $0.capture.engine == .auto })
        #expect(observation.legacyAttemptCount == 0)
        #expect(observation.modernAttemptCount == 2)
        #expect(await captureLane.captureCount == 2)
        #expect(await captureLane.settlementCount == 2)
        #expect(claimCounter.count == 2)
        await host.stop()
    }

    @Test
    func `Bridge preparation failure suppresses screen ownership capability`() async throws {
        let socketPath = Self.fixtureSocketPath()
        let preparation = BridgeOwnerPreparationGate()
        let observation = BridgeAutoScreenObservationService(failSlowAutomaticCapture: false)
        let services = StubServices(
            snapshots: InMemorySnapshotManager(),
            desktopObservation: observation,
            supportsScreenCaptureKitProcessOwnership: true)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: URL(fileURLWithPath: socketPath + ".coordination")),
            screenCaptureKitProcessCapabilityRegistrar: {},
            screenCaptureKitOwnershipPreparer: {
                await preparation.prepare()
            },
            screenCaptureKitOwnerClaimProvider: {
                Issue.record("Preparation must not claim an owner")
                throw ScreenCaptureKitOwnerLease.LeaseError.invalidOwnerIdentity("unexpected fixture claim")
            },
            screenCaptureKitOwnershipPreparationTimeoutSeconds: 0.02,
            postEventAccessEvaluator: { true },
            postEventAccessRequester: { false },
            permissionStatusEvaluator: Self.grantedPermissions,
            windowOwnerProcessIdentifierProvider: { _ in nil },
            windowBoundsProvider: { _ in nil },
            maximizedVisibleWorkAreaProvider: { _ in nil },
            processStartIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in false })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 0.5)
        try await host.startChecked()
        await preparation.release()
        defer { Task { await host.stop() } }
        let client = try await self.makeNegotiatedClient(
            socketPath: socketPath,
            requestTimeoutSec: 2)

        let error = await #expect(throws: DesktopActionFailure.self) {
            _ = try await client.desktopObservation(Self.backgroundAutoScreenRequest)
        }
        #expect(error?.screenCaptureKitOwnershipDiagnostic?.kind == .timedOut)
        #expect(error?.screenCaptureKitOwnershipDiagnostic?.timeoutSeconds == 0.02)
        #expect(observation.requests.isEmpty)
        await host.stop()
    }

    @Test
    func `Bridge stop during ownership preparation prevents later socket publication`() async throws {
        let socketPath = Self.fixtureSocketPath()
        let preparation = BridgeOwnerPreparationGate()
        let services = StubServices(
            snapshots: InMemorySnapshotManager(),
            desktopObservation: BridgeAutoScreenObservationService(),
            supportsScreenCaptureKitProcessOwnership: true)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: URL(fileURLWithPath: socketPath + ".coordination")),
            screenCaptureKitProcessCapabilityRegistrar: {},
            screenCaptureKitOwnershipPreparer: {
                await preparation.prepare()
            },
            screenCaptureKitOwnerClaimProvider: {
                Issue.record("Preparation must not claim an owner")
                throw ScreenCaptureKitOwnerLease.LeaseError.invalidOwnerIdentity("unexpected fixture claim")
            },
            postEventAccessEvaluator: { true },
            postEventAccessRequester: { false },
            permissionStatusEvaluator: Self.grantedPermissions,
            windowOwnerProcessIdentifierProvider: { _ in nil },
            windowBoundsProvider: { _ in nil },
            maximizedVisibleWorkAreaProvider: { _ in nil },
            processStartIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in false })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [])
        let start = Task { try await host.startChecked() }
        await preparation.waitUntilStarted()

        #expect(await host.stop() == .stopped)
        await preparation.release()
        await #expect(throws: CancellationError.self) {
            try await start.value
        }
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test
    func `Bridge start cancellation does not cancel or wait for shared ownership preparation`() async throws {
        let socketPath = Self.fixtureSocketPath()
        let preparation = BridgeOwnerPreparationGate()
        let completion = BridgeStartCompletionFlag()
        let services = StubServices(
            snapshots: InMemorySnapshotManager(),
            desktopObservation: BridgeAutoScreenObservationService(),
            supportsScreenCaptureKitProcessOwnership: true)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: URL(fileURLWithPath: socketPath + ".coordination")),
            screenCaptureKitProcessCapabilityRegistrar: {},
            screenCaptureKitOwnershipPreparer: {
                await preparation.prepare()
            },
            screenCaptureKitOwnerClaimProvider: {
                Issue.record("Preparation must not claim an owner")
                throw ScreenCaptureKitOwnerLease.LeaseError.invalidOwnerIdentity("unexpected fixture claim")
            },
            postEventAccessEvaluator: { true },
            postEventAccessRequester: { false },
            permissionStatusEvaluator: Self.grantedPermissions,
            windowOwnerProcessIdentifierProvider: { _ in nil },
            windowBoundsProvider: { _ in nil },
            maximizedVisibleWorkAreaProvider: { _ in nil },
            processStartIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in false })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [])
        let start = Task { try await host.startChecked() }
        let completionObserver = Task {
            let result = await start.result
            await completion.finish()
            return result
        }
        await preparation.waitUntilStarted()

        start.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await !(completion.isFinished), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await completion.isFinished)
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        await preparation.release()
        let result = await completionObserver.value
        guard case let .failure(error) = result else {
            Issue.record("Cancelled Bridge start unexpectedly succeeded")
            return
        }
        #expect(error is CancellationError)
        #expect(await host.stop() == .stopped)
    }

    @Test
    func `Fresh Bridge owner claims before concurrent background auto screen observations`() async throws {
        let socketPath = Self.fixtureSocketPath()
        let ownerReceipt = try #require(Self.currentProcessOwnerReceipt())
        let claimCounter = BridgeOwnerClaimCounter()
        let observation = BridgeAutoScreenObservationService()
        let services = StubServices(
            snapshots: InMemorySnapshotManager(),
            desktopObservation: observation,
            supportsScreenCaptureKitProcessOwnership: true)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: URL(fileURLWithPath: socketPath + ".coordination")),
            screenCaptureKitProcessCapabilityRegistrar: {},
            screenCaptureKitOwnershipPreparer: {},
            screenCaptureKitOwnerClaimProvider: {
                claimCounter.record()
                return ownerReceipt
            },
            postEventAccessEvaluator: { true },
            postEventAccessRequester: { false },
            permissionStatusEvaluator: Self.grantedPermissions,
            windowOwnerProcessIdentifierProvider: { _ in nil },
            windowBoundsProvider: { _ in nil },
            maximizedVisibleWorkAreaProvider: { _ in nil },
            processStartIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in false })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 0.5)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let firstClient = try await self.makeNegotiatedClient(
            socketPath: socketPath,
            requestTimeoutSec: 2)
        let secondClient = try await self.makeNegotiatedClient(
            socketPath: socketPath,
            requestTimeoutSec: 2)

        async let first = firstClient.desktopObservation(Self.backgroundAutoScreenRequest)
        async let second = secondClient.desktopObservation(Self.backgroundAutoScreenRequest)
        let (firstResult, secondResult) = try await (first, second)
        let results = [firstResult, secondResult]

        #expect(results.count == 2)
        #expect(observation.requests.count == 2)
        #expect(observation.requests.allSatisfy { $0.capture.engine == .auto })
        #expect(observation.legacyAttemptCount == 0)
        #expect(observation.modernAttemptCount == 2)
        #expect(claimCounter.count == 2)
        await host.stop()
    }

    @Test
    func `Claimed screen owner generation drift preserves automatic capture`() async throws {
        let socketPath = Self.fixtureSocketPath()
        let ownerReceipt = try #require(Self.currentProcessOwnerReceipt())
        let claimCounter = BridgeOwnerClaimCounter()
        let differentOwnerReceipt = ScreenCaptureKitOwnerLease.OwnerReceipt(
            processIdentifier: ownerReceipt.processIdentifier,
            processStartIdentity: ownerReceipt.processStartIdentity + 1)
        let observation = BridgeAutoScreenObservationService(failSlowAutomaticCapture: false)
        let services = StubServices(
            snapshots: InMemorySnapshotManager(),
            desktopObservation: observation,
            supportsScreenCaptureKitProcessOwnership: true)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: URL(fileURLWithPath: socketPath + ".coordination")),
            screenCaptureKitProcessCapabilityRegistrar: {},
            screenCaptureKitOwnershipPreparer: {},
            screenCaptureKitOwnerClaimProvider: {
                claimCounter.record()
                return differentOwnerReceipt
            },
            postEventAccessEvaluator: { true },
            postEventAccessRequester: { false },
            permissionStatusEvaluator: Self.grantedPermissions,
            windowOwnerProcessIdentifierProvider: { _ in nil },
            windowBoundsProvider: { _ in nil },
            maximizedVisibleWorkAreaProvider: { _ in nil },
            processStartIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in false })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 0.5)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = try await self.makeNegotiatedClient(
            socketPath: socketPath,
            requestTimeoutSec: 2)

        _ = try await client.desktopObservation(Self.backgroundAutoScreenRequest)

        #expect(observation.requests.count == 1)
        #expect(observation.requests.first?.capture.engine == .auto)
        #expect(observation.legacyAttemptCount == 1)
        #expect(observation.modernAttemptCount == 0)
        #expect(claimCounter.count == 1)
        await host.stop()
    }

    @Test
    func `Competing screen owner claim preserves automatic capture`() async throws {
        let socketPath = Self.fixtureSocketPath()
        let ownerReceipt = try #require(Self.currentProcessOwnerReceipt())
        let competingReceipt = ScreenCaptureKitOwnerLease.OwnerReceipt(
            processIdentifier: ownerReceipt.processIdentifier + 1,
            processStartIdentity: ownerReceipt.processStartIdentity + 1)
        let claimCounter = BridgeOwnerClaimCounter()
        let observation = BridgeAutoScreenObservationService(failSlowAutomaticCapture: false)
        let services = StubServices(
            snapshots: InMemorySnapshotManager(),
            desktopObservation: observation,
            supportsScreenCaptureKitProcessOwnership: true)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: URL(fileURLWithPath: socketPath + ".coordination")),
            screenCaptureKitProcessCapabilityRegistrar: {},
            screenCaptureKitOwnershipPreparer: {},
            screenCaptureKitOwnerClaimProvider: {
                claimCounter.record()
                throw ScreenCaptureKitOwnerLease.LeaseError.ownedByAnotherProcess(
                    path: "/tmp/peekaboo-competing-owner.lock",
                    receipt: competingReceipt)
            },
            postEventAccessEvaluator: { true },
            postEventAccessRequester: { false },
            permissionStatusEvaluator: Self.grantedPermissions,
            windowOwnerProcessIdentifierProvider: { _ in nil },
            windowBoundsProvider: { _ in nil },
            maximizedVisibleWorkAreaProvider: { _ in nil },
            processStartIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in false })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 0.5)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = try await self.makeNegotiatedClient(
            socketPath: socketPath,
            requestTimeoutSec: 2)

        _ = try await client.desktopObservation(Self.backgroundAutoScreenRequest)

        #expect(observation.requests.count == 1)
        #expect(observation.requests.first?.capture.engine == .auto)
        #expect(observation.legacyAttemptCount == 1)
        #expect(observation.modernAttemptCount == 0)
        #expect(claimCounter.count == 1)
        await host.stop()
    }

    @Test
    func `Unexpected screen owner claim failure preserves automatic capture`() async throws {
        let socketPath = Self.fixtureSocketPath()
        let claimCounter = BridgeOwnerClaimCounter()
        let observation = BridgeAutoScreenObservationService(failSlowAutomaticCapture: false)
        let services = StubServices(
            snapshots: InMemorySnapshotManager(),
            desktopObservation: observation,
            supportsScreenCaptureKitProcessOwnership: true)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: URL(fileURLWithPath: socketPath + ".coordination")),
            screenCaptureKitProcessCapabilityRegistrar: {},
            screenCaptureKitOwnershipPreparer: {},
            screenCaptureKitOwnerClaimProvider: {
                claimCounter.record()
                throw ScreenCaptureKitOwnerLease.LeaseError.invalidOwnerIdentity("fixture drift")
            },
            postEventAccessEvaluator: { true },
            postEventAccessRequester: { false },
            permissionStatusEvaluator: Self.grantedPermissions,
            windowOwnerProcessIdentifierProvider: { _ in nil },
            windowBoundsProvider: { _ in nil },
            maximizedVisibleWorkAreaProvider: { _ in nil },
            processStartIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in false })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 0.5)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = try await self.makeNegotiatedClient(
            socketPath: socketPath,
            requestTimeoutSec: 2)

        _ = try await client.desktopObservation(Self.backgroundAutoScreenRequest)

        #expect(observation.requests.count == 1)
        #expect(observation.requests.first?.capture.engine == .auto)
        #expect(observation.legacyAttemptCount == 1)
        #expect(observation.modernAttemptCount == 0)
        #expect(claimCounter.count == 1)
        await host.stop()
    }

    @Test
    func `Claimed automatic screen capture falls back to legacy after modern failure`() async throws {
        let socketPath = Self.fixtureSocketPath()
        let ownerReceipt = try #require(Self.currentProcessOwnerReceipt())
        let claimCounter = BridgeOwnerClaimCounter()
        let observation = BridgeAutoScreenObservationService(
            failSlowAutomaticCapture: false,
            failModernAutomaticCapture: true)
        let services = StubServices(
            snapshots: InMemorySnapshotManager(),
            desktopObservation: observation,
            supportsScreenCaptureKitProcessOwnership: true)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: URL(fileURLWithPath: socketPath + ".coordination")),
            screenCaptureKitProcessCapabilityRegistrar: {},
            screenCaptureKitOwnershipPreparer: {},
            screenCaptureKitOwnerClaimProvider: {
                claimCounter.record()
                return ownerReceipt
            },
            postEventAccessEvaluator: { true },
            postEventAccessRequester: { false },
            permissionStatusEvaluator: Self.grantedPermissions,
            windowOwnerProcessIdentifierProvider: { _ in nil },
            windowBoundsProvider: { _ in nil },
            maximizedVisibleWorkAreaProvider: { _ in nil },
            processStartIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in false })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 0.5)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = try await self.makeNegotiatedClient(
            socketPath: socketPath,
            requestTimeoutSec: 2)

        _ = try await client.desktopObservation(Self.backgroundAutoScreenRequest)

        #expect(observation.requests.count == 1)
        #expect(observation.requests.first?.capture.engine == .auto)
        #expect(observation.modernAttemptCount == 1)
        #expect(observation.legacyAttemptCount == 1)
        #expect(claimCounter.count == 1)
        await host.stop()
    }

    private static func fixtureSocketPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString).sock").path
    }

    private static let backgroundAutoScreenRequest = DesktopObservationRequest(
        target: .screen(index: 0),
        capture: .init(engine: .auto, focus: .background),
        detection: .init(mode: .none))

    private static func grantedPermissions(_: Bool) -> PermissionsStatus {
        PermissionsStatus(
            screenRecording: true,
            accessibility: true,
            appleScript: false,
            postEvent: true)
    }

    private static func currentProcessOwnerReceipt() -> ScreenCaptureKitOwnerLease.OwnerReceipt? {
        let processIdentifier = getpid()
        guard let processStartIdentity = SystemIdentityResolver.processStartIdentity(processIdentifier) else {
            return nil
        }
        return ScreenCaptureKitOwnerLease.OwnerReceipt(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity)
    }

    private func makeNegotiatedClient(
        socketPath: String,
        requestTimeoutSec: TimeInterval) async throws -> PeekabooBridgeClient
    {
        let client = TrustedBridgeClientFixture.make(
            socketPath: socketPath,
            requestTimeoutSec: requestTimeoutSec)
        let handshake = try await client.handshake(client: Self.clientIdentity)
        #expect(handshake.negotiatedVersion == PeekabooBridgeConstants.protocolVersion)
        #expect(handshake.operationAttestation != nil)
        #expect(handshake.operationSessionAttestation != nil)
        return client
    }
}

@MainActor
private final class BridgeAutoScreenObservationService: DesktopObservationServiceProtocol {
    private let failSlowAutomaticCapture: Bool
    private let failModernAutomaticCapture: Bool
    private let captureLane: BridgeSyntheticCaptureLane?
    private(set) var requests: [DesktopObservationRequest] = []
    private(set) var legacyAttemptCount = 0
    private(set) var modernAttemptCount = 0

    init(
        failSlowAutomaticCapture: Bool = true,
        failModernAutomaticCapture: Bool = false,
        captureLane: BridgeSyntheticCaptureLane? = nil)
    {
        self.failSlowAutomaticCapture = failSlowAutomaticCapture
        self.failModernAutomaticCapture = failModernAutomaticCapture
        self.captureLane = captureLane
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.requests.append(request)
        switch request.capture.engine {
        case .modern:
            self.modernAttemptCount += 1
            if self.failModernAutomaticCapture {
                throw OperationError.captureFailed(reason: "Fixture modern capture failed")
            }
            if let captureLane {
                await captureLane.capture()
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        case .auto where ScreenCaptureService.prefersModernFirstAutomaticCaptureForTesting:
            self.modernAttemptCount += 1
            if self.failModernAutomaticCapture {
                self.legacyAttemptCount += 1
            } else if let captureLane {
                await captureLane.capture()
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        case .auto, .legacy:
            self.legacyAttemptCount += 1
            if self.failSlowAutomaticCapture {
                try await Task.sleep(for: .seconds(1))
                throw OperationError.captureFailed(reason: "Fixture classic capture exceeded the Bridge envelope")
            }
        }
        return DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: StubScreenCaptureService.sampleData,
                metadata: CaptureMetadata(
                    size: .init(width: 1, height: 1),
                    mode: .screen,
                    displayInfo: DisplayInfo(
                        index: 0,
                        name: "Fixture",
                        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                        scaleFactor: 1),
                    diagnostics: .init(
                        requestedScale: request.capture.scale,
                        nativeScale: 1,
                        outputScale: 1,
                        scaleSource: "fixture",
                        finalPixelSize: .init(width: 1, height: 1),
                        engine: "ScreenCaptureKit"))),
            elements: nil)
    }
}

private actor BridgeOwnerPreparationGate {
    private var didStart = false
    private var didRelease = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func prepare() async {
        self.didStart = true
        self.startWaiters.forEach { $0.resume() }
        self.startWaiters.removeAll()
        guard !self.didRelease else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !self.didStart else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func release() {
        self.didRelease = true
        self.releaseWaiters.forEach { $0.resume() }
        self.releaseWaiters.removeAll()
    }
}

private actor BridgeStartCompletionFlag {
    private(set) var isFinished = false

    func finish() {
        self.isFinished = true
    }
}

private final class BridgeOwnerClaimCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        self.lock.withLock { self.storedCount }
    }

    var didRecord: Bool {
        self.lock.withLock { self.storedCount > 0 }
    }

    func record() {
        self.lock.withLock { self.storedCount += 1 }
    }
}

private actor BridgeSyntheticCaptureLane {
    let captureDelay: Duration
    let settlementDelay: Duration
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var captureCount = 0
    private(set) var settlementCount = 0

    init(captureDelay: Duration, settlementDelay: Duration) {
        self.captureDelay = captureDelay
        self.settlementDelay = settlementDelay
    }

    func capture() async {
        if self.busy {
            await withCheckedContinuation { continuation in
                self.waiters.append(continuation)
            }
        } else {
            self.busy = true
        }
        try? await Task.sleep(for: self.captureDelay)
        self.captureCount += 1
        try? await Task.sleep(for: self.settlementDelay)
        self.settlementCount += 1
        if self.waiters.isEmpty {
            self.busy = false
        } else {
            self.waiters.removeFirst().resume()
        }
    }
}
