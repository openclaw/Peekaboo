import Commander
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct ExplicitAutoClassicOwnerRuntimeTests {
    @Test(arguments: ["auto", "omitted"], ["flag", "environment"])
    func `automatic capture uses classic on its selected host around a distinct live owner`(
        engine: String,
        socketSource: String
    ) async throws {
        try await Self.checkRoute(engine: engine, scenario: "allowed", socketSource: socketSource)
    }

    @Test(arguments: ["modern", "sckit"])
    func `explicit modern never gains classic fallback around a distinct live owner`(engine: String) async throws {
        try await Self.checkRoute(engine: engine, scenario: "explicitModern")
    }

    @Test(
        arguments: ["auto", "omitted"],
        [
            "missingClassicProof",
            "missingEngineTransport",
            "disabledObservation",
            "authenticationFailure",
            "missingHostIdentity",
            "missingHostGeneration",
            "ownerInspectionFailure",
            "samePIDWrongGeneration",
            "samePIDWrongBuild",
            "unknownReadiness",
            "missingReadiness",
            "blockedReadiness",
            "implicit",
            "persistent",
        ]
    )
    func `automatic owner fallback preserves proof identity readiness and runtime boundaries`(
        engine: String,
        scenario: String
    ) async throws {
        try await Self.checkRoute(engine: engine, scenario: scenario)
    }

    @Test(arguments: ["auto", "omitted"])
    func `cancelled selected host handshake cannot trigger classic fallback`(engine: String) async throws {
        try await Self.checkRoute(engine: engine, scenario: "cancelled")
    }

    private static func checkRoute(
        engine: String,
        scenario: String,
        socketSource: String = "flag"
    ) async throws {
        let socket = "/synthetic/explicit-auto-classic.sock"
        let owner = ScreenCaptureKitOwnerRuntimeTests.ownerReceipt()
        let response = Self.handshake(scenario: scenario, owner: owner)
        let explicitSocket = scenario == "implicit" ? nil : socket
        let environment = socketSource == "environment" ? ["PEEKABOO_BRIDGE_SOCKET": socket] : [:]
        var arguments: [String: [String]] = [:]
        if let explicitSocket, socketSource == "flag" {
            arguments["bridge-socket"] = [explicitSocket]
        }
        if engine != "omitted" {
            arguments["captureEngine"] = [engine]
        }
        let commandType: any ParsableCommand.Type = scenario == "persistent" ? MCPCommand.Serve.self : SeeCommand.self
        var options = try CommanderCLIBinder.makeRuntimeOptions(
            from: .init(positional: [], options: arguments, flags: scenario == "persistent" ? [] : ["noElements"]),
            commandType: commandType,
            environment: environment
        ).applyingEnvironmentOverrides(environment: environment)
        options.autoStartDaemon = false

        var handshakes: [String] = []
        var ownerClaims = 0
        var ownerInspections = 0
        var localFactories = 0
        var remoteFactoryEngines: [CaptureEnginePreference] = []
        let cache = RuntimeHostResolver.RemoteHandshakeCache(
            identity: .init(bundleIdentifier: "synthetic.client", teamIdentifier: nil, processIdentifier: 123),
            handshakeProvider: { candidate, _ in
                handshakes.append(candidate.socketPath)
                if scenario == "cancelled" {
                    throw CancellationError()
                }
                guard candidate.socketPath == socket, scenario != "authenticationFailure" else {
                    throw PeekabooBridgeErrorEnvelope(
                        code: .unauthorizedClient,
                        message: "Synthetic selected host authentication failed"
                    )
                }
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
                return owner
            },
            inspectScreenCaptureKitOwner: {
                ownerInspections += 1
                if scenario == "ownerInspectionFailure" {
                    throw ScreenCaptureKitOwnerLease.LeaseError.invalidOwnerIdentity(
                        "Synthetic owner inspection rejected its receipt"
                    )
                }
                return owner
            },
            remoteCandidatePlan: { _, _ in
                .init(
                    explicitSocket: explicitSocket,
                    daemonSocketPath: "/synthetic/unused-daemon.sock",
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
            makeRemoteServices: { _, handshake, resolvedOptions in
                #expect(handshake.hostIdentity?.processIdentifier == response.hostIdentity?.processIdentifier)
                #expect(handshake.hostIdentity?.processStartIdentity == response.hostIdentity?.processStartIdentity)
                #expect(resolvedOptions.requiresCaptureEnginePreferenceCapability)
                #expect(resolvedOptions.requiresScreenCaptureKitOwnerCapability)
                #expect(BridgeCapabilityPolicy.supportsRemoteRequirements(for: handshake, options: resolvedOptions))
                remoteFactoryEngines.append(ObservationCommandSupport.captureEnginePreference(
                    cliValue: resolvedOptions.captureEnginePreference,
                    configuredValue: nil
                ))
                return OwnerPolicyFixtureServices(ownerAware: true)
            }
        )

        if scenario == "allowed" {
            let resolution = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: environment,
                configurationInput: nil,
                dependencies: dependencies
            )
            #expect(resolution.selectedRemoteSocketPath == socket)
            #expect(resolution.selectedRemoteHostProcessIdentifier == 3131)
            #expect(resolution.selectedRemoteHostIdentity?.processStartIdentity == 4141)
            #expect(resolution.selectedRemoteHostIdentity?.codeSignatureHash == "selected-build")
            #expect(resolution.captureEngineSafetyOverride == .legacy)
            #expect(resolution.requiredHostFailure == nil)
            #expect(remoteFactoryEngines == [.legacy])
            #expect(handshakes == [socket])
        } else if scenario == "cancelled" {
            await #expect(throws: CancellationError.self) {
                _ = try await RuntimeHostResolver.resolveServices(
                    options: options,
                    environment: environment,
                    configurationInput: nil,
                    dependencies: dependencies
                )
            }
            #expect(remoteFactoryEngines.isEmpty)
            #expect(handshakes == [socket])
        } else {
            let error = await #expect(throws: PreDispatchActionError.self) {
                _ = try await RuntimeHostResolver.resolveServices(
                    options: options,
                    environment: environment,
                    configurationInput: nil,
                    dependencies: dependencies
                )
            }
            #expect(error?.code == .CAPTURE_FAILED)
            #expect(error?.envelopeEffect == .refused)
            #expect(error?.envelopeMutationDispatched == false)
            #expect(error?.envelopeRetrySafe == true)
            #expect(remoteFactoryEngines.isEmpty)
        }
        if explicitSocket != nil {
            #expect(handshakes.allSatisfy { $0 == socket })
        }
        if scenario == "ownerInspectionFailure" {
            #expect(ownerInspections == 1)
        }
        #expect(ownerClaims == 0)
        #expect(localFactories == 0)
    }

    private static func handshake(
        scenario: String,
        owner: ScreenCaptureKitOwnerLease.OwnerReceipt
    ) -> PeekabooBridgeHandshakeResponse {
        var capabilities = [
            PeekabooBridgeHostCapability.screenCaptureKitOwnershipEnforcement,
            PeekabooBridgeHostCapability.classicCaptureWithoutScreenCaptureKit,
            PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
            PeekabooBridgeHostCapability.hostGenerationIdentity,
            PeekabooBridgeHostCapability.codeSignatureBuildIdentity,
            PeekabooBridgeHostCapability.producerBoundSnapshotReferences,
            PeekabooBridgeHostCapability.attestedOperationReceipts,
        ]
        if scenario == "missingClassicProof" {
            capabilities.removeAll { $0 == PeekabooBridgeHostCapability.classicCaptureWithoutScreenCaptureKit }
        }
        if scenario == "missingEngineTransport" {
            capabilities.removeAll { $0 == PeekabooBridgeHostCapability.desktopObservationCaptureEngine }
        }
        let readiness: ScreenCaptureKitReadiness? = switch scenario {
        case "unknownReadiness": .init(state: .unknown)
        case "missingReadiness": nil
        case "blockedReadiness": .failed(
                ScreenCaptureKitOwnerLease.LeaseError.ownedByAnotherProcess(
                    path: "/synthetic/owner.lock",
                    receipt: owner
                ),
                stage: .preparation
            )
        default: .init(state: .ready)
        }
        let sharesOwnerPID = scenario == "samePIDWrongGeneration" || scenario == "samePIDWrongBuild"
        let processStartIdentity: UInt64? = switch scenario {
        case "missingHostGeneration": nil
        case "samePIDWrongGeneration": 9002
        case "samePIDWrongBuild": 9001
        default: 4141
        }
        return .init(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: "selected-fixture",
            supportedOperations: [.captureScreen, .desktopObservation, .inspectAccessibilityTree, .ownsSnapshot],
            permissions: .init(screenRecording: true, accessibility: true, appleScript: false, postEvent: false),
            enabledOperations: scenario == "disabledObservation" ? [.captureScreen] : nil,
            hostIdentity: scenario == "missingHostIdentity" ? nil : .init(
                processIdentifier: sharesOwnerPID ? owner.processIdentifier : 3131,
                processStartIdentity: processStartIdentity,
                bundleIdentifier: "synthetic.selected-gui",
                bundleShortVersion: nil,
                bundleVersion: nil,
                codeSignatureHash: scenario == "samePIDWrongGeneration" ? owner.codeSignatureHash : "selected-build"
            ),
            hostCapabilities: capabilities,
            screenCaptureKitReadiness: readiness
        )
    }
}
