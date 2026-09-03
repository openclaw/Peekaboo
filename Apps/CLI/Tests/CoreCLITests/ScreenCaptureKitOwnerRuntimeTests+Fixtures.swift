import Darwin
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAutomationKit
@testable import PeekabooCLI

@MainActor
extension ScreenCaptureKitOwnerRuntimeTests {
    static var fixtureSockets: Set<String> = []

    static func fixtureSocketPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString).sock").path
    }

    static func makeInertRemoteServices(
        client: PeekabooBridgeClient,
        handshake: PeekabooBridgeHandshakeResponse,
        options: CommandRuntimeOptions
    ) -> any PeekabooServiceProviding {
        OwnerPolicyFixtureServices(ownerAware: true, remoteClient: client)
    }

    static func inertHandshakeCache() -> RuntimeHostResolver.RemoteHandshakeCache {
        RuntimeHostResolver.RemoteHandshakeCache(
            identity: .init(
                bundleIdentifier: "boo.peekaboo.test.client",
                teamIdentifier: nil,
                processIdentifier: getpid()
            ),
            clientFactory: { path in
                // Only task-owned listeners can be reached, including by legacy candidate scans.
                let isolatedPath = self.fixtureSockets.contains(path) ? path : self.fixtureSocketPath()
                return PeekabooBridgeClient(socketPath: isolatedPath)
            }
        )
    }

    static func inertDependencies(
        makeLocalServices: @escaping RuntimeHostResolver.LocalServiceFactory,
        claimScreenCaptureKitOwner: @escaping RuntimeHostResolver.ScreenCaptureKitOwnerClaim,
        inspectScreenCaptureKitOwner: @escaping RuntimeHostResolver.ScreenCaptureKitOwnerInspector,
        inspectScreenCaptureKitSafety: @escaping RuntimeHostResolver
            .ScreenCaptureKitSafetyInspector = { _, _, _, _ in nil },
        recordScreenCaptureKitSafetyBlocker: @escaping RuntimeHostResolver.ScreenCaptureKitSafetyRecorder = { _ in },
        remoteCandidatePlan: RuntimeHostResolver.RemoteCandidatePlanner? = nil,
        makeRemoteHandshakeCache: RuntimeHostResolver.RemoteHandshakeCacheFactory? = nil
    ) -> RuntimeHostResolver.Dependencies {
        .init(
            makeLocalServices: makeLocalServices,
            claimScreenCaptureKitOwner: claimScreenCaptureKitOwner,
            inspectScreenCaptureKitOwner: inspectScreenCaptureKitOwner,
            inspectScreenCaptureKitSafety: inspectScreenCaptureKitSafety,
            recordScreenCaptureKitSafetyBlocker: recordScreenCaptureKitSafetyBlocker,
            remoteCandidatePlan: remoteCandidatePlan ?? { options, environment in
                let socket = options.bridgeSocketPath ?? environment["PEEKABOO_BRIDGE_SOCKET"]
                let daemon = environment["PEEKABOO_DAEMON_SOCKET"] ?? "/synthetic/daemon.sock"
                return .init(
                    explicitSocket: socket,
                    daemonSocketPath: daemon,
                    runtimeBuildIdentity: "fixture",
                    buildScopedDaemonSocketPath: nil,
                    historicalBuildScopedDaemonSocketPaths: [],
                    candidates: socket.map { [.init(
                        socketPath: $0,
                        requireReusableDaemon: false,
                        requiredHostKind: nil,
                        requiresValidatedHistoricalDaemon: false
                    )] } ??
                        []
                )
            },
            makeRemoteHandshakeCache: makeRemoteHandshakeCache ?? { self.inertHandshakeCache() },
            makeRemoteServices: self.makeInertRemoteServices
        )
    }

    static func startHost(
        socketPath: String,
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        codeSignatureHash: String,
        ownerAware: Bool = true,
        screenRecording: Bool = true,
        maximumProtocolVersion: PeekabooBridgeProtocolVersion =
            PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion,
        usesCurrentHostIdentity: Bool = false,
        serviceOverride: (any PeekabooBridgeServiceProviding)? = nil,
        coordinationRootURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-owner-lane-\(UUID().uuidString)", isDirectory: true),
        windowIdentity: WindowMutationIdentity? = nil,
        screenCaptureKitProcessCapabilityRegistrar: @MainActor @Sendable () throws -> Void = {},
        screenCaptureKitOwnershipPreparer: @escaping @Sendable () async throws -> Void = {},
        permissionEvaluationObserver: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws -> PeekabooBridgeHost {
        let services: any PeekabooBridgeServiceProviding = if let serviceOverride {
            serviceOverride
        } else if ownerAware {
            OwnerPolicyFixtureServices(ownerAware: true)
        } else {
            OwnerPolicyFixtureServices(ownerAware: false)
        }
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: ClosedRange(uncheckedBounds: (
                lower: PeekabooBridgeConstants.supportedProtocolRange.lowerBound,
                upper: maximumProtocolVersion
            )),
            allowedOperations: [
                .permissionsStatus,
                .captureScreen,
                .desktopObservation,
                .invalidateImplicitLatestSnapshot,
                .launchApplicationWithOptions,
                .findApplication,
                .activateApplication,
                .targetedHotkey,
                .targetedTypeActions,
                .targetedClick,
                .ownsSnapshot,
                .targetedDialogListElements,
                .prepareDialogAction,
                .exactDialogClickButton,
                .exactDialogDismiss,
            ],
            hostIdentity: usesCurrentHostIdentity
                ? .current()
                : PeekabooBridgeHostIdentity(
                    processIdentifier: processIdentifier,
                    processStartIdentity: processStartIdentity,
                    bundleIdentifier: "boo.peekaboo.test.host",
                    bundleShortVersion: nil,
                    bundleVersion: nil,
                    codeSignatureHash: codeSignatureHash
                ),
            // Synthetic startup and dispatch must not use user-wide ownership or desktop coordination state.
            desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: coordinationRootURL),
            screenCaptureKitProcessCapabilityRegistrar: screenCaptureKitProcessCapabilityRegistrar,
            screenCaptureKitOwnershipPreparer: screenCaptureKitOwnershipPreparer,
            screenCaptureKitOwnerClaimProvider: {
                Issue.record("Routing fixture must not claim ScreenCaptureKit")
                throw ScreenCaptureKitOwnerLease.LeaseError.invalidOwnerIdentity("unexpected fixture claim")
            },
            postEventAccessEvaluator: { true },
            postEventAccessRequester: { false },
            permissionStatusEvaluator: { _ in
                permissionEvaluationObserver()
                return PermissionsStatus(
                    screenRecording: screenRecording,
                    accessibility: true,
                    appleScript: false,
                    postEvent: true
                )
            },
            windowOwnerProcessIdentifierProvider: { windowID in
                windowIdentity?.windowID == Int(windowID) ? windowIdentity?.ownerProcessIdentifier : nil
            },
            windowBoundsProvider: { windowID in
                windowIdentity?.windowID == Int(windowID) ? windowIdentity?.capturedBounds : nil
            },
            maximizedVisibleWorkAreaProvider: { _ in nil },
            processStartIdentityProvider: { pid in
                windowIdentity?.ownerProcessIdentifier == pid ? windowIdentity?.ownerProcessStartIdentity : nil
            },
            processPresenceProvider: { pid in windowIdentity?.ownerProcessIdentifier == pid }
        )
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2
        )
        try await host.startChecked()
        self.fixtureSockets.insert(socketPath)
        return host
    }
}

