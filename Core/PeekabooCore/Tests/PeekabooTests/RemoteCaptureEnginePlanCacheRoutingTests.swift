import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import Testing
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct RemoteCaptureEnginePlanCacheRoutingTests {
    @Test
    func `two clients reuse one owner host plan while classic and auto avoid modern cache`() async throws {
        let socketPath = "/tmp/peekaboo-capture-engine-plan-route-\(UUID().uuidString).sock"
        let observation = CountingCaptureEngineObservationService()
        let fixtureBounds = Self.windowBounds
        let hostIdentity = PeekabooBridgeHostIdentity.current()
        let server = PeekabooBridgeServer(
            services: StubServices(desktopObservation: observation),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            hostIdentity: hostIdentity,
            hostCapabilities: [
                PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
                PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
            ],
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

        let firstClient = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await firstClient.handshake(client: .init(
            bundleIdentifier: "test.capture-engine.first",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        #expect(handshake.hostKind == .onDemand)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.desktopObservationCaptureEngine) == true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership) == true)
        #expect(handshake.hostIdentity == hostIdentity)

        let firstRemote = RemoteDesktopObservationService(
            client: firstClient,
            supportsDesktopObservationCaptureEngine: true)
        let secondClient = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await secondClient.handshake(client: .init(
            bundleIdentifier: "test.capture-engine.second",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        let secondRemote = RemoteDesktopObservationService(
            client: secondClient,
            supportsDesktopObservationCaptureEngine: true)

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

        _ = try await firstRemote.observe(Self.request(engine: .legacy))
        _ = try await secondRemote.observe(Self.request(engine: .auto))

        #expect(observation.requestedEngines == [.modern, .modern, .legacy, .auto])
        #expect(observation.modernLookups == 2)
        #expect(observation.modernBuilds == 1)
        #expect(observation.modernHits == 1)
        #expect(observation.legacyCalls == 2)
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
    private(set) var requestedEngines: [CaptureEnginePreference] = []
    private(set) var modernLookups = 0
    private(set) var modernBuilds = 0
    private(set) var modernHits = 0
    private(set) var legacyCalls = 0

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.requestedEngines.append(request.capture.engine)
        let cacheStatus: CaptureWindowPlanCacheStatus?
        let generation: UInt64?
        switch request.capture.engine {
        case .modern:
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
                    index: 0)),
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
                        engine: request.capture.engine.rawValue,
                        windowPlanCacheStatus: cacheStatus,
                        windowPlanCacheGeneration: generation))),
            elements: nil,
            files: DesktopObservationFiles())
    }
}
