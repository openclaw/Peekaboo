import Commander
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct DesktopObservationOCRRuntimeCapabilityTests {
    private static let observationOperations: [PeekabooBridgeOperation] = [
        .captureScreen,
        .desktopObservation,
    ]

    @Test
    func `desktop observation OCR requires the operation and additive host capability`() {
        let capable = Self.handshake(capabilities: [
            PeekabooBridgeHostCapability.desktopObservationOCR,
            PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
        ])
        let legacy = Self.handshake(capabilities: nil)
        let empty = Self.handshake(capabilities: [])
        let missingOperation = Self.handshake(
            operations: [.captureScreen],
            capabilities: [PeekabooBridgeHostCapability.desktopObservationOCR]
        )
        let disabled = Self.handshake(
            enabledOperations: [.captureScreen],
            capabilities: [PeekabooBridgeHostCapability.desktopObservationOCR]
        )

        #expect(CommandRuntime.supportsDesktopObservationOCR(for: capable))
        #expect(!CommandRuntime.supportsDesktopObservationOCR(for: legacy))
        #expect(!CommandRuntime.supportsDesktopObservationOCR(for: empty))
        #expect(!CommandRuntime.supportsDesktopObservationOCR(for: missingOperation))
        #expect(!CommandRuntime.supportsDesktopObservationOCR(for: disabled))
    }

    @Test
    func `See OCR requires a capable remote host while ordinary see stays compatible`() throws {
        let ocr = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["ocr"]),
            commandType: SeeCommand.self
        )
        let ordinary = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: SeeCommand.self
        )
        let menubar = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["menubar"]),
            commandType: SeeCommand.self
        )
        let capable = Self.handshake(capabilities: [
            PeekabooBridgeHostCapability.desktopObservationOCR,
            PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
        ])
        let ownerAware = Self.handshake(capabilities: [
            PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
        ])
        let legacy = Self.handshake(capabilities: nil)

        #expect(ocr.requiresDesktopObservationOCR)
        #expect(!menubar.requiresDesktopObservationOCR)
        #expect(!ordinary.requiresDesktopObservationOCR)
        #expect(CommandRuntime.supportsRemoteRequirements(for: capable, options: ocr))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: ocr))
        #expect(CommandRuntime.supportsRemoteRequirements(for: ownerAware, options: menubar))
        #expect(CommandRuntime.supportsRemoteRequirements(for: ownerAware, options: ordinary))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: ordinary))
    }

    @Test
    func `candidate validation refuses legacy and accepts capable protocol 1_22 hosts`() async {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        var options = CommandRuntimeOptions()
        options.requiresDesktopObservation = true
        options.requiresDesktopObservationOCR = true
        let legacy = Self.handshake(capabilities: nil)
        let capable = Self.handshake(capabilities: [PeekabooBridgeHostCapability.desktopObservationOCR])

        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: legacy,
            options: options
        ) == nil)
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: capable,
            options: options
        ) != nil)
    }

    @Test
    func `remote OCR refusal is actionable and no remote explicitly selects local services`() throws {
        let remoteOCR = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["ocr"]),
            commandType: SeeCommand.self
        )
        let localOCR = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["ocr", "no-remote"]),
            commandType: SeeCommand.self
        )

        let failure = RuntimeHostResolver.requiredHostFailure(explicitSocket: nil, options: remoteOCR)
        #expect(failure?.contains(PeekabooBridgeHostCapability.desktopObservationOCR) == true)
        #expect(failure?.contains("Update and relaunch") == true)
        #expect(failure?.contains("--no-remote") == true)
        #expect(localOCR.remoteIsolationRequested)
        #expect(!RuntimeHostResolver.shouldResolveKnownRemoteEndpoints(
            options: localOCR,
            environment: [:],
            configurationInput: nil
        ))
        #expect(RuntimeHostResolver.initialRoutingDecision(
            options: localOCR,
            environment: [:],
            configurationInput: nil,
            knownSnapshotInvalidationRemoteSocketPaths: []
        ) ==
            .local(snapshotInvalidationRemoteSocketPaths: []))
    }

    private static func handshake(
        operations: [PeekabooBridgeOperation] = Self.observationOperations,
        enabledOperations: [PeekabooBridgeOperation]? = nil,
        capabilities: [String]?
    ) -> PeekabooBridgeHandshakeResponse {
        BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: operations,
            enabledOperations: enabledOperations,
            hostCapabilities: capabilities
        ).withProducerBoundSnapshotFixture()
    }
}