@MainActor
final class OwnerPolicyFixtureServices: PeekabooBridgeServiceProviding, PeekabooServiceProviding {
    let automation: any UIAutomationServiceProtocol = MockTargetedAutomationService()
    let applications: any ApplicationServiceProtocol
    let dialogs: any DialogServiceProtocol
    let snapshots: any SnapshotManagerProtocol
    let desktopObservation: any DesktopObservationServiceProtocol
    let supportsDesktopObservationCaptureEngine = true
    let supportsScreenCaptureKitProcessOwnership: Bool
    let supportsClassicCaptureWithoutScreenCaptureKit: Bool
    private let remoteClient: PeekabooBridgeClient?

    init(
        ownerAware: Bool,
        observation: (any DesktopObservationServiceProtocol)? = nil,
        snapshots: any SnapshotManagerProtocol = InMemorySnapshotManager(),
        remoteClient: PeekabooBridgeClient? = nil
    ) {
        self.supportsScreenCaptureKitProcessOwnership = ownerAware
        self.supportsClassicCaptureWithoutScreenCaptureKit = ownerAware
        self.remoteClient = remoteClient
        self.snapshots = snapshots
        if let remoteClient {
            self.desktopObservation = RemoteDesktopObservationService(
                client: remoteClient, supportsDesktopObservationCaptureEngine: true
            )
        } else {
            self.desktopObservation = observation ?? ClassicDispatchSentinelObservationService()
        }
        // Capability reads are inert; an unexpected operation has no ambient endpoint.
        let client = PeekabooBridgeClient(socketPath: FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).sock").path)
        self.screenCapture = RemoteScreenCaptureService(client: client)
        self.browser = RemoteBrowserMCPClient(client: client)
        self.applications = RemoteApplicationService(
            client: client,
            supportsLaunchOptions: true,
            supportsSafeBackgroundLaunchNoOp: true,
            supportsPinnedActivation: true
        )
        self.dialogs = RemoteDialogService(client: client)
    }

