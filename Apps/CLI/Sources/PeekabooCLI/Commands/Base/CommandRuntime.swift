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
    var inputStrategy: UIInputStrategy?
    var preferRemote = true
    var remoteIsolationRequested = false
    var autoStartDaemon = true
    var bridgeSocketPath: String?
    var requiresElementActions = false
    var requiresInspectAccessibilityTree = false
    var requiresBrowserMCP = false
    var requiresApplicationLaunchOptions = false
    var requiresApplicationRelaunch = false
    var requiresSurvivingApplicationHost = false
    var requiresHostApplicationInventory = false
    var requiresImplicitSnapshotInvalidation = false
    var requiresCallerDesktopMutationBarrier = false
    var usesPerToolSnapshotInvalidation = false
    var requiresExactWindowTargetedClicks = false
    var requiresPostEventClickPermission = false
    /// Set for commands that acquire screen pixels (capture/detection/desktop observation) so a
    /// remote host that explicitly lacks Screen Recording is rejected during selection. Not set for
    /// interaction commands (click/scroll/type) that operate on cached snapshots.
    var requiresScreenCapturePermission = false
    /// Set for interactive permission-request commands, which must be able to reach a host that
    /// still lacks the permission being requested.
    var requestsHostPermissionGrant = false

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
        if options.captureEnginePreference == nil,
           let captureEngine = Self.captureEnginePreference(environment: environment) {
            options.captureEnginePreference = captureEngine
            if !options.requiresApplicationLaunchOptions && !options.requiresHostApplicationInventory {
                options.preferRemote = false
            }
        }
        return options
    }

    static func captureEnginePreference(environment: [String: String]) -> String? {
        guard let value = environment["PEEKABOO_CAPTURE_ENGINE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// Runtime context passed to runtime-aware commands.
struct CommandRuntime {
    static let defaultDaemonIdleTimeoutSeconds: TimeInterval = 300

    @TaskLocal
    private static var serviceOverride: PeekabooServices?

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
    let snapshotInvalidationRemoteSocketPaths: [String]
    let applicationRelaunchAllowed: Bool
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
        snapshotInvalidationRemoteSocketPaths: [String] = [],
        applicationRelaunchAllowed: Bool = true,
        interactionMutationTracker: InteractionMutationTracker = InteractionMutationTracker()
    ) {
        // Keep Tachikoma credential/profile resolution aligned with Peekaboo CLI storage.
        PeekabooCore.ConfigurationManager.configureTachikomaProfileDirectory()

        self.configuration = configuration
        self.services = services
        self.hostDescription = hostDescription
        self.selectedRemoteSocketPath = selectedRemoteSocketPath
        self.selectedRemoteHostProcessIdentifier = selectedRemoteHostProcessIdentifier
        self.snapshotInvalidationRemoteSocketPaths = snapshotInvalidationRemoteSocketPaths
        self.applicationRelaunchAllowed = applicationRelaunchAllowed
        self.interactionMutationTracker = interactionMutationTracker
        self.logger = Logger.shared

        services.installAgentRuntimeDefaults()

        self.logger.setJsonOutputMode(configuration.jsonOutput)
        let explicitLevel = configuration.logLevel
        var shouldEnableVerbose = configuration.verbose
        if configuration.jsonOutput && explicitLevel == nil {
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
    static func makeDefaultAsync(options: CommandRuntimeOptions) async -> CommandRuntime {
        let effectiveOptions = options.applyingEnvironmentOverrides(environment: ProcessInfo.processInfo.environment)
        if let override = serviceOverride {
            return CommandRuntime(options: effectiveOptions, services: override)
        }

        let resolution = await resolveServices(options: effectiveOptions)
        return CommandRuntime(
            configuration: effectiveOptions.makeConfiguration(),
            services: resolution.services,
            hostDescription: resolution.hostDescription,
            selectedRemoteSocketPath: resolution.selectedRemoteSocketPath,
            selectedRemoteHostProcessIdentifier: resolution.selectedRemoteHostProcessIdentifier,
            snapshotInvalidationRemoteSocketPaths: resolution.snapshotInvalidationRemoteSocketPaths,
            applicationRelaunchAllowed: resolution.applicationRelaunchAllowed
        )
    }

    @MainActor
    static func makeDefaultAsync() async -> CommandRuntime {
        await self.makeDefaultAsync(options: CommandRuntimeOptions())
    }

    @MainActor
    static func withInjectedServices<T>(
        _ services: PeekabooServices,
        perform operation: () async throws -> T
    ) async rethrows -> T {
        try await self.$serviceOverride.withValue(services) {
            try await operation()
        }
    }

    @MainActor
    private static func resolveServices(options: CommandRuntimeOptions) async -> RuntimeHostResolver.Resolution {
        await RuntimeHostResolver.resolveServices(options: options)
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

    static func supportsApplicationLaunchOptions(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsApplicationLaunchOptions(for: handshake)
    }

    static func supportsApplicationRelaunch(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsApplicationRelaunch(for: handshake)
    }

    static func supportsImplicitSnapshotInvalidation(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsImplicitSnapshotInvalidation(for: handshake)
    }

    static func supportsElementActions(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsElementActions(for: handshake)
    }

    static func supportsDesktopObservation(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        BridgeCapabilityPolicy.supportsDesktopObservation(for: handshake)
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
