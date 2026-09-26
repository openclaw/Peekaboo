import Commander
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct DesktopObservationCaptureEngineRuntimeCapabilityTests {
    private static let operations: [PeekabooBridgeOperation] = [
        .captureScreen,
        .desktopObservation,
    ]
    private static let inlineOperations = Self.operations + [.invalidateImplicitLatestSnapshot]
    private static let inlineCapabilities = [
        PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
        PeekabooBridgeHostCapability.desktopObservationInlinePixels,
        PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
    ]

    @Test(arguments: ["live", "action"], ["omitted", "cli-classic", "environment-classic"])
    func `older hosts neither redirect implicit classic capture nor force unselected capture local`(
        command: String,
        selector: String
    ) async throws {
        let environment = selector == "environment-classic" ? ["PEEKABOO_CAPTURE_ENGINE": "cg"] : [:]
        let arguments = selector == "cli-classic" ? ["captureEngine": ["cg"]] : [:]
        var options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: arguments, flags: []),
            commandType: command == "live" ? CaptureLiveCommand.self : CaptureActionCommand.self,
            environment: environment
        ).applyingEnvironmentOverrides(environment: environment)
        options.autoStartDaemon = false
        let socket = "/synthetic/older-capture-host.sock"
        let legacy = Self.handshake(
            operations: [.captureScreen, .invalidateImplicitLatestSnapshot],
            capabilities: nil
        )
        var localFactories = 0
        var remoteFactories = 0
        var ownerClaims = 0
        var handshakes = 0
        let cache = RuntimeHostResolver.RemoteHandshakeCache(
            identity: .init(bundleIdentifier: "synthetic.client", teamIdentifier: nil, processIdentifier: 123),
            handshakeProvider: { _, _ in
                handshakes += 1
                return legacy
            }
        )
        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: environment,
            configurationInput: nil,
            dependencies: .init(
                makeLocalServices: { _ in
                    localFactories += 1
                    return OwnerPolicyFixtureServices(ownerAware: true)
                },
                claimScreenCaptureKitOwner: {
                    ownerClaims += 1
                    return ScreenCaptureKitOwnerRuntimeTests.ownerReceipt()
                },
                inspectScreenCaptureKitOwner: { nil },
                remoteCandidatePlan: { _, _ in
                    .init(
                        explicitSocket: nil,
                        daemonSocketPath: socket,
                        runtimeBuildIdentity: "fixture",
                        buildScopedDaemonSocketPath: nil,
                        historicalBuildScopedDaemonSocketPaths: [],
                        candidates: [.init(
                            socketPath: socket,
                            requireReusableDaemon: false,
                            requiredHostKind: nil,
                            requiresValidatedHistoricalDaemon: false
                        )]
                    )
                },
                makeRemoteHandshakeCache: { cache },
                makeRemoteServices: { client, _, _ in
                    remoteFactories += 1
                    return OwnerPolicyFixtureServices(ownerAware: true, remoteClient: client)
                }
            )
        )

        let capturesRemotely = selector == "omitted"
        #expect(resolution.selectedRemoteSocketPath == (capturesRemotely ? socket : nil))
        #expect(localFactories == (capturesRemotely ? 0 : 1))
        #expect(remoteFactories == (capturesRemotely ? 1 : 0))
        #expect(handshakes == (capturesRemotely ? 1 : 0))
        #expect(ownerClaims == 0)
        #expect(!options.remoteIsolationRequested)
        #expect(!options.requiresDesktopObservationInlinePixels)
        if command == "action" {
            #expect(resolution.snapshotInvalidationRemoteSocketPaths.contains(socket))
        }
    }

    @Test(arguments: ["live", "action"], ["", " \n "])
    func `empty engine choices retain the legacy capture capability contract`(
        command: String,
        empty: String
    ) throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: ["captureEngine": [empty]], flags: []),
            commandType: command == "live" ? CaptureLiveCommand.self : CaptureActionCommand.self,
            environment: ["PEEKABOO_CAPTURE_ENGINE": empty]
        ).applyingEnvironmentOverrides(environment: ["PEEKABOO_CAPTURE_ENGINE": empty])
        let legacy = Self.handshake(
            operations: [.captureScreen, .invalidateImplicitLatestSnapshot],
            capabilities: nil
        )

        #expect(options.captureEnginePreference == nil)
        #expect(!options.requiresDesktopObservation)
        #expect(!options.requiresDesktopObservationInlinePixels)
        #expect(!options.transportsCaptureEnginePreference)
        #expect(options.preferRemote)
        #expect(!RuntimeHostResolver.requiresCallerLocalModernOwnerClaim(options: options, environment: [:]))
        #expect(CommandRuntime.supportsRemoteRequirements(for: legacy, options: options))
    }

    @Test(arguments: ["live", "action"], ["auto", "modern", "cg"])
    func `selected live engines require inline pixels in addition to engine and ownership capabilities`(
        command: String,
        engine: String
    ) throws {
        let options = try Self.options(
            engine: engine,
            commandType: command == "live" ? CaptureLiveCommand.self : CaptureActionCommand.self
        )
        let capable = Self.handshake(operations: Self.inlineOperations, capabilities: Self.inlineCapabilities)
        let noInline = Self.handshake(
            operations: Self.inlineOperations,
            capabilities: Self.inlineCapabilities
                .filter { $0 != PeekabooBridgeHostCapability.desktopObservationInlinePixels }
        )
        let noEngine = Self.handshake(
            operations: Self.inlineOperations,
            capabilities: Self.inlineCapabilities
                .filter { $0 != PeekabooBridgeHostCapability.desktopObservationCaptureEngine }
        )
        let noOwnership = Self.handshake(
            operations: Self.inlineOperations,
            capabilities: Self.inlineCapabilities
                .filter { $0 != PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership }
        )
        let legacy = Self.handshake(operations: Self.inlineOperations, capabilities: nil)

        #expect(options.requiresDesktopObservation)
        #expect(options.requiresDesktopObservationInlinePixels)
        #expect(options.requiresCaptureEnginePreferenceCapability == (engine != "auto"))
        #expect(CommandRuntime.supportsRemoteRequirements(for: capable, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: noInline, options: options))
        #expect(CommandRuntime.supportsRemoteRequirements(for: noEngine, options: options) == (engine == "auto"))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: noOwnership, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: options))
        #expect(BridgeCapabilityPolicy.observationCapabilities(
            for: capable,
            options: options
        ).desktopObservationInlinePixels)
        #expect(!BridgeCapabilityPolicy.observationCapabilities(
            for: noInline,
            options: options
        ).desktopObservationInlinePixels)
    }

    @Test(arguments: ["live", "action"])
    func `inline capability cannot replace a missing or disabled observation operation`(command: String) throws {
        let options = try Self.options(
            engine: "modern",
            commandType: command == "live" ? CaptureLiveCommand.self : CaptureActionCommand.self
        )
        let withoutObservation = Self.inlineOperations.filter { $0 != .desktopObservation }
        let missing = Self.handshake(operations: withoutObservation, capabilities: Self.inlineCapabilities)
        let disabled = Self.handshake(
            operations: Self.inlineOperations,
            enabledOperations: withoutObservation,
            capabilities: Self.inlineCapabilities
        )

        for handshake in [missing, disabled] {
            #expect(!BridgeCapabilityPolicy.observationCapabilities(
                for: handshake,
                options: options
            ).desktopObservationInlinePixels)
            #expect(!CommandRuntime.supportsRemoteRequirements(for: handshake, options: options))
        }
    }

    @Test(arguments: ["live", "action"])
    func `inline capture uses observation when legacy capture is disabled`(command: String) throws {
        let options = try Self.options(
            engine: "modern",
            commandType: command == "live" ? CaptureLiveCommand.self : CaptureActionCommand.self
        )
        let handshake = Self.handshake(
            operations: Self.inlineOperations,
            enabledOperations: [.desktopObservation, .invalidateImplicitLatestSnapshot],
            capabilities: Self.inlineCapabilities
        )

        #expect(CommandRuntime.supportsRemoteRequirements(for: handshake, options: options))
    }

    @Test(arguments: ["live", "action"])
    func `classic permission deferral retains inline capability gating`(command: String) throws {
        let options = try Self.options(
            engine: "classic",
            commandType: command == "live" ? CaptureLiveCommand.self : CaptureActionCommand.self
        )
        let permissions = PermissionsStatus(
            screenRecording: false,
            accessibility: true,
            appleScript: false,
            postEvent: true
        )
        let capable = Self.handshake(
            operations: Self.inlineOperations,
            enabledOperations: [.invalidateImplicitLatestSnapshot],
            capabilities: Self.inlineCapabilities,
            permissions: permissions
        )
        let noInline = Self.handshake(
            operations: Self.inlineOperations,
            enabledOperations: [.invalidateImplicitLatestSnapshot],
            capabilities: Self.inlineCapabilities
                .filter { $0 != PeekabooBridgeHostCapability.desktopObservationInlinePixels },
            permissions: permissions
        )

        #expect(CommandRuntime.supportsRemoteRequirements(for: capable, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: noInline, options: options))
    }

    @Test
    func `non auto engine selection requires the additive host capability`() {
        let capable = Self.handshake(
            capabilities: [
                PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
                PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
            ]
        )
        let legacy = Self.handshake(capabilities: nil)
        let empty = Self.handshake(capabilities: [])
        let missingOperation = Self.handshake(
            operations: [.captureScreen],
            capabilities: [
                PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
                PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
            ]
        )
        let disabled = Self.handshake(
            enabledOperations: [.captureScreen],
            capabilities: [
                PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
                PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
            ]
        )

        #expect(CommandRuntime.supportsDesktopObservationCaptureEngine(for: capable))
        #expect(!CommandRuntime.supportsDesktopObservationCaptureEngine(for: legacy))
        #expect(!CommandRuntime.supportsDesktopObservationCaptureEngine(for: empty))
        #expect(!CommandRuntime.supportsDesktopObservationCaptureEngine(for: missingOperation))
        #expect(!CommandRuntime.supportsDesktopObservationCaptureEngine(for: disabled))
        #expect(BridgeCapabilityPolicy.supportsScreenCaptureKitProcessOwnership(for: capable))
        #expect(!BridgeCapabilityPolicy.supportsScreenCaptureKitProcessOwnership(for: legacy))
    }

    @Test(arguments: ["modern", "sckit"])
    func `explicit non auto engine requires a capable remote host`(engine: String) throws {
        let options = try Self.options(engine: engine)
        let capable = Self.handshake(
            capabilities: [
                PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
                PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
            ]
        )
        let engineOnly = Self.handshake(
            capabilities: [PeekabooBridgeHostCapability.desktopObservationCaptureEngine]
        )
        let legacy = Self.handshake(capabilities: nil)

        #expect(options.requiresCaptureEnginePreferenceHost)
        #expect(!options.requiresDesktopObservationInlinePixels)
        #expect(options.requiresCaptureEnginePreferenceCapability)
        #expect(options.requiresScreenCaptureKitOwnerCapability)
        #expect(CommandRuntime.supportsRemoteRequirements(for: capable, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: engineOnly, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: options))
    }

    @Test(arguments: ["classic", "cg"])
    func `explicit classic requires current ownership policy and engine transport`(engine: String) throws {
        let options = try Self.options(engine: engine)
        let capable = Self.handshake(
            capabilities: [
                PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
                PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
            ]
        )
        let engineOnly = Self.handshake(
            capabilities: [PeekabooBridgeHostCapability.desktopObservationCaptureEngine]
        )

        #expect(options.requiresCaptureEnginePreferenceCapability)
        #expect(options.requiresScreenCaptureKitOwnerCapability)
        #expect(CommandRuntime.supportsRemoteRequirements(for: capable, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: engineOnly, options: options))
    }

    @Test
    func `owner aware classic defers handshake status to host native evidence`() throws {
        let options = try Self.options(engine: "classic")
        let handshake = Self.handshake(
            enabledOperations: [],
            capabilities: [
                PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
                PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
            ],
            permissions: PermissionsStatus(
                screenRecording: false,
                accessibility: true,
                appleScript: false,
                postEvent: true
            )
        )

        #expect(BridgeCapabilityPolicy.explicitlyMissingRemotePermissions(
            for: handshake,
            options: options
        ).isEmpty)
        #expect(CommandRuntime.supportsRemoteRequirements(for: handshake, options: options))
    }

    @Test
    func `classic deferral preserves OCR and ROI capability checks`() throws {
        var options = try Self.options(engine: "classic")
        options.requiresDesktopObservationOCR = true
        options.requiresExactWindowROIObservation = true
        let handshake = Self.handshake(
            operations: [.captureScreen, .desktopObservation, .storeObservationSnapshot],
            enabledOperations: [.storeObservationSnapshot],
            capabilities: [
                PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
                PeekabooBridgeHostCapability.desktopObservationOCR,
                PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
            ],
            permissions: PermissionsStatus(
                screenRecording: false,
                accessibility: true,
                appleScript: false,
                postEvent: true
            )
        )

        #expect(CommandRuntime.supportsRemoteRequirements(for: handshake, options: options))
    }

    @Test
    func `auto requires owner aware host and no remote remains caller local`() throws {
        let auto = try Self.options(engine: "auto")
        let localModern = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["captureEngine": ["modern"]],
                flags: ["no-remote"]
            ),
            commandType: SeeCommand.self
        )
        let ownerAware = Self.handshake(
            capabilities: [PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership]
        )
        let legacy = Self.handshake(capabilities: nil)

        #expect(auto.requiresCaptureEnginePreferenceHost)
        #expect(!auto.requiresDesktopObservationInlinePixels)
        #expect(!auto.requiresCaptureEnginePreferenceCapability)
        #expect(auto.requiresScreenCaptureKitOwnerCapability)
        #expect(CommandRuntime.supportsRemoteRequirements(for: ownerAware, options: auto))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: auto))
        #expect(localModern.requiresCaptureEnginePreferenceCapability)
        #expect(localModern.requiresScreenCaptureKitOwnerCapability)
        #expect(localModern.remoteIsolationRequested)
        #expect(!RuntimeHostResolver.shouldResolveKnownRemoteEndpoints(
            options: localModern,
            environment: [:],
            configurationInput: nil
        ))
    }

    @Test
    func `transported engine preferences never become daemon lifetime environment`() throws {
        let modern = try Self.options(engine: "modern")
        var localOnly = CommandRuntimeOptions()
        localOnly.captureEnginePreference = "modern"
        localOnly.transportsCaptureEnginePreference = false

        #expect(!CommanderRuntimeExecutor.shouldExportCaptureEnginePreference(modern))
        #expect(CommanderRuntimeExecutor.shouldExportCaptureEnginePreference(localOnly))

        let launchEnvironment = DaemonLaunchPolicy.onDemandDaemonEnvironment([
            "PATH": "/usr/bin:/bin",
            "PEEKABOO_CAPTURE_ENGINE": "modern",
            "PEEKABOO_LOG_LEVEL": "debug",
        ])
        #expect(launchEnvironment["PEEKABOO_CAPTURE_ENGINE"] == nil)
        #expect(launchEnvironment["PATH"] == "/usr/bin:/bin")
        #expect(launchEnvironment["PEEKABOO_LOG_LEVEL"] == "debug")
    }

    private static func options(
        engine: String,
        commandType: any ParsableCommand.Type = SeeCommand.self
    ) throws -> CommandRuntimeOptions {
        var arguments = ["captureEngine": [engine]]
        if commandType == CaptureLiveCommand.self || commandType == CaptureActionCommand.self {
            arguments["bridge-socket"] = ["/synthetic/capture-host.sock"]
        }
        return try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: arguments,
                flags: []
            ),
            commandType: commandType,
            environment: [:]
        )
    }

    private static func handshake(
        operations: [PeekabooBridgeOperation] = Self.operations,
        enabledOperations: [PeekabooBridgeOperation]? = nil,
        capabilities: [String]?,
        permissions: PermissionsStatus? = nil
    ) -> PeekabooBridgeHandshakeResponse {
        BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            permissions: permissions,
            enabledOperations: enabledOperations,
            hostCapabilities: capabilities
        ).withProducerBoundSnapshotFixture()
    }
}
