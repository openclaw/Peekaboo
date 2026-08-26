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

    private static func options(engine: String) throws -> CommandRuntimeOptions {
        try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["captureEngine": [engine]],
                flags: []
            ),
            commandType: SeeCommand.self
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
