import Commander
import Foundation
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct RuntimeHostDiagnosticTests {
    private static let socket = "/synthetic/diagnostic-host.sock"
    private static let operations: [PeekabooBridgeOperation] = [
        .captureScreen,
        .desktopObservation,
        .createSnapshot,
        .invalidateImplicitLatestSnapshot,
    ]
    private static let capabilities = [
        PeekabooBridgeHostCapability.desktopObservationFreshAccessibilityTree,
        PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
    ]

    @Test
    func `fresh capable receiptless host reports producer binding instead of missing fresh support`() async throws {
        let options = try Self.freshSeeOptions()
        let handshake = Self.handshake(enabledOperations: Self.operations)

        #expect(options.requiresDesktopObservationFreshAccessibilityTree)
        #expect(options.requiresProducerBoundSnapshotReferences)
        #expect(!options.requiresExplicitSnapshotPublication)
        #expect(PeekabooBridgeConstants.defaultTrustedHostTeamIDs(socketPath: Self.socket) == nil)
        #expect(handshake.negotiatedVersion == PeekabooBridgeProtocolVersion(major: 1, minor: 28))
        #expect(handshake.supportsDesktopObservationFreshAccessibilityTree)
        #expect(!BridgeCapabilityPolicy.supportsProducerBoundSnapshotReferences(for: handshake))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: handshake, options: options))
        #expect(BridgeCapabilityPolicy.firstUnmetRemoteRequirement(for: handshake, options: options) ==
            .producerBoundSnapshotReferences)

        let evaluation = await Self.evaluate(handshake, options: options)
        #expect(evaluation.validation == nil)
        #expect(evaluation.rejection == .requirementsNotMet)
        #expect(evaluation.requirementFailure == .producerBoundSnapshotReferences)
        let report = try BridgeCandidateRejectionReport.runtime(
            #require(evaluation.rejection),
            handshake: handshake
        )
        #expect(report.code == "requirementsNotMet")

        let message = try #require(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: Self.socket,
            options: options,
            rejections: [evaluation]
        ))
        Self.expectProducerBindingDiagnostic(message)
    }

    @Test
    func `resolver retains the actual producer rejection through local fallback and preflight`() async throws {
        let options = try Self.freshSeeOptions()
        let fixture = RoutingFixture(handshake: Self.handshake(enabledOperations: Self.operations))
        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: fixture.dependencies()
        )

        #expect(resolution.selectedRemoteSocketPath == nil)
        #expect(resolution.hostDescription == "local (in-process fallback)")
        #expect(fixture.localFactoryCalls == 1)
        #expect(fixture.handshakePaths == [Self.socket])
        let message = try #require(resolution.requiredHostFailure)
        Self.expectProducerBindingDiagnostic(message)

        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: resolution.services,
            requiredHostFailure: message
        )
        let error = #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try runtime.requireCompatibleHost()
        }
        #expect(error?.code == .operationNotSupported)
        #expect(error?.message == message)
        if let error {
            #expect(CaptureLiveCommand().mapErrorToCode(error) == .VALIDATION_ERROR)
        }
    }

    @Test
    func `genuinely missing fresh support remains the first reported requirement`() async throws {
        let options = try Self.freshSeeOptions()
        let handshake = Self.handshake(capabilities: [PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership])
        let evaluation = await Self.evaluate(handshake, options: options)

        #expect(!handshake.supportsDesktopObservationFreshAccessibilityTree)
        #expect(!CommandRuntime.supportsRemoteRequirements(for: handshake, options: options))
        #expect(evaluation.rejection == .requirementsNotMet)
        #expect(evaluation.requirementFailure == .capability("desktopObservationFreshAccessibilityTree"))
        let message = try #require(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: Self.socket,
            options: options,
            rejections: [evaluation]
        ))
        #expect(message.contains("unmet desktopObservationFreshAccessibilityTree requirement"))
        #expect(!message.contains("producer-bound"))
    }

    @Test
    func `disabled observation is not misreported as missing advertised fresh support`() async throws {
        let options = try Self.freshSeeOptions()
        let handshake = Self.handshake(enabledOperations: Self.operations.filter { $0 != .desktopObservation })
        let evaluation = await Self.evaluate(handshake, options: options)

        #expect(handshake.supportsDesktopObservationFreshAccessibilityTree)
        #expect(!CommandRuntime.supportsRemoteRequirements(for: handshake, options: options))
        #expect(evaluation.rejection == .requirementsNotMet)
        #expect(evaluation.requirementFailure == .capability("desktopObservation"))
        let message = try #require(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: Self.socket,
            options: options,
            rejections: [evaluation]
        ))
        #expect(message.contains("unmet desktopObservation requirement"))
        #expect(!message.contains("desktopObservationFreshAccessibilityTree"))
        #expect(!message.contains("producer-bound"))
    }

    @Test
    func `missing screen permission retains its rejection before fresh and producer requirements`() async throws {
        let options = try Self.freshSeeOptions()
        let handshake = Self.handshake(screenRecording: false)
        let evaluation = await Self.evaluate(handshake, options: options)

        #expect(handshake.supportsDesktopObservationFreshAccessibilityTree)
        #expect(!CommandRuntime.supportsRemoteRequirements(for: handshake, options: options))
        #expect(evaluation.rejection == .missingPermissions([.screenRecording]))
        #expect(evaluation.requirementFailure == nil)
        let report = try BridgeCandidateRejectionReport.runtime(
            #require(evaluation.rejection),
            handshake: handshake
        )
        #expect(report.code == "missingPermissions")
        let message = try #require(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: Self.socket,
            options: options,
            rejections: [evaluation]
        ))
        #expect(message.contains("missing host permissions (Screen Recording)"))
        #expect(!message.contains("desktopObservationFreshAccessibilityTree"))
        #expect(!message.contains("producer-bound"))
    }

    @Test
    func `missing OCR precedes missing fresh and producer requirements`() async throws {
        let options = try Self.freshSeeOptions(ocr: true)
        let handshake = Self.handshake(capabilities: [PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership])
        let evaluation = await Self.evaluate(handshake, options: options)

        #expect(options.requiresDesktopObservationOCR)
        #expect(!handshake.supportsDesktopObservationFreshAccessibilityTree)
        #expect(!CommandRuntime.supportsRemoteRequirements(for: handshake, options: options))
        #expect(evaluation.requirementFailure == .capability("desktopObservationOCR"))
        let message = try #require(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: Self.socket,
            options: options,
            rejections: [evaluation]
        ))
        #expect(message.contains("unmet desktopObservationOCR requirement"))
        #expect(!message.contains("desktopObservationFreshAccessibilityTree"))
        #expect(!message.contains("producer-bound"))
    }

    @Test
    func `protocol and host kind gates retain priority over requirement diagnostics`() async throws {
        let options = try Self.freshSeeOptions()
        let handshake = Self.handshake()
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: Self.socket,
            requireReusableDaemon: false,
            requiredHostKind: .gui,
            requiresValidatedHistoricalDaemon: false
        )
        let protocolEvaluation = await RuntimeHostResolver.evaluateRemoteCandidate(
            candidate,
            handshake: handshake,
            options: options,
            requiredProtocolVersion: PeekabooBridgeConstants.protocolVersion,
            fetchReusableDaemonStatus: { _ in fatalError("No daemon status probes") }
        )
        let kindEvaluation = await RuntimeHostResolver.evaluateRemoteCandidate(
            candidate,
            handshake: handshake,
            options: options,
            fetchReusableDaemonStatus: { _ in fatalError("No daemon status probes") }
        )

        #expect(protocolEvaluation.rejection == .protocolVersionMismatch)
        #expect(protocolEvaluation.requirementFailure == nil)
        #expect(kindEvaluation.rejection == .hostKindMismatch(expected: .gui))
        #expect(kindEvaluation.requirementFailure == nil)
    }

    @Test
    func `mixed candidate rejections summarize distinct reasons without blaming all hosts for fresh`() async throws {
        let options = try Self.freshSeeOptions()
        let missingFresh = await Self.evaluate(
            Self.handshake(capabilities: [PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership]),
            options: options
        )
        let missingProducer = await Self.evaluate(Self.handshake(), options: options)
        let message = try #require(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: nil,
            options: options,
            rejections: [missingFresh, missingProducer, missingFresh]
        ))

        #expect(message.contains("Attempted hosts were rejected for:"))
        #expect(message.components(separatedBy: "unmet desktopObservationFreshAccessibilityTree requirement")
            .count == 2)
        #expect(message.contains("authenticated, producer-bound snapshot requirements"))
        #expect(!message.contains("No compatible Bridge host advertises"))
        #expect(!message.contains("Update and relaunch"))
        #expect(!message.contains("remove --bridge-socket"))
        #expect(message.contains("automatically discovered hosts"))
    }

    @Test(arguments: [false, true])
    func `producer operation policy failure does not prescribe socket trust changes`(supported: Bool) async throws {
        let options = try Self.freshSeeOptions()
        let handshake = Self.handshake(
            version: PeekabooBridgeConstants.protocolVersion,
            operations: Self.operations + (supported ? [.ownsSnapshot] : []),
            enabledOperations: Self.operations,
            capabilities: Self.capabilities + [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.producerBoundSnapshotReferences,
            ]
        )
        let evaluation = await Self.evaluate(handshake, options: options)
        #expect(handshake.supportsDesktopObservationFreshAccessibilityTree)
        #expect(!CommandRuntime.supportsRemoteRequirements(for: handshake, options: options))
        #expect(evaluation.rejection == .requirementsNotMet)
        #expect(evaluation.requirementFailure == .capability("supported and enabled ownsSnapshot"))
        let message = try #require(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: Self.socket,
            options: options,
            rejections: [evaluation]
        ))
        #expect(message.contains("unmet supported and enabled ownsSnapshot requirement"))
        #expect(!message.contains("desktopObservationFreshAccessibilityTree"))
        #expect(!message.contains("host-signing policy"))
        #expect(!message.contains("remove --bridge-socket"))
    }

    @Test
    func `current producer capable host stays eligible and resolves remotely`() async throws {
        let options = try Self.freshSeeOptions()
        let handshake = Self.handshake(version: PeekabooBridgeConstants.protocolVersion)
            .withProducerBoundSnapshotFixture()
        let evaluation = await Self.evaluate(handshake, options: options)

        #expect(handshake.supportsDesktopObservationFreshAccessibilityTree)
        #expect(CommandRuntime.supportsRemoteRequirements(for: handshake, options: options))
        #expect(BridgeCapabilityPolicy.firstUnmetRemoteRequirement(for: handshake, options: options) == nil)
        #expect(evaluation.validation != nil)
        #expect(evaluation.rejection == nil)
        #expect(evaluation.requirementFailure == nil)

        let fixture = RoutingFixture(handshake: handshake)
        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: fixture.dependencies()
        )
        #expect(resolution.selectedRemoteSocketPath == Self.socket)
        #expect(resolution.requiredHostFailure == nil)
        #expect(fixture.localFactoryCalls == 0)
        #expect(fixture.handshakePaths == [Self.socket])
    }

    @Test
    func `producer only requirements preserve nil fallback and explicit bridge unavailable envelope`() async throws {
        var options = CommandRuntimeOptions()
        options.requiresProducerBoundSnapshotReferences = true
        options.bridgeSocketPath = Self.socket
        options.autoStartDaemon = false
        let handshake = Self.handshake()
        let evaluation = await Self.evaluate(handshake, options: options)

        #expect(evaluation.requirementFailure == .producerBoundSnapshotReferences)
        #expect(RuntimeHostResolver.requiredHostFailure(explicitSocket: Self.socket, options: options) == nil)
        #expect(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: Self.socket,
            options: options,
            rejections: [evaluation]
        ) == nil)
        #expect(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: nil,
            options: options,
            rejections: [evaluation]
        ) == nil)

        let fixture = RoutingFixture(handshake: handshake)
        let error = await #expect(throws: BridgeExplicitSocketUnavailableError.self) {
            _ = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: [:],
                configurationInput: nil,
                dependencies: fixture.dependencies()
            )
        }
        #expect(error?.socketPath == Self.socket)
        #expect(error?.envelopeCode == .BRIDGE_UNAVAILABLE)
        #expect(fixture.localFactoryCalls == 0)
        #expect(fixture.handshakePaths == [Self.socket])
    }

    @Test(arguments: [
        "enabled",
        "implicit-enabled",
        "protocol",
        "receipts",
        "producer",
        "owns-supported",
        "owns-enabled"
    ])
    func `producer requirement diagnostics preserve every admission predicate`(scenario: String) async {
        var options = CommandRuntimeOptions()
        options.requiresProducerBoundSnapshotReferences = true
        let version = scenario == "protocol"
            ? PeekabooBridgeProtocolVersion(major: 1, minor: 33)
            : PeekabooBridgeConstants.producerBoundSnapshotReferencesVersion
        let capabilities = [
            PeekabooBridgeHostCapability.attestedOperationReceipts,
            PeekabooBridgeHostCapability.producerBoundSnapshotReferences,
        ].filter {
            !(scenario == "receipts" && $0 == PeekabooBridgeHostCapability.attestedOperationReceipts) &&
                !(scenario == "producer" && $0 == PeekabooBridgeHostCapability.producerBoundSnapshotReferences)
        }
        let operations: [PeekabooBridgeOperation] = scenario == "owns-supported" ? [] : [.ownsSnapshot]
        let enabledOperations: [PeekabooBridgeOperation]? = scenario == "implicit-enabled"
            ? nil
            : scenario == "owns-enabled" ? [] : operations
        let handshake = Self.handshake(
            version: version,
            operations: operations,
            enabledOperations: enabledOperations,
            capabilities: capabilities
        )
        let expectedSupport = scenario == "enabled" || scenario == "implicit-enabled"
        let failure = BridgeCapabilityPolicy.firstUnmetRemoteRequirement(for: handshake, options: options)
        let evaluation = await Self.evaluate(handshake, options: options)

        #expect(BridgeCapabilityPolicy.supportsProducerBoundSnapshotReferences(for: handshake) == expectedSupport)
        #expect(CommandRuntime.supportsRemoteRequirements(for: handshake, options: options) == expectedSupport)
        #expect((failure == nil) == expectedSupport)
        #expect((evaluation.validation != nil) == expectedSupport)
        if !expectedSupport {
            let expectedFailure: BridgeCapabilityPolicy.RemoteRequirementFailure =
                scenario == "owns-supported" || scenario == "owns-enabled"
                    ? .capability("supported and enabled ownsSnapshot") : .producerBoundSnapshotReferences
            #expect(failure == expectedFailure)
            #expect(evaluation.rejection == .requirementsNotMet)
            #expect(evaluation.requirementFailure == expectedFailure)
        }
    }

    private static func freshSeeOptions(ocr: Bool = false) throws -> CommandRuntimeOptions {
        var options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["bridge-socket": [Self.socket]],
                flags: ocr ? ["fresh", "ocr"] : ["fresh"]
            ),
            commandType: SeeCommand.self,
            environment: [:]
        )
        options.autoStartDaemon = false
        return options
    }

    private static func handshake(
        version: PeekabooBridgeProtocolVersion = .init(major: 1, minor: 28),
        operations: [PeekabooBridgeOperation] = Self.operations,
        enabledOperations: [PeekabooBridgeOperation]? = nil,
        capabilities: [String] = Self.capabilities,
        screenRecording: Bool = true
    ) -> PeekabooBridgeHandshakeResponse {
        BridgeTestFixtures.handshake(
            negotiatedVersion: version,
            hostKind: .onDemand,
            supportedOperations: operations,
            permissions: .init(
                screenRecording: screenRecording,
                accessibility: true,
                appleScript: true,
                postEvent: true
            ),
            enabledOperations: enabledOperations,
            hostCapabilities: capabilities
        )
    }

    private static func evaluate(
        _ handshake: PeekabooBridgeHandshakeResponse,
        options: CommandRuntimeOptions
    ) async -> RuntimeHostResolver.RemoteCandidateEvaluation {
        await RuntimeHostResolver.evaluateRemoteCandidate(
            .init(
                socketPath: self.socket,
                requireReusableDaemon: false,
                requiredHostKind: nil,
                requiresValidatedHistoricalDaemon: false
            ),
            handshake: handshake,
            options: options,
            fetchReusableDaemonStatus: { _ in fatalError("No daemon status probes") }
        )
    }

    private static func expectProducerBindingDiagnostic(_ message: String) {
        #expect(message.contains("authenticated, producer-bound snapshots"))
        #expect(message.contains("Bridge protocol 1.34 or newer"))
        #expect(message.contains("standard socket or canonical build-scoped daemon socket"))
        #expect(message.contains("Custom sockets without a host-signing policy"))
        #expect(message.contains("updating the binary alone does not establish that trust"))
        #expect(!message.contains("desktopObservationFreshAccessibilityTree"))
        #expect(!message.contains("Update and relaunch"))
    }

    @MainActor
    private final class RoutingFixture {
        let handshake: PeekabooBridgeHandshakeResponse
        var localFactoryCalls = 0
        var handshakePaths: [String] = []

        init(handshake: PeekabooBridgeHandshakeResponse) {
            self.handshake = handshake
        }

        func dependencies() -> RuntimeHostResolver.Dependencies {
            ScreenCaptureKitOwnerRuntimeTests.inertDependencies(
                makeLocalServices: { _ in
                    self.localFactoryCalls += 1
                    return OwnerPolicyFixtureServices(ownerAware: true)
                },
                claimScreenCaptureKitOwner: { fatalError("No capture ownership claims") },
                inspectScreenCaptureKitOwner: { nil },
                inspectScreenCaptureKitSafety: { _, _, _, _ in nil },
                recordScreenCaptureKitSafetyBlocker: { _ in fatalError("No capture safety writes") },
                makeRemoteHandshakeCache: {
                    RuntimeHostResolver.RemoteHandshakeCache(
                        identity: .init(
                            bundleIdentifier: "boo.peekaboo.test.diagnostics",
                            teamIdentifier: nil,
                            processIdentifier: 123
                        ),
                        handshakeProvider: { candidate, _ in
                            self.handshakePaths.append(candidate.socketPath)
                            return self.handshake
                        }
                    )
                },
                snapshotAffinityProbe: { _, _, _, _ in fatalError("No snapshot ownership probes") }
            )
        }
    }
}
