import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct RemoteCaptureEnginePlanCacheRoutingTests {
    @Test
    func `two clients reuse one owner host plan while classic and auto avoid modern cache`() async throws {
        let socketPath = "/tmp/peekaboo-capture-engine-plan-route-\(UUID().uuidString).sock"
        let fixtureBounds = Self.windowBounds
        let hostIdentity = PeekabooBridgeHostIdentity.current()
        let processID = getpid()
        let processStartIdentity = try #require(hostIdentity.processStartIdentity)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-plan-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        // Use the real lease algorithm in a private namespace, never the live SCK registry or operator.
        let ownerLease = ScreenCaptureKitOwnerLease(
            lockURL: directory.appendingPathComponent("owner.lock"),
            ownerIdentity: .init(
                processIdentifier: processID,
                processStartIdentity: processStartIdentity,
                buildIdentity: "capture-plan-fixture"),
            processStartIdentity: { $0 == processID ? processStartIdentity : nil })
        let observation = CountingCaptureEngineObservationService(ownerLease: ownerLease)
        let server = PeekabooBridgeServer(
            services: PlanCacheOwnerServices(observation: observation),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            hostIdentity: hostIdentity,
            screenCaptureKitProcessCapabilityRegistrar: { _ = try ownerLease.claim() },
            screenCaptureKitOwnershipPreparer: { _ = try ownerLease.claim() },
            screenCaptureKitOwnerClaimProvider: { try ownerLease.claim().receipt },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: false,
                    postEvent: true)
            },
            windowOwnerProcessIdentifierProvider: { $0 == 42 ? 123 : nil },
            windowBoundsProvider: { $0 == 42 ? fixtureBounds : nil },
            processStartIdentityProvider: { $0 == 123 ? 456 : nil })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let firstClient = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await firstClient.handshake(client: .init(
            bundleIdentifier: "test.capture-engine.first",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        #expect(handshake.hostKind == .onDemand)
        try #require(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.desktopObservationCaptureEngine) == true)
        try #require(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership) == true)
        #expect(handshake.hostIdentity == hostIdentity)
        #expect(handshake.negotiatedVersion == PeekabooBridgeConstants.protocolVersion)
        let listener = try #require(handshake.operationAttestation)
        let firstSession = try #require(handshake.operationSessionAttestation)

        let firstRemote = RemoteDesktopObservationService(
            client: firstClient,
            supportsDesktopObservationCaptureEngine: handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.desktopObservationCaptureEngine) == true)
        let secondClient = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let secondHandshake = try await secondClient.handshake(client: .init(
            bundleIdentifier: "test.capture-engine.second",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        #expect(secondHandshake.operationAttestation == listener)
        try #require(secondHandshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership) == true)
        let secondSession = try #require(secondHandshake.operationSessionAttestation)
        #expect(secondSession.sessionID != firstSession.sessionID)
        let secondRemote = RemoteDesktopObservationService(
            client: secondClient,
            supportsDesktopObservationCaptureEngine: secondHandshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.desktopObservationCaptureEngine) == true)

        let first = try await firstRemote.observe(Self.request(engine: .modern))
        let second = try await secondRemote.observe(Self.request(engine: .modern))

        #expect(first.capture.metadata.diagnostics?.windowPlanCacheStatus == .miss)
        #expect(second.capture.metadata.diagnostics?.windowPlanCacheStatus == .hit)
        #expect(first.capture.metadata.diagnostics?.windowPlanCacheGeneration == 1)
        #expect(second.capture.metadata.diagnostics?.windowPlanCacheGeneration == 1)
        #expect(observation.modernLookups == 2)
        #expect(observation.modernBuilds == 1)
        #expect(observation.modernHits == 1)
        #expect(observation.legacyCalls == 0)
        #expect(observation.ownerReceipts.count == 2)
        #expect(observation.ownerReceipts.allSatisfy {
            $0.processIdentifier == processID && $0.processStartIdentity == processStartIdentity
        })
        for (client, session) in [(firstClient, firstSession), (secondClient, secondSession)] {
            let receipt = try #require(await client.lastOperationReceipt())
            #expect(receipt.payload.operation == .desktopObservation)
            #expect(receipt.payload.listenerInstanceID == listener.listenerInstanceID)
            #expect(receipt.payload.host == listener.host)
            #expect(receipt.payload.sessionID == session.sessionID)
            let expectedClientInstanceID = await client.operationClientInstanceID
            #expect(receipt.payload.clientInstanceID == expectedClientInstanceID)
        }

        let classic = try await firstRemote.observe(Self.request(engine: .legacy))
        let automatic = try await secondRemote.observe(Self.request(engine: .auto))
        for result in [classic, automatic] {
            #expect(result.capture.metadata.diagnostics?.windowPlanCacheStatus == nil)
            #expect(result.capture.metadata.diagnostics?.windowPlanCacheGeneration == nil)
        }

        #expect(observation.requestedEngines == [.modern, .modern, .legacy, .auto])
        #expect(observation.modernLookups == 2)
        #expect(observation.modernBuilds == 1)
        #expect(observation.modernHits == 1)
        #expect(observation.legacyCalls == 2)
        #expect(observation.ownerReceipts.count == 2)
        await host.stop()
    }

    @Test(arguments: [false, true])
    func `capability flags cannot turn an unsupported stub into a process owner`(trusted: Bool) async throws {
        let socketPath = "/tmp/peekaboo-plan-unsupported-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: StubServices(snapshots: InMemorySnapshotManager()),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            hostCapabilities: [PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership],
            screenCaptureKitProcessCapabilityRegistrar: {
                Issue.record("An unsupported producer must not register process ownership")
            },
            screenCaptureKitOwnershipPreparer: {
                Issue.record("An unsupported producer must not prepare process ownership")
            },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, appleScript: false, postEvent: true)
            })
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [], requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        // Custom sockets without signer trust retain their default receiptless ceiling.
        let client = trusted
            ? TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
            : PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: .init(
            bundleIdentifier: "test.capture-engine.unsupported",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        #expect(handshake.negotiatedVersion == (trusted
                ? PeekabooBridgeConstants.protocolVersion
                : .init(major: 1, minor: 28)))
        #expect((handshake.operationAttestation != nil) == trusted)
        #expect((handshake.operationSessionAttestation != nil) == trusted)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership) != true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.desktopObservationCaptureEngine) != true)
        await host.stop()
    }

    fileprivate static let windowBounds = CGRect(x: 100, y: 200, width: 800, height: 600)

    private static func request(engine: CaptureEnginePreference) -> DesktopObservationRequest {
        DesktopObservationRequest(
            target: .windowID(42),
            capture: DesktopCaptureOptions(engine: engine),
            detection: DesktopDetectionOptions(mode: .none))
    }
}

