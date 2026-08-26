//
//  CommandRuntime.swift
//  PeekabooCLI
//

import Darwin
import Foundation
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import PeekabooProtocols

/// Shared options that control logging and output behavior.
struct CommandRuntimeOptions {
    var verbose = false
    var jsonOutput = false
    var logLevel: LogLevel?
    var captureEnginePreference: String?
    /// This command carries the capture-engine choice in its remote request instead of
    /// requiring the caller process to own capture/TCC.
    var transportsCaptureEnginePreference = false
    /// AX-only command forms do not run a capture backend; ambient engine configuration must
    /// not alter their runtime host.
    var ignoresCaptureEnginePreference = false
    /// An explicit engine must run on a compatible host or fail; local fallback would silently
    /// change capture/TCC ownership. Explicit `--no-remote` remains the local opt-in.
    var requiresCaptureEnginePreferenceHost = false
    /// Non-auto engine values need an additive host capability so an older host cannot silently
    /// ignore the transported preference and run its default backend.
    var requiresCaptureEnginePreferenceCapability = false
    /// Every transported capture engine requires the current ownership-policy capability.
    /// Auto/modern use the owner lease; classic attests that permission probing stays out of SCK.
    var requiresScreenCaptureKitOwnerCapability = false
    var requiresDesktopObservation = false
    /// `accessibilityAndOCR` is additive inside protocol 1.22. Require a raw host capability so
    /// an older 1.22 host cannot try to decode the enum case before the client can fail safely.
    var requiresDesktopObservationOCR = false
    var inputStrategy: UIInputStrategy?
    var preferRemote = true
    var remoteIsolationRequested = false
    var autoStartDaemon = true
    /// Bridge status must run locally after probing an unavailable explicit socket so it can report the exact
    /// handshake failure. No operation-bearing command may use this diagnostic-only escape hatch.
    var permitsExplicitSocketDiagnosticFallback = false
    var bridgeSocketPath: String?
    var requiresElementActions = false
    var requiresInspectAccessibilityTree = false
    var requiresBrowserMCP = false
    var requiresApplicationLaunchOptions = false
    var requiresSafeBackgroundApplicationLaunchNoOp = false
    var requiresNewApplicationInstanceLaunch = false
    var requiresApplicationWindowReadiness = false
    var requiresApplicationRelaunch = false
    var requiresSurvivingApplicationHost = false
    /// Protocol 1.16 carries a process-generation receipt with application quit requests.
    var requiresProcessGenerationPinnedApplicationQuit = false
    var requiresProcessGenerationPinnedApplicationActivation = false
    var requiresProcessGenerationPinnedApplicationHide = false
    /// Protocol 1.19 carries a process-generation receipt with targeted hotkey requests.
    var requiresProcessGenerationPinnedHotkeys = false
    /// Protocol 1.22 carries a process-generation receipt with targeted typing requests.
    var requiresProcessGenerationPinnedTypeActions = false
    /// Protocol 1.22 carries a process-generation receipt with targeted click requests.
    var requiresProcessGenerationPinnedClicks = false
    /// Current background clicks must carry an explicit AX-value allow/deny policy to the selected host.
    var requiresTargetedClickAccessibilityValueDelivery = false
    var requiresHostApplicationInventory = false
    /// A concrete snapshot reference is host-local state. Runtime selection must authenticate
    /// the live host that owns it instead of replaying the ID against the ordinary preferred host.
    var explicitSnapshotID: String?
    /// Snapshot-producing commands require canonical producer ownership before selecting a host.
    var requiresProducerBoundSnapshotReferences = false
    var requiresImplicitSnapshotInvalidation = false
    /// Protocol 1.26 publishes a receipt that is addressable by ID without replacing implicit latest elements.
    var requiresExplicitSnapshotPublication = false
    var requiresCallerDesktopMutationBarrier = false
    var usesPerToolSnapshotInvalidation = false
    /// MCP and Agent keep one dynamic tool runtime alive across multiple calls. An explicit
    /// Bridge route therefore owns capture preflight for that runtime's authenticated generation.
    var usesPersistentDynamicToolRuntime: Bool {
        self.requiresAgentService && self.usesPerToolSnapshotInvalidation
    }

