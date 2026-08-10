import Commander
import PeekabooBridge
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct ExactWindowROIRuntimeCapabilityTests {
    private static let roiOperations: [PeekabooBridgeOperation] = [
        .desktopObservation,
        .storeScreenshot,
        .storeDetectionResult,
        .storeAnnotatedScreenshot,
    ]

    @Test
    func `exact window ROI requires protocol 1_20 and enabled publication operations`() {
        let supported = Self.handshake(
            minor: 20,
            hostKind: .gui,
            operations: Self.roiOperations,
            enabledOperations: Self.roiOperations
        )
        let older = Self.handshake(
            minor: 19,
            hostKind: .gui,
            operations: Self.roiOperations,
            enabledOperations: Self.roiOperations
        )
        let disabledOperations = Self.roiOperations.filter { $0 != .desktopObservation }
        let disabled = Self.handshake(
            minor: 20,
            hostKind: .gui,
            operations: Self.roiOperations,
            enabledOperations: disabledOperations
        )
        let incompleteOperations = Self.roiOperations.filter { $0 != .storeAnnotatedScreenshot }
        let incomplete = Self.handshake(
            minor: 20,
            hostKind: .gui,
            operations: incompleteOperations,
            enabledOperations: incompleteOperations
        )

        #expect(CommandRuntime.supportsExactWindowROIObservation(for: supported))
        #expect(!CommandRuntime.supportsExactWindowROIObservation(for: older))
        #expect(!CommandRuntime.supportsExactWindowROIObservation(for: disabled))
        #expect(!CommandRuntime.supportsExactWindowROIObservation(for: incomplete))
    }

    @Test
    func `See ROI requires protocol 1_20 while ordinary see remains compatible`() throws {
        let roi = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["windowId": ["42"], "roi": ["0,0,100,100"]],
                flags: []
            ),
            commandType: SeeCommand.self
        )
        let ordinary = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["windowId": ["42"]],
                flags: []
            ),
            commandType: SeeCommand.self
        )
        let operations = [PeekabooBridgeOperation.captureScreen] + Self.roiOperations
        let older = Self.handshake(minor: 19, hostKind: .onDemand, operations: operations)
        let current = Self.handshake(minor: 20, hostKind: .onDemand, operations: operations)
        let disabledOperations = operations.filter { $0 != .desktopObservation }
        let disabled = Self.handshake(
            minor: 20,
            hostKind: .onDemand,
            operations: operations,
            enabledOperations: disabledOperations
        )

        #expect(roi.requiresExactWindowROIObservation)
        #expect(!ordinary.requiresExactWindowROIObservation)
        #expect(!CommandRuntime.supportsRemoteRequirements(for: older, options: roi))
        #expect(CommandRuntime.supportsRemoteRequirements(for: current, options: roi))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: disabled, options: roi))
        #expect(CommandRuntime.supportsRemoteRequirements(for: older, options: ordinary))
    }

    @Test
    func `candidate validation requires ROI observation and publication operations`() async {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        var options = CommandRuntimeOptions()
        options.requiresExactWindowROIObservation = true
        let older = Self.handshake(
            minor: 19,
            hostKind: .onDemand,
            operations: Self.roiOperations,
            enabledOperations: Self.roiOperations
        )
        let current = Self.handshake(
            minor: 20,
            hostKind: .onDemand,
            operations: Self.roiOperations,
            enabledOperations: Self.roiOperations
        )
        let disabledOperations = Self.roiOperations.filter { $0 != .desktopObservation }
        let disabled = Self.handshake(
            minor: 20,
            hostKind: .onDemand,
            operations: Self.roiOperations,
            enabledOperations: disabledOperations
        )

        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: older,
            options: options
        ) == nil)
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: current,
            options: options
        ) != nil)
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: disabled,
            options: options
        ) == nil)
    }

    private static func handshake(
        minor: Int,
        hostKind: PeekabooBridgeHostKind,
        operations: [PeekabooBridgeOperation],
        enabledOperations: [PeekabooBridgeOperation]? = nil
    ) -> PeekabooBridgeHandshakeResponse {
        PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: minor),
            hostKind: hostKind,
            build: nil,
            supportedOperations: operations,
            enabledOperations: enabledOperations
        )
    }
}