@MainActor
private final class CountingCaptureEngineObservationService: DesktopObservationServiceProtocol {
    private final class Plan {}

    private var modernPlan: Plan?
    let ownerLease: ScreenCaptureKitOwnerLease
    private(set) var ownerReceipts: [ScreenCaptureKitOwnerLease.OwnerReceipt] = []
    private(set) var requestedEngines: [CaptureEnginePreference] = []
    private(set) var modernLookups = 0
    private(set) var modernBuilds = 0
    private(set) var modernHits = 0
    private(set) var legacyCalls = 0

    init(ownerLease: ScreenCaptureKitOwnerLease) {
        self.ownerLease = ownerLease
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.requestedEngines.append(request.capture.engine)
        let cacheStatus: CaptureWindowPlanCacheStatus?
        let generation: UInt64?
        switch request.capture.engine {
        case .modern:
            try self.ownerReceipts.append(self.ownerLease.claim().receipt)
            self.modernLookups += 1
            if self.modernPlan == nil {
                self.modernPlan = Plan()
                self.modernBuilds += 1
                cacheStatus = .miss
            } else {
                self.modernHits += 1
                cacheStatus = .hit
            }
            generation = 1
        case .legacy, .auto:
            self.legacyCalls += 1
            cacheStatus = nil
            generation = nil
        }

        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 456,
            capturedBounds: RemoteCaptureEnginePlanCacheRoutingTests.windowBounds)
        return DesktopObservationResult(
            target: ResolvedObservationTarget(
                kind: .windowID(42),
                app: ApplicationIdentity(
                    processIdentifier: 123,
                    processStartIdentity: 456,
                    bundleIdentifier: "test.capture-engine.host",
                    name: "Capture Engine Host"),
                window: WindowIdentity(
                    windowID: 42,
                    title: "Fixture",
                    bounds: RemoteCaptureEnginePlanCacheRoutingTests.windowBounds,
                    index: 0),
                bounds: RemoteCaptureEnginePlanCacheRoutingTests.windowBounds,
                detectionContext: WindowContext(
                    applicationName: "Capture Engine Host",
                    applicationBundleId: "test.capture-engine.host",
                    applicationProcessId: 123,
                    windowTitle: "Fixture",
                    windowID: 42,
                    windowBounds: RemoteCaptureEnginePlanCacheRoutingTests.windowBounds,
                    windowMutationIdentity: identity)),
            capture: CaptureResult(
                imageData: StubScreenCaptureService.sampleData,
                metadata: CaptureMetadata(
                    size: RemoteCaptureEnginePlanCacheRoutingTests.windowBounds.size,
                    mode: .window,
                    applicationInfo: ServiceApplicationInfo(
                        processIdentifier: 123,
                        processStartIdentity: 456,
                        bundleIdentifier: "test.capture-engine.host",
                        name: "Capture Engine Host",
                        windowCount: 1),
                    windowInfo: ServiceWindowInfo(
                        windowID: 42,
                        title: "Fixture",
                        bounds: RemoteCaptureEnginePlanCacheRoutingTests.windowBounds,
                        mutationIdentity: identity),
                    diagnostics: CaptureDiagnostics(
                        requestedScale: .logical1x,
                        nativeScale: 1,
                        outputScale: 1,
                        scaleSource: "fixture",
                        finalPixelSize: RemoteCaptureEnginePlanCacheRoutingTests.windowBounds.size,
                        engine: request.capture.engine == .modern ? "ScreenCaptureKit" : "CGWindowList",
                        windowPlanCacheStatus: cacheStatus,
                        windowPlanCacheGeneration: generation))),
            elements: nil,
            files: DesktopObservationFiles())
    }
}

@MainActor
private final class PlanCacheOwnerServices: PeekabooBridgeServiceProviding {
    private let base: StubServices
    private let observation: CountingCaptureEngineObservationService

    init(observation: CountingCaptureEngineObservationService) {
        self.observation = observation
        self.base = StubServices(snapshots: InMemorySnapshotManager(), desktopObservation: observation)
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
        self.observation
    }

    /// This synthetic observation provider implements all engine cases and claims its isolated lease before plan use.
    var supportsDesktopObservationCaptureEngine: Bool {
        true
    }

    var supportsScreenCaptureKitProcessOwnership: Bool {
        true
    }
}