    var requiresExactWindowTargetedClicks = false
    /// Protocol 1.30 is required before encoding middle/triple click cases.
    var requiresStatelessClickVariants = false
    /// Background middle/triple clicks additionally require exact-window targeted-click support.
    var requiresBackgroundStatelessClickVariants = false
    /// Modifier-click must execute in the host that owns and leases its exact snapshot.
    var requiresForegroundModifierClickSnapshotLease = false
    /// Pixel-focus typing is host-atomic and must not fall back to ordinary targeted typing.
    var requiresExactWindowPixelFocusTyping = false
    var requiresTargetedScroll = false
    var requiresPostEventPermission = false
    var requiresAccessibilityPermission = false
    var requiresLongPressClick = false
    var requiresBackgroundWindowClose = false
    var requiresBackgroundDialogClick = false
    var requiresTargetedDialogList = false
    var requiresPreparedDialogClick = false
    var requiresPreparedDialogDismiss = false
    /// Protocol 1.12 added the silent capture visualizer mode used by background observation.
    /// Older hosts cannot decode that enum value, so commands that can send it must fail preflight.
    var requiresSilentCapture = false
    /// Protocol 1.21 carries exact-window ROI receipts and atomic snapshot publication.
    /// Older hosts could ignore the crop or acknowledge only part of the snapshot.
    var requiresExactWindowROIObservation = false
    var requiresTargetedFocusedElement = false
    var requiresExactWindowTargetedKeyboard = false
    /// Protocol 1.18 pins window mutations to the PID, process generation, CGWindowID, and
    /// capture-time bounds. Commands that mutate a window must reject older hosts before dispatch.
    var requiresPinnedWindowMutations = false
    /// Restore was added as a receipt-pinned Bridge operation in protocol 1.18.
    var requiresWindowRestore = false
    /// Set for commands that acquire screen pixels (capture/detection/desktop observation) so a
    /// remote host that explicitly lacks Screen Recording is rejected during selection. Not set for
    /// interaction commands (click/scroll/type) that operate on cached snapshots.
    var requiresScreenCapturePermission = false
    /// Set for interactive permission-request commands, which must be able to reach a host that
    /// still lacks the permission being requested.
    var requestsHostPermissionGrant = false
    /// Only Agent execution and the long-lived MCP server need provider discovery during
    /// process bootstrap. Other commands construct the native service graph without eagerly
    /// reloading provider credentials or creating an Agent that they cannot call.
    var requiresAgentService = false

    func makeConfiguration() -> CommandRuntime.Configuration {
        CommandRuntime.Configuration(
            verbose: self.verbose,
            jsonOutput: self.jsonOutput,
            logLevel: self.logLevel,
            captureEnginePreference: self.captureEnginePreference,
            inputStrategy: self.inputStrategy
        )
    }

    func applyingEnvironmentOverrides(environment: [String: String]) -> CommandRuntimeOptions {
        var options = self
        if !options.ignoresCaptureEnginePreference,
           options.captureEnginePreference == nil,
           let captureEngine = Self.captureEnginePreference(environment: environment) {
            options.captureEnginePreference = captureEngine
            if options.transportsCaptureEnginePreference {
                options.requiresCaptureEnginePreferenceHost = true
                let preference = ObservationCommandSupport.captureEnginePreference(
                    cliValue: captureEngine,
                    configuredValue: nil
                )
                options.requiresCaptureEnginePreferenceCapability = preference != .auto
                options.requiresScreenCaptureKitOwnerCapability = true
            } else if !options.requiresApplicationLaunchOptions, !options.requiresHostApplicationInventory {
                options.preferRemote = false
            }
        }
        return options
    }