    let permissions = PermissionsService(
        dependencies: .init(
            screenRecordingPreflight: { fatalError("No permission probe") },
            screenRecordingRequest: { fatalError("No permission request") },
            screenRecordingEvaluator: ScreenRecordingPermissionChecker(
                preflight: { fatalError("No permission probe") },
                coreGraphicsEvidence: { fatalError("No metadata probe") },
                shareableContentProbe: { fatalError("No ScreenCaptureKit probe") }
            ),
            postEventPreflight: { fatalError("No permission probe") },
            postEventRequest: { fatalError("No permission request") }
        ),
        loggingService: MockLoggingService()
    )
    let screenCapture: any ScreenCaptureServiceProtocol
    let windows: any WindowManagementServiceProtocol = MockWindowService(result: [])
    let menu: any MenuServiceProtocol = MockMenuService(barItems: [])
    let dock: any DockServiceProtocol = MockDockService(items: [])

    var configuration: PeekabooCore.ConfigurationManager {
        fatalError("No ambient configuration")
    }

    var audioInput: AudioInputService {
        fatalError("No provider initialization")
    }

    var logging: any LoggingServiceProtocol {
        fatalError("No shared logging service")
    }

    var files: any FileServiceProtocol {
        fatalError("No file service")
    }

    let clipboard: any ClipboardServiceProtocol = UnusedRoutingClipboard()
    let screens: any ScreenServiceProtocol = EmptyRoutingScreens()
    let browser: any BrowserMCPClientProviding

    var agent: (any AgentServiceProtocol)? {
        nil
    }

    func permissionsStatus() async throws -> PermissionsStatus {
        guard let remoteClient else { fatalError("Inject fixture permission status") }
        return try await remoteClient.permissionsStatus()
    }

    func ensureVisualizerConnection() {}
}

@MainActor
final class ClassicDispatchSentinelObservationService: DesktopObservationServiceProtocol {
    private let expectedTarget: DesktopObservationTargetRequest?

    init(expectedTarget: DesktopObservationTargetRequest? = nil) {
        self.expectedTarget = expectedTarget
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        if let expectedTarget {
            #expect(request.target == expectedTarget)
            #expect(request.capture.engine == .legacy)
        }
        throw OperationError.captureFailed(reason: "classic request reached the remote observation service")
    }
}

@MainActor
private struct EmptyRoutingScreens: ScreenServiceProtocol {
    func listScreens() -> [ScreenInfo] {
        []
    }

    func screenContainingWindow(bounds: CGRect) -> ScreenInfo? {
        nil
    }

    func screen(at index: Int) -> ScreenInfo? {
        nil
    }

    var primaryScreen: ScreenInfo? {
        nil
    }
}

private struct UnusedRoutingClipboard: ClipboardServiceProtocol {
    func get(prefer uti: UTType?) throws -> ClipboardReadResult? {
        throw POSIXError(.ENOTSUP)
    }

    func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        throw POSIXError(.ENOTSUP)
    }

    func clear() {
        fatalError("No clipboard writes")
    }

    func save(slot: String) throws {
        throw POSIXError(.ENOTSUP)
    }

    func restore(slot: String) throws -> ClipboardReadResult {
        throw POSIXError(.ENOTSUP)
    }
}
