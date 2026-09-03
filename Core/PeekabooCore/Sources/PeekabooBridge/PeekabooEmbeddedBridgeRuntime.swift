import Foundation
import PeekabooAutomationKit

/// Native Peekaboo services suitable for embedding in a signed macOS application.
///
/// This assembly intentionally excludes agent, browser, provider, configuration, audio, and visualizer state. All
/// stateful automation services share one snapshot manager, one durable mutation watermark, and the AutomationKit
/// process-wide desktop lane coordinator.
@MainActor
public final class PeekabooEmbeddedBridgeServices: PeekabooBridgeServiceProviding {
    public static let backgroundFirstInputPolicy = UIInputPolicy(
        defaultStrategy: .actionFirst,
        setValue: .actionOnly,
        performAction: .actionOnly)

    public let permissions: PermissionsService
    public let screenCapture: any ScreenCaptureServiceProtocol
    public let automation: any UIAutomationServiceProtocol
    public let windows: any WindowManagementServiceProtocol
    public let applications: any ApplicationServiceProtocol
    public let menu: any MenuServiceProtocol
    public let dock: any DockServiceProtocol
    public let dialogs: any DialogServiceProtocol
    public let snapshots: any SnapshotManagerProtocol
    public let desktopObservation: any DesktopObservationServiceProtocol
    public let desktopMutationWatermarkStore: DesktopMutationWatermarkStore
    public let inputPolicy: UIInputPolicy

    public var supportsScreenCaptureKitProcessOwnership: Bool {
        true
    }

    public var supportsClassicCaptureWithoutScreenCaptureKit: Bool {
        true
    }

    public init(
        desktopMutationWatermarkStore: DesktopMutationWatermarkStore = DesktopMutationWatermarkStore(),
        snapshotOptions: InMemorySnapshotManager.Options = .init(copyArtifactsOnStore: true),
        inputPolicy: UIInputPolicy = PeekabooEmbeddedBridgeServices.backgroundFirstInputPolicy,
        feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient())
    {
        let logging = LoggingService()
        let permissions = PermissionsService()
        let applications = ApplicationService(
            permissions: permissions,
            feedbackClient: feedbackClient)
        let snapshots = InMemorySnapshotManager(
            options: snapshotOptions,
            desktopMutationWatermarkStore: desktopMutationWatermarkStore)
        let screenCapture = ScreenCaptureService(
            loggingService: logging,
            feedbackClient: feedbackClient)
        let automation = UIAutomationService(
            snapshotManager: snapshots,
            loggingService: logging,
            searchPolicy: .balanced,
            inputPolicy: inputPolicy,
            feedbackClient: feedbackClient)
        let windows = WindowManagementService(
            applicationService: applications,
            feedbackClient: feedbackClient)
        let menu = MenuService(
            applicationService: applications,
            feedbackClient: feedbackClient)
        let dock = DockService(feedbackClient: feedbackClient)
        let dialogs = DialogService(
            applicationService: applications,
            feedbackClient: feedbackClient)
        let screens = ScreenService()

        self.permissions = permissions
        self.screenCapture = screenCapture
        self.automation = automation
        self.windows = windows
        self.applications = applications
        self.menu = menu
        self.dock = dock
        self.dialogs = dialogs
        self.snapshots = snapshots
        self.desktopObservation = DesktopObservationService(
            screenCapture: screenCapture,
            automation: automation,
            applications: applications,
            menu: menu,
            screens: screens,
            snapshotManager: snapshots)
        self.desktopMutationWatermarkStore = desktopMutationWatermarkStore
        self.inputPolicy = inputPolicy
    }

    public func ownsDesktopOperationLane(for operation: PeekabooBridgeOperation) -> Bool {
        operation.nativeServiceOwnsDesktopOperationLane
    }
}

public enum PeekabooEmbeddedBridgeRuntimeError: Error, LocalizedError, Sendable, Equatable {
    case emptyTeamAllowlist
    case emptyBundleAllowlist

