import Commander
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooBridgeTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct CaptureReadinessRuntimeTests {
    @Test(
        arguments: ["classic", "cg", "auto", "modern", "sckit", "omitted"],
        ["blockedFlag", "blockedEnvironment", "missingEnvironment", "silentRefresh"]
    )
    func `current GUI keeps explicit socket and typed readiness`(engine: String, scenario: String) async throws {
        try await Self.checkRoute(engine: engine, scenario: scenario)
    }

    @Test(
        arguments: ["classic", "cg", "modern"],
        ["flag-normal", "flag-noElements", "environment-normal", "environment-noElements"]
    )
    func `effective environment engine keeps the selected socket`(engine: String, scenario: String) async throws {
        try await Self.checkRoute(
            engine: engine,
            scenario: scenario.hasPrefix("environment") ? "blockedEnvironment" : "blockedFlag",
            noElements: scenario.hasSuffix("noElements"),
            engineFromEnvironment: true
        )
    }

    private static func checkRoute(
        engine: String,
        scenario: String,
        noElements: Bool = true,
        engineFromEnvironment: Bool = false
    ) async throws {
        let socket = "/synthetic/selected-gui.sock"
        let response = Self.handshake(readiness: scenario == "missingEnvironment" ? nil : Self.blockedReadiness)
        var environment = scenario == "blockedFlag" ? [:] : ["PEEKABOO_BRIDGE_SOCKET": socket]
        var arguments: [String: [String]] = scenario == "blockedFlag" ? ["bridge-socket": [socket]] : [:]
        if engineFromEnvironment {
            environment["PEEKABOO_CAPTURE_ENGINE"] = engine
        } else if engine != "omitted" {
            arguments["captureEngine"] = [engine]
        }
        let parsed = ParsedValues(positional: [], options: arguments, flags: noElements ? ["noElements"] : [])
        var options = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: SeeCommand.self,
            environment: environment
        ).applyingEnvironmentOverrides(environment: environment)
        if engineFromEnvironment {
            #expect(options.captureEnginePreference == engine)
            #expect(options.requiresCaptureEnginePreferenceCapability)
        }
        options.autoStartDaemon = false
        if scenario == "silentRefresh" {
            options.requiresScreenCapturePermission = false
        }
        var localFactories = 0
        var ownerClaims = 0
        var safetyRecords = 0
        var remoteFactories = 0
        var handshakes: [String] = []
        let cache = RuntimeHostResolver.RemoteHandshakeCache(
            identity: .init(bundleIdentifier: "synthetic.client", teamIdentifier: nil, processIdentifier: 123),
            handshakeProvider: { candidate, _ in
                handshakes.append(candidate.socketPath)
                #expect(candidate.socketPath == socket)
                return response
            }
        )
        let dependencies = RuntimeHostResolver.Dependencies(
            makeLocalServices: { _ in
                localFactories += 1
                return OwnerPolicyFixtureServices(ownerAware: true)
            },
            claimScreenCaptureKitOwner: {
                ownerClaims += 1
                throw POSIXError(.ENOTSUP)
            },
            inspectScreenCaptureKitOwner: { nil },
            inspectScreenCaptureKitSafety: { _, _, candidates, cache in
                try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
                    candidates: (candidates ?? []).filter { $0.socketPath == socket },
                    identity: cache.identity,
                    handshakeCache: cache,
                    externalHostPresence: { _ in .absent }
                )
            },
            recordScreenCaptureKitSafetyBlocker: { _ in safetyRecords += 1 },
            remoteCandidatePlan: { _, _ in
                .init(
                    explicitSocket: socket,
                    daemonSocketPath: "/synthetic/unused.sock",
                    runtimeBuildIdentity: "fixture",
                    buildScopedDaemonSocketPath: nil,
                    historicalBuildScopedDaemonSocketPaths: [],
                    candidates: [.init(
                        socketPath: socket,
                        requireReusableDaemon: false,
                        requiredHostKind: .gui,
                        requiresValidatedHistoricalDaemon: false
                    )]
                )
            },
            makeRemoteHandshakeCache: { cache },
            makeRemoteServices: { _, _, _ in
                remoteFactories += 1
                return OwnerPolicyFixtureServices(ownerAware: true)
            }
        )

        if engine == "classic" || engine == "cg" {
            let result = try await RuntimeHostResolver.resolveServices(
                options: options, environment: environment, configurationInput: nil, dependencies: dependencies
            )
            #expect(result.selectedRemoteSocketPath == socket)
            #expect(result.selectedRemoteHostProcessIdentifier == 3131)
            #expect(result.captureEngineSafetyOverride == nil)
            #expect(remoteFactories == 1)
        } else {
            let error = await #expect(throws: PreDispatchActionError.self) {
                _ = try await RuntimeHostResolver.resolveServices(
                    options: options, environment: environment, configurationInput: nil, dependencies: dependencies
                )
            }
            #expect(error?.code == .CAPTURE_FAILED)
            let diagnostic = try #require(error?.failure.screenCaptureKitOwnershipDiagnostic)
            if scenario == "missingEnvironment" {
                #expect(diagnostic.kind == .unavailable)
                #expect(diagnostic.blockers.isEmpty)
            } else {
                #expect(diagnostic.blockers == Self.blockedReadiness.failure?.blockers)
            }
            #expect(diagnostic.selectedHost?.processIdentifier == 3131)
            #expect(diagnostic.selectedHost?.socketPath == socket)
            #expect(error?.localizedDescription.contains("predates") == false)
            #expect(remoteFactories == 0)
        }
        #expect(localFactories == 0)
        #expect(ownerClaims == 0)
        #expect(safetyRecords == 0)
        #expect(handshakes == [socket])
    }

    @Test(arguments: ["classic", "cg"])
    func `classic missing readiness still requires positive proof`(engine: String) throws {
        let options = try Self.options(engine: engine)
        #expect(BridgeCapabilityPolicy.supportsRemoteRequirements(
            for: Self.handshake(readiness: nil),
            options: options
        ))
        let engineOnly = Self.handshake(capabilities: [PeekabooBridgeHostCapability.desktopObservationCaptureEngine])
        #expect(!BridgeCapabilityPolicy.supportsRemoteRequirements(for: engineOnly, options: options))
        let ownershipOnly = Self
            .handshake(capabilities: [PeekabooBridgeHostCapability.screenCaptureKitOwnershipEnforcement])
        #expect(!BridgeCapabilityPolicy.supportsRemoteRequirements(for: ownershipOnly, options: options))
        let disabled = Self.handshake(enabledOperations: [.captureScreen])
        #expect(!BridgeCapabilityPolicy.supportsRemoteRequirements(for: disabled, options: options))
    }

    @Test
    func `local owner conversion retains every blocker`() throws {
        let original = try #require(Self.blockedReadiness.failure)
        let refusal = RuntimeHostResolver.ownerRefusal(
            error: original, callerLocal: false, selectedSocket: "/synthetic/current.sock"
        )
        #expect(refusal.failure.screenCaptureKitOwnershipDiagnostic?.blockers == original.blockers)
        #expect(refusal.failure.screenCaptureKitOwnershipDiagnostic?.selectedHost?
            .socketPath == "/synthetic/current.sock")
    }

    @Test
    func `missing and contradictory readiness cannot authorize modern`() throws {
        let options = try Self.options(engine: "modern")
        for readiness in [
            nil,
            ScreenCaptureKitReadiness(state: .unknown),
            .init(state: .ready, failure: Self.blockedReadiness.failure)
        ] {
            #expect(!BridgeCapabilityPolicy.supportsRemoteRequirements(
                for: Self.handshake(readiness: readiness),
                options: options
            ))
        }
        let oldOwner = Self.handshake(readiness: nil, capabilities: [
            PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
            PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
        ])
        #expect(BridgeCapabilityPolicy.supportsRemoteRequirements(for: oldOwner, options: options))
    }

    @Test
    func `ax only ignores capture readiness and ambient engine`() throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: .init(positional: [], options: [:], flags: ["tree", "noScreenshot"]),
            commandType: SeeCommand.self,
            environment: ["PEEKABOO_CAPTURE_ENGINE": "modern"]
        ).applyingEnvironmentOverrides(environment: ["PEEKABOO_CAPTURE_ENGINE": "modern"])
        #expect(options.captureEnginePreference == nil)
        #expect(!options.requiresScreenCaptureKitOwnerCapability)
        #expect(BridgeCapabilityPolicy.supportsRemoteRequirements(for: Self.handshake(), options: options))
    }

    private static func options(engine: String) throws -> CommandRuntimeOptions {
        try CommanderCLIBinder.makeRuntimeOptions(
            from: .init(positional: [], options: ["captureEngine": [engine]], flags: []),
            commandType: SeeCommand.self,
            environment: [:]
        )
    }

    private static let blockedReadiness = ScreenCaptureKitReadiness.failed(
        ScreenCaptureKitOwnerLease.LeaseError.uncoordinatedProcesses([
            .init(processIdentifier: 4242, processStartIdentity: 9001, executablePath: "/synthetic/PotentialHost"),
            .init(processIdentifier: 4343, processStartIdentity: 9002, executablePath: "/synthetic/OtherPotentialHost"),
        ]), stage: .preparation
    )

    private static func handshake(
        readiness: ScreenCaptureKitReadiness? = Self.blockedReadiness,
        capabilities: [String] = [
            PeekabooBridgeHostCapability.screenCaptureKitOwnershipEnforcement,
            PeekabooBridgeHostCapability.classicCaptureWithoutScreenCaptureKit,
            PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
        ],
        enabledOperations: [PeekabooBridgeOperation]? = nil
    ) -> PeekabooBridgeHandshakeResponse {
        .init(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: "current-fixture",
            supportedOperations: [.captureScreen, .desktopObservation, .inspectAccessibilityTree, .ownsSnapshot],
            permissions: .init(screenRecording: true, accessibility: true, appleScript: false, postEvent: false),
            enabledOperations: enabledOperations,
            hostIdentity: .init(
                processIdentifier: 3131,
                processStartIdentity: 4141,
                bundleIdentifier: "synthetic.gui",
                bundleShortVersion: nil,
                bundleVersion: nil,
                codeSignatureHash: "fixture-hash"
            ),
            hostCapabilities: capabilities + [
                PeekabooBridgeHostCapability.producerBoundSnapshotReferences,
                PeekabooBridgeHostCapability.attestedOperationReceipts
            ],
            screenCaptureKitReadiness: readiness
        )
    }
}
