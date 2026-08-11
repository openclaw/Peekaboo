import Commander
import PeekabooBridge
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
            capabilities: [PeekabooBridgeHostCapability.desktopObservationCaptureEngine]
        )
        let legacy = Self.handshake(capabilities: nil)
        let empty = Self.handshake(capabilities: [])
        let missingOperation = Self.handshake(
            operations: [.captureScreen],
            capabilities: [PeekabooBridgeHostCapability.desktopObservationCaptureEngine]
        )
        let disabled = Self.handshake(
            enabledOperations: [.captureScreen],
            capabilities: [PeekabooBridgeHostCapability.desktopObservationCaptureEngine]
        )

        #expect(CommandRuntime.supportsDesktopObservationCaptureEngine(for: capable))
        #expect(!CommandRuntime.supportsDesktopObservationCaptureEngine(for: legacy))
        #expect(!CommandRuntime.supportsDesktopObservationCaptureEngine(for: empty))
        #expect(!CommandRuntime.supportsDesktopObservationCaptureEngine(for: missingOperation))
        #expect(!CommandRuntime.supportsDesktopObservationCaptureEngine(for: disabled))
    }

    @Test(arguments: ["modern", "sckit", "classic", "cg"])
    func `explicit non auto engine requires a capable remote host`(engine: String) throws {
        let options = try Self.options(engine: engine)
        let capable = Self.handshake(
            capabilities: [PeekabooBridgeHostCapability.desktopObservationCaptureEngine]
        )
        let legacy = Self.handshake(capabilities: nil)

        #expect(options.requiresCaptureEnginePreferenceHost)
        #expect(options.requiresCaptureEnginePreferenceCapability)
        #expect(CommandRuntime.supportsRemoteRequirements(for: capable, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: options))
    }

    @Test
    func `auto remains compatible and no remote remains caller local`() throws {
        let auto = try Self.options(engine: "auto")
        let localModern = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["captureEngine": ["modern"]],
                flags: ["no-remote"]
            ),
            commandType: SeeCommand.self
        )
        let legacy = Self.handshake(capabilities: nil)

        #expect(auto.requiresCaptureEnginePreferenceHost)
        #expect(!auto.requiresCaptureEnginePreferenceCapability)
        #expect(CommandRuntime.supportsRemoteRequirements(for: legacy, options: auto))
        #expect(localModern.requiresCaptureEnginePreferenceCapability)
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
        capabilities: [String]?
    ) -> PeekabooBridgeHandshakeResponse {
        PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 22),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            enabledOperations: enabledOperations,
            hostCapabilities: capabilities
        )
    }
}