    static func captureEnginePreference(environment: [String: String]) -> String? {
        guard let value = environment["PEEKABOO_CAPTURE_ENGINE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }
}

/// Runtime context passed to runtime-aware commands.
struct CommandRuntime {
    static let defaultDaemonIdleTimeoutSeconds: TimeInterval = 300

    @TaskLocal
    private static var serviceOverride: (any PeekabooServiceProviding)?

    struct Configuration {
        var verbose: Bool
        var jsonOutput: Bool
        var logLevel: LogLevel?
        var captureEnginePreference: String?
        var inputStrategy: UIInputStrategy?
    }

    let configuration: Configuration
    let hostDescription: String
    let selectedRemoteSocketPath: String?
    let selectedRemoteHostProcessIdentifier: pid_t?
    let captureEngineSafetyOverride: CaptureEnginePreference?
    let toolCapturePreflightRefusal: MCPToolCapturePreflightRefusal?
    let snapshotInvalidationRemoteSocketPaths: [String]
    let applicationRelaunchAllowed: Bool
    let requiredHostFailure: String?
    let interactionMutationTracker: InteractionMutationTracker
    @MainActor let services: any PeekabooServiceProviding
    @MainActor let logger: Logger

    @MainActor
    var observationTimeoutMutationTracker: InteractionMutationTracker? {
        if self.selectedRemoteSocketPath == nil || self.interactionMutationTracker.hasPendingDurableMutation {
            return self.interactionMutationTracker
        }
        return nil
    }

    @MainActor
    init(
        configuration: Configuration,
        services: any PeekabooServiceProviding,
        hostDescription: String = "local (in-process)",
        selectedRemoteSocketPath: String? = nil,
        selectedRemoteHostProcessIdentifier: pid_t? = nil,
        captureEngineSafetyOverride: CaptureEnginePreference? = nil,
        toolCapturePreflightRefusal: MCPToolCapturePreflightRefusal? = nil,
        snapshotInvalidationRemoteSocketPaths: [String] = [],
        applicationRelaunchAllowed: Bool = true,
        requiredHostFailure: String? = nil,
        interactionMutationTracker: InteractionMutationTracker = InteractionMutationTracker()
    ) {
        // Keep Tachikoma credential/profile resolution aligned with Peekaboo CLI storage.
        PeekabooCore.ConfigurationManager.configureTachikomaProfileDirectory()

        self.configuration = configuration
        self.services = services
        self.hostDescription = hostDescription
        self.selectedRemoteSocketPath = selectedRemoteSocketPath
        self.selectedRemoteHostProcessIdentifier = selectedRemoteHostProcessIdentifier
        self.captureEngineSafetyOverride = captureEngineSafetyOverride
        self.toolCapturePreflightRefusal = toolCapturePreflightRefusal
        self.snapshotInvalidationRemoteSocketPaths = snapshotInvalidationRemoteSocketPaths
        self.applicationRelaunchAllowed = applicationRelaunchAllowed
        self.requiredHostFailure = requiredHostFailure
        self.interactionMutationTracker = interactionMutationTracker
        self.logger = Logger.shared

        if let agent = services.agent as? PeekabooAgentService {
            agent.configureCapturePreflightRefusal(toolCapturePreflightRefusal)
        }
        services.installAgentRuntimeDefaults()

        self.logger.setJsonOutputMode(configuration.jsonOutput)
        let explicitLevel = configuration.logLevel
        var shouldEnableVerbose = configuration.verbose
        if configuration.jsonOutput, explicitLevel == nil {
            shouldEnableVerbose = true
        }
        if let explicitLevel, explicitLevel <= .verbose {
            shouldEnableVerbose = true
        }

        self.logger.setVerboseMode(shouldEnableVerbose)

        if let explicitLevel {
            self.logger.setMinimumLogLevel(explicitLevel)
        } else if shouldEnableVerbose {
            self.logger.setMinimumLogLevel(.verbose)
        } else {
            self.logger.resetMinimumLogLevel()
        }

        let visualizerConsoleLevel: PeekabooProtocols.LogLevel? = if let explicitLevel {
            explicitLevel.coreLogLevel
        } else if shouldEnableVerbose {
            .debug
        } else {
            nil
        }

        VisualizationClient.shared.setConsoleLogLevelOverride(visualizerConsoleLevel)
        VisualizationClient.shared.setConsoleMirroringEnabled(configuration.verbose)

        self.services.ensureVisualizerConnection()

        self.logger.debug("Runtime host: \(hostDescription)")
    }

    @MainActor
    init(options: CommandRuntimeOptions, services: any PeekabooServiceProviding) {
        self.init(configuration: options.makeConfiguration(), services: services)
    }
}

extension CommandRuntime {
    @MainActor
    static func makeDefault(options: CommandRuntimeOptions) -> CommandRuntime {
        let effectiveOptions = options.applyingEnvironmentOverrides(environment: ProcessInfo.processInfo.environment)
        let services = self.serviceOverride ?? self.makeLocalServices(options: effectiveOptions)
        return CommandRuntime(configuration: effectiveOptions.makeConfiguration(), services: services)
    }

    @MainActor
    static func makeDefault() -> CommandRuntime {
        self.makeDefault(options: CommandRuntimeOptions())
    }

    @MainActor
    static func makeDefaultAsync(options: CommandRuntimeOptions) async throws -> CommandRuntime {
        let effectiveOptions = options.applyingEnvironmentOverrides(environment: ProcessInfo.processInfo.environment)
        try ObservationCommandSupport.validateCaptureEngineValue(effectiveOptions.captureEnginePreference)
        if let override = serviceOverride {
            return CommandRuntime(options: effectiveOptions, services: override)
        }

        let resolution = try await resolveServices(options: effectiveOptions)
        return CommandRuntime(
            configuration: effectiveOptions.makeConfiguration(),
            services: resolution.services,
            hostDescription: resolution.hostDescription,
            selectedRemoteSocketPath: resolution.selectedRemoteSocketPath,
            selectedRemoteHostProcessIdentifier: resolution.selectedRemoteHostProcessIdentifier,
            captureEngineSafetyOverride: resolution.captureEngineSafetyOverride,
            toolCapturePreflightRefusal: resolution.toolCapturePreflightRefusal,
            snapshotInvalidationRemoteSocketPaths: resolution.snapshotInvalidationRemoteSocketPaths,
            applicationRelaunchAllowed: resolution.applicationRelaunchAllowed,
            requiredHostFailure: resolution.requiredHostFailure
        )
    }

    @MainActor
    static func makeDefaultAsync() async throws -> CommandRuntime {
        try await self.makeDefaultAsync(options: CommandRuntimeOptions())
    }

    @MainActor
    static func withInjectedServices<T>(
        _ services: any PeekabooServiceProviding,
        perform operation: () async throws -> T
    ) async rethrows -> T {
        try await self.$serviceOverride.withValue(services) {
            try await operation()
        }
    }

    @MainActor
    private static func resolveServices(options: CommandRuntimeOptions) async throws -> RuntimeHostResolver.Resolution {
        try await RuntimeHostResolver.resolveServices(options: options)
    }

    static func explicitBridgeSocket(
        options: CommandRuntimeOptions,
        environment: [String: String]
    ) -> String? {
        BridgeSocketResolver.explicitBridgeSocket(options: options, environment: environment)
    }

    static func shouldAutoStartDaemon(
        options: CommandRuntimeOptions,
        environment: [String: String]
    ) -> Bool {
        DaemonLaunchPolicy.shouldAutoStartDaemon(options: options, environment: environment)
    }

    static func daemonSocketPath(environment: [String: String]) -> String {
        DaemonLaunchPolicy.daemonSocketPath(environment: environment)
    }

    static func daemonIdleTimeoutSeconds(environment: [String: String]) -> TimeInterval {
        DaemonLaunchPolicy.daemonIdleTimeoutSeconds(environment: environment)
    }

    static func onDemandDaemonArguments(socketPath: String, idleTimeoutSeconds: TimeInterval) -> [String] {
        DaemonLaunchPolicy.onDemandDaemonArguments(socketPath: socketPath, idleTimeoutSeconds: idleTimeoutSeconds)
    }

    @MainActor
    private static func makeLocalServices(options: CommandRuntimeOptions) -> PeekabooServices {
        RuntimeServiceFactory.makeLocalServices(options: options)
    }

    static func hasInputStrategyEnvironmentOverride(environment: [String: String]) -> Bool {
        RuntimeInputPolicyResolver.hasEnvironmentOverride(environment: environment)
    }

    static func hasInputStrategyConfigOverride(input: PeekabooAutomation.Configuration.InputConfig?) -> Bool {
        RuntimeInputPolicyResolver.hasConfigOverride(input: input)
    }

    static func supportsRemoteRequirements(
        for handshake: PeekabooBridgeHandshakeResponse,
        options: CommandRuntimeOptions
    ) -> Bool {
        BridgeCapabilityPolicy.supportsRemoteRequirements(for: handshake, options: options)
    }

    static func supportsTargetedHotkeys(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsTargetedHotkeys(for: handshake)
    }

    static func supportsTargetedTypeActions(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsTargetedTypeActions(for: handshake)
    }

    static func supportsTargetedClicks(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsTargetedClicks(for: handshake)
    }

    static func supportsStatelessClickVariants(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsStatelessClickVariants(for: handshake)
    }

    static func supportsApplicationLaunchOptions(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsApplicationLaunchOptions(for: handshake)
    }

    static func supportsApplicationRelaunch(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsApplicationRelaunch(for: handshake)
    }

    static func supportsImplicitSnapshotInvalidation(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsImplicitSnapshotInvalidation(for: handshake)
    }

    static func supportsSnapshotMutationLeases(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsSnapshotMutationLeases(for: handshake)
    }

    static func supportsElementActions(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsElementActions(for: handshake)
    }

    static func supportsDesktopObservation(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsDesktopObservation(for: handshake)
    }

    static func supportsDesktopObservationOCR(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsDesktopObservationOCR(for: handshake)
    }

    static func supportsDesktopObservationCaptureEngine(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> Bool {
        BridgeCapabilityPolicy.supportsDesktopObservationCaptureEngine(for: handshake)
    }

    static func supportsExactWindowROIObservation(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsExactWindowROIObservation(for: handshake)
    }

    static func supportsInspectAccessibilityTree(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsInspectAccessibilityTree(for: handshake)
    }

    static func supportsBrowserMCP(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsBrowserMCP(for: handshake)
    }

    static func supportsPostEventPermissionRequest(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsPostEventPermissionRequest(for: handshake)
    }

    static func targetedHotkeyAvailability(for handshake: PeekabooBridgeHandshakeResponse)
    -> (isEnabled: Bool, unavailableReason: String?, missingPermissions: Set<PeekabooBridgePermissionKind>) {
        BridgeCapabilityPolicy.targetedHotkeyAvailability(for: handshake)
    }

    static func targetedTypeAvailability(for handshake: PeekabooBridgeHandshakeResponse)
    -> (isEnabled: Bool, unavailableReason: String?, missingPermissions: Set<PeekabooBridgePermissionKind>) {
        BridgeCapabilityPolicy.targetedTypeAvailability(for: handshake)
    }

    static func targetedClickAvailability(for handshake: PeekabooBridgeHandshakeResponse)
    -> (isEnabled: Bool, unavailableReason: String?, missingPermissions: Set<PeekabooBridgePermissionKind>) {
        BridgeCapabilityPolicy.targetedClickAvailability(for: handshake)
    }
}

/// Commands that need access to verbose/json flags even before a runtime is injected
/// (e.g., during unit tests) can conform to this protocol and store the parsed options.
protocol RuntimeOptionsConfigurable {
    var runtimeOptions: CommandRuntimeOptions { get set }
}

extension RuntimeOptionsConfigurable {
    mutating func setRuntimeOptions(_ options: CommandRuntimeOptions) {
        runtimeOptions = options
    }
}

@propertyWrapper
struct RuntimeStorage<Value: ExpressibleByNilLiteral> {
    private var storage: Value

    init() {
        self.storage = nil
    }

    var wrappedValue: Value {
        get { self.storage }
        set { self.storage = newValue }
    }
}

extension RuntimeStorage: Codable where Value: ExpressibleByNilLiteral {
    init(from _: any Decoder) throws {
        self.storage = nil
    }

    func encode(to _: any Encoder) throws {}
}

extension RuntimeStorage: Sendable where Value: Sendable {}

extension LogLevel {
    fileprivate var coreLogLevel: PeekabooProtocols.LogLevel {
        switch self {
        case .trace: .trace
        case .verbose: .debug
        case .debug: .debug
        case .info: .info
        case .warning: .warning
        case .error: .error
        case .critical: .critical
        }
    }
}