    public var errorDescription: String? {
        switch self {
        case .emptyTeamAllowlist:
            "An embedded Bridge host requires at least one explicitly allowlisted Team ID"
        case .emptyBundleAllowlist:
            "An embedded Bridge host requires at least one explicitly allowlisted bundle identifier"
        }
    }
}

public enum PeekabooEmbeddedBridgeRuntimeState: String, Sendable, Equatable {
    case stopped
    case starting
    case ready
    case stopping
}

public struct PeekabooEmbeddedBridgeRuntimeSnapshot: Sendable, Equatable {
    public let state: PeekabooEmbeddedBridgeRuntimeState
    public let socketPath: String
    public let hostCapabilities: Set<String>

    public init(
        state: PeekabooEmbeddedBridgeRuntimeState,
        socketPath: String,
        hostCapabilities: Set<String>)
    {
        self.state = state
        self.socketPath = socketPath
        self.hostCapabilities = hostCapabilities
    }
}

/// Checked lifecycle owner for an embedded native Bridge host.
///
/// Start, stop, and restart intents execute in arrival order. A failed start never publishes a host, and successful
/// stop does not return until any in-flight request has released socket ownership.
public actor PeekabooEmbeddedBridgeRuntime {
    struct LifecycleHooks: Sendable {
        var didEnqueueStart: @Sendable () -> Void = {}
        var didEnqueueStop: @Sendable () -> Void = {}
        var didEnqueueRestart: @Sendable () -> Void = {}
        var willStartHost: @Sendable () async -> Void = {}
        var willStopHost: @Sendable () async -> Void = {}
    }

    public struct Configuration: Sendable {
        public let socketPath: String
        public let allowlistedTeams: Set<String>
        public let allowlistedBundles: Set<String>
        public let allowedOperations: Set<PeekabooBridgeOperation>
        public let hostKind: PeekabooBridgeHostKind
        public let hostCapabilities: Set<String>
        public let maxMessageBytes: Int
        public let requestTimeoutSeconds: TimeInterval
        public let requestDrainTimeoutSeconds: TimeInterval

        let screenCaptureKitProcessCapabilityRegistrar: @Sendable () throws -> Void
        let screenCaptureKitOwnershipPreparer: @Sendable () async throws -> Void

        public init(
            socketPath: String,
            allowlistedTeams: Set<String>,
            allowlistedBundles: Set<String>,
            allowedOperations: Set<PeekabooBridgeOperation> = PeekabooBridgeOperation.embeddedDefaultAllowlist,
            hostKind: PeekabooBridgeHostKind = .helper,
            hostCapabilities: Set<String> = [PeekabooBridgeHostCapability.backgroundBridgeHost],
            maxMessageBytes: Int = 64 * 1024 * 1024,
            requestTimeoutSeconds: TimeInterval = PeekabooBridgeConstants.defaultRequestTimeoutSeconds,
            requestDrainTimeoutSeconds: TimeInterval = 1.0)
        {
            self.init(
                socketPath: socketPath,
                allowlistedTeams: allowlistedTeams,
                allowlistedBundles: allowlistedBundles,
                allowedOperations: allowedOperations,
                hostKind: hostKind,
                hostCapabilities: hostCapabilities,
                maxMessageBytes: maxMessageBytes,
                requestTimeoutSeconds: requestTimeoutSeconds,
                requestDrainTimeoutSeconds: requestDrainTimeoutSeconds,
                screenCaptureKitProcessCapabilityRegistrar: {
                    try ScreenCaptureKitOwnerLease.registerCurrentProcessCapability()
                },
                screenCaptureKitOwnershipPreparer: {
                    try await ScreenCaptureKitOwnerLease.prepareCurrentProcessCapability()
                })
        }

        init(
            socketPath: String,
            allowlistedTeams: Set<String>,
            allowlistedBundles: Set<String>,
            allowedOperations: Set<PeekabooBridgeOperation> = PeekabooBridgeOperation.embeddedDefaultAllowlist,
            hostKind: PeekabooBridgeHostKind = .helper,
            hostCapabilities: Set<String> = [PeekabooBridgeHostCapability.backgroundBridgeHost],
            maxMessageBytes: Int = 64 * 1024 * 1024,
            requestTimeoutSeconds: TimeInterval = PeekabooBridgeConstants.defaultRequestTimeoutSeconds,
            requestDrainTimeoutSeconds: TimeInterval = 1.0,
            screenCaptureKitProcessCapabilityRegistrar: @escaping @Sendable () throws -> Void,
            screenCaptureKitOwnershipPreparer: @escaping @Sendable () async throws -> Void)
        {
            self.socketPath = socketPath
            self.allowlistedTeams = allowlistedTeams
            self.allowlistedBundles = allowlistedBundles
            // Callers may narrow the embedded surface, but this native-only runtime cannot acquire browser,
            // daemon-control, or interactive permission-prompt ownership by configuration accident.
            self.allowedOperations = allowedOperations.intersection(PeekabooBridgeOperation.embeddedDefaultAllowlist)
            self.hostKind = hostKind
            self.hostCapabilities = hostCapabilities
                .subtracting([PeekabooBridgeHostCapability.agentExecutionTrace])
                .union([PeekabooBridgeHostCapability.backgroundBridgeHost])
            self.maxMessageBytes = maxMessageBytes
            self.requestTimeoutSeconds = requestTimeoutSeconds
            self.requestDrainTimeoutSeconds = requestDrainTimeoutSeconds
            self.screenCaptureKitProcessCapabilityRegistrar = screenCaptureKitProcessCapabilityRegistrar
            self.screenCaptureKitOwnershipPreparer = screenCaptureKitOwnershipPreparer
        }

        func validate() throws {
            guard !self.allowlistedTeams.isEmpty else {
                throw PeekabooEmbeddedBridgeRuntimeError.emptyTeamAllowlist
            }
            guard !self.allowlistedBundles.isEmpty else {
                throw PeekabooEmbeddedBridgeRuntimeError.emptyBundleAllowlist
            }
        }
    }

    private struct StartedHost: Sendable {
        let host: PeekabooBridgeHost
        let capabilities: Set<String>
    }

    private let configuration: Configuration
    private let services: PeekabooEmbeddedBridgeServices
    private let lifecycleHooks: LifecycleHooks
    private var state: PeekabooEmbeddedBridgeRuntimeState = .stopped
    private var startedHost: StartedHost?
    private var lifecycleTail: Task<Void, Never>?

    public init(
        configuration: Configuration,
        services: PeekabooEmbeddedBridgeServices)
    {
        self.configuration = configuration
        self.services = services
        self.lifecycleHooks = LifecycleHooks()
    }

    init(
        configuration: Configuration,
        services: PeekabooEmbeddedBridgeServices,
        lifecycleHooks: LifecycleHooks)
    {
        self.configuration = configuration
        self.services = services
        self.lifecycleHooks = lifecycleHooks
    }

    @MainActor
    public static func make(
        configuration: Configuration,
        desktopMutationWatermarkStore: DesktopMutationWatermarkStore = DesktopMutationWatermarkStore(),
        snapshotOptions: InMemorySnapshotManager.Options = .init(copyArtifactsOnStore: true),
        inputPolicy: UIInputPolicy = PeekabooEmbeddedBridgeServices.backgroundFirstInputPolicy,
        feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient()) -> Self
    {
        Self(
            configuration: configuration,
            services: PeekabooEmbeddedBridgeServices(
                desktopMutationWatermarkStore: desktopMutationWatermarkStore,
                snapshotOptions: snapshotOptions,
                inputPolicy: inputPolicy,
                feedbackClient: feedbackClient))
    }

    public func snapshot() -> PeekabooEmbeddedBridgeRuntimeSnapshot {
        PeekabooEmbeddedBridgeRuntimeSnapshot(
            state: self.state,
            socketPath: self.configuration.socketPath,
            hostCapabilities: self.startedHost?.capabilities ?? [])
    }

    @discardableResult
    public func startChecked() async throws -> PeekabooEmbeddedBridgeRuntimeSnapshot {
        let predecessor = self.lifecycleTail
        let operation = Task<PeekabooEmbeddedBridgeRuntimeSnapshot, any Error> { [self] in
            await predecessor?.value
            return try await self.performStart()
        }
        self.lifecycleTail = Task {
            _ = try? await operation.value
        }
        self.lifecycleHooks.didEnqueueStart()
        return try await operation.value
    }

    public func stopChecked() async {
        let predecessor = self.lifecycleTail
        let operation = Task { [self] in
            await predecessor?.value
            await self.performStop()
        }
        self.lifecycleTail = operation
        self.lifecycleHooks.didEnqueueStop()
        await operation.value
    }

    @discardableResult
    public func restartChecked() async throws -> PeekabooEmbeddedBridgeRuntimeSnapshot {
        let predecessor = self.lifecycleTail
        let operation = Task<PeekabooEmbeddedBridgeRuntimeSnapshot, any Error> { [self] in
            await predecessor?.value
            await self.performStop()
            return try await self.performStart()
        }
        self.lifecycleTail = Task {
            _ = try? await operation.value
        }
        self.lifecycleHooks.didEnqueueRestart()
        return try await operation.value
    }

    private func performStart() async throws -> PeekabooEmbeddedBridgeRuntimeSnapshot {
        if let startedHost, self.state == .ready {
            return self.readySnapshot(for: startedHost)
        }
        try self.configuration.validate()
        self.startedHost = nil
        self.state = .starting
        await self.lifecycleHooks.willStartHost()
        do {
            let startedHost = try await Self.makeStartedHost(
                configuration: self.configuration,
                services: self.services)
            self.startedHost = startedHost
            self.state = .ready
            return self.readySnapshot(for: startedHost)
        } catch {
            self.startedHost = nil
            self.state = .stopped
            throw error
        }
    }

    private func performStop() async {
        guard let startedHost else {
            self.state = .stopped
            return
        }
        self.state = .stopping
        await self.lifecycleHooks.willStopHost()
        _ = await startedHost.host.stop()
        await startedHost.host.waitUntilFullyStopped()
        self.startedHost = nil
        self.state = .stopped
    }

    private func readySnapshot(for startedHost: StartedHost) -> PeekabooEmbeddedBridgeRuntimeSnapshot {
        PeekabooEmbeddedBridgeRuntimeSnapshot(
            state: .ready,
            socketPath: self.configuration.socketPath,
            hostCapabilities: startedHost.capabilities)
    }

    private nonisolated static func makeStartedHost(
        configuration: Configuration,
        services: PeekabooEmbeddedBridgeServices) async throws -> StartedHost
    {
        try configuration.screenCaptureKitProcessCapabilityRegistrar()

        let preparedHost = await MainActor.run {
            PeekabooBridgeBootstrap.makeHost(
                services: services,
                configuration: .init(
                    hostKind: configuration.hostKind,
                    socketPath: configuration.socketPath,
                    allowlistedTeams: configuration.allowlistedTeams,
                    allowlistedBundles: configuration.allowlistedBundles,
                    daemonControl: nil,
                    automationActivityObserver: nil,
                    allowedOperations: configuration.allowedOperations,
                    hostIdentity: .current(),
                    hostCapabilities: configuration.hostCapabilities,
                    desktopMutationWatermarkStore: services.desktopMutationWatermarkStore,
                    maxMessageBytes: configuration.maxMessageBytes,
                    requestTimeoutSec: configuration.requestTimeoutSeconds,
                    requestDrainTimeoutSec: configuration.requestDrainTimeoutSeconds,
                    screenCaptureKitOwnershipPreparer: configuration.screenCaptureKitOwnershipPreparer))
        }
        let host = preparedHost.host

        do {
            try await host.startChecked()
            return await StartedHost(
                host: host,
                capabilities: host.advertisedHostCapabilities())
        } catch {
            _ = await host.stop()
            await host.waitUntilFullyStopped()
            throw error
        }
    }
}
