import Commander
import Foundation
import PeekabooBridge
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct VerifyCaptureRuntimeTests {
    @Test(arguments: [nil, "auto", "modern"] as [String?])
    func `nonclassic screenshots retain conservative owner admission`(engine: String?) throws {
        let environment = engine.map { ["PEEKABOO_CAPTURE_ENGINE": $0] } ?? [:]
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: .init(positional: [], options: ["screenshot": ["/synthetic/final.png"]], flags: []),
            commandType: VerifyCommand.self,
            environment: environment
        ).applyingEnvironmentOverrides(environment: environment)
        #expect(RuntimeHostResolver.requiresCallerLocalScreenCaptureKitSafetyCheck(
            options: options, environment: environment
        ))
        #expect(RuntimeHostResolver.shouldPreferScreenCaptureKitOwnerHost(options: options, environment: environment))
    }

    @Test
    func `local opt in never transports the verification engine to an explicit socket`() throws {
        let environment = ["PEEKABOO_CAPTURE_ENGINE": "classic"]
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: .init(
                positional: [],
                options: ["screenshot": ["/synthetic/final.png"], "bridge-socket": ["/synthetic/gui.sock"]],
                flags: ["no-remote"]
            ),
            commandType: VerifyCommand.self,
            environment: environment
        ).applyingEnvironmentOverrides(environment: environment)
        #expect(options.remoteIsolationRequested)
        #expect(!options.transportsCaptureEnginePreference)
        #expect(!options.requiresCaptureEnginePreferenceHost)
        #expect(!options.requiresDesktopObservationInlinePixels)
    }

    @Test(arguments: [
        "desktopObservation",
        PeekabooBridgeHostCapability.classicCaptureWithoutScreenCaptureKit,
        PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
        PeekabooBridgeHostCapability.desktopObservationInlinePixels,
    ])
    func `classic verification refuses a host missing a required transport capability`(missing: String) throws {
        let environment = ["PEEKABOO_CAPTURE_ENGINE": "classic"]
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: .init(
                positional: [],
                options: ["screenshot": ["/synthetic/final.png"], "bridge-socket": ["/synthetic/gui.sock"]],
                flags: []
            ),
            commandType: VerifyCommand.self,
            environment: environment
        ).applyingEnvironmentOverrides(environment: environment)
        let handshake = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: "fixture",
            supportedOperations: missing == "desktopObservation" ? [.invalidateImplicitLatestSnapshot] :
                [.desktopObservation, .invalidateImplicitLatestSnapshot],
            permissions: .init(screenRecording: true, accessibility: true, appleScript: false, postEvent: false),
            hostCapabilities: [
                PeekabooBridgeHostCapability.classicCaptureWithoutScreenCaptureKit,
                PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
                PeekabooBridgeHostCapability.desktopObservationInlinePixels,
            ].filter { $0 != missing }
        ).withProducerBoundSnapshotFixture()
        #expect(!BridgeCapabilityPolicy.supportsRemoteRequirements(for: handshake, options: options))
        #expect(RuntimeHostResolver
            .requiredHostFailure(explicitSocket: options.bridgeSocketPath, options: options) != nil)
    }

    @Test(arguments: ["classic", "cg"])
    func `fixed classic screenshots do not inherit dynamic tool ownership`(engine: String) throws {
        let environment = ["PEEKABOO_CAPTURE_ENGINE": engine]
        var options = try CommanderCLIBinder.makeRuntimeOptions(
            from: .init(positional: [], options: ["screenshot": ["/synthetic/final.png"]], flags: []),
            commandType: VerifyCommand.self,
            environment: environment
        ).applyingEnvironmentOverrides(environment: environment)
        #expect(options.usesInlineCaptureEngineTransport)
        #expect(options.usesPerToolSnapshotInvalidation)
        #expect(!options.requiresScreenCapturePermission)
        #expect(!RuntimeHostResolver.requiresCallerLocalScreenCaptureKitSafetyCheck(
            options: options, environment: environment
        ))
        #expect(!RuntimeHostResolver.shouldPreferScreenCaptureKitOwnerHost(options: options, environment: environment))

        options.requiresAgentService = true
        #expect(RuntimeHostResolver.requiresCallerLocalScreenCaptureKitSafetyCheck(
            options: options, environment: environment
        ))
        #expect(RuntimeHostResolver.shouldPreferScreenCaptureKitOwnerHost(options: options, environment: environment))
    }

    @Test(arguments: ["classic", "cg"], [false, true])
    func `fixed classic screenshot prewarms its exact compatible host without requiring permission`(
        engine: String,
        screenRecording: Bool
    ) async throws {
        let socket = "/synthetic/verify-classic-gui.sock"
        let environment = ["PEEKABOO_CAPTURE_ENGINE": engine]
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: .init(
                positional: [],
                options: ["bridge-socket": [socket], "screenshot": ["/synthetic/final.png"]],
                flags: ["window-exists"]
            ),
            commandType: VerifyCommand.self,
            environment: environment
        ).applyingEnvironmentOverrides(environment: environment)
        let handshake = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: "classic-only-fixture",
            supportedOperations: [.desktopObservation, .invalidateImplicitLatestSnapshot],
            permissions: .init(
                screenRecording: screenRecording,
                accessibility: true,
                appleScript: false,
                postEvent: false
            ),
            enabledOperations: [.invalidateImplicitLatestSnapshot],
            hostCapabilities: [
                PeekabooBridgeHostCapability.classicCaptureWithoutScreenCaptureKit,
                PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
                PeekabooBridgeHostCapability.desktopObservationInlinePixels,
            ]
        ).withProducerBoundSnapshotFixture()
        var handshakes: [String] = []
        var localFactories = 0
        var captureProbes = 0
        let cache = RuntimeHostResolver.RemoteHandshakeCache(
            identity: .init(bundleIdentifier: "synthetic.client", teamIdentifier: nil, processIdentifier: 123),
            handshakeProvider: { candidate, _ in
                handshakes.append(candidate.socketPath)
                return handshake
            }
        )
        let result = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: environment,
            configurationInput: nil,
            dependencies: ScreenCaptureKitOwnerRuntimeTests.inertDependencies(
                makeLocalServices: { _ in
                    localFactories += 1
                    return OwnerPolicyFixtureServices(ownerAware: true)
                },
                claimScreenCaptureKitOwner: {
                    captureProbes += 1
                    throw POSIXError(.ENOTSUP)
                },
                inspectScreenCaptureKitOwner: {
                    captureProbes += 1
                    return ScreenCaptureKitOwnerRuntimeTests.ownerReceipt()
                },
                inspectScreenCaptureKitSafety: { _, _, _, _ in
                    captureProbes += 1
                    return .init(
                        socketPath: socket,
                        processIdentifier: nil,
                        processStartIdentity: nil,
                        buildIdentity: "classic-only-fixture"
                    )
                },
                recordScreenCaptureKitSafetyBlocker: { _ in captureProbes += 1 },
                makeRemoteHandshakeCache: { cache }
            )
        )
        #expect(result.selectedRemoteSocketPath == socket)
        #expect(result.toolCapturePreflightRefusal == nil)
        #expect(handshakes == [socket])
        #expect(localFactories == 0)
        #expect(captureProbes == 0)
        #expect(options.transportsCaptureEnginePreference)
        #expect(options.requiresDesktopObservationInlinePixels)
        #expect(!options.requiresScreenCapturePermission)
    }

    @Test(arguments: [nil, "", "/synthetic/final.png"] as [String?])
    func `only requested verification screenshots retain capture admission`(screenshot: String?) throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: .init(positional: [], options: screenshot.map { ["screenshot": [$0]] } ?? [:], flags: []),
            commandType: VerifyCommand.self,
            environment: [:]
        )
        let captures = screenshot != nil
        #expect(options.dynamicToolScreenCaptureReachable == captures)
        #expect(options.ignoresCaptureEnginePreference == !captures)
        #expect(options.usesPerToolSnapshotInvalidation)
        #expect(options.requiresProducerBoundSnapshotReferences)
        #expect(RuntimeHostResolver.requiresCallerLocalScreenCaptureKitSafetyCheck(
            options: options, environment: [:]
        ) == captures)
        #expect(RuntimeHostResolver.shouldPreferScreenCaptureKitOwnerHost(
            options: options, environment: [:]
        ) == captures)
    }

    @Test(arguments: [nil, "auto", "modern", "classic"] as [String?])
    func `screenshot free verification keeps its host without probing capture`(engine: String?) async throws {
        let socket = "/synthetic/verify-gui.sock"
        let environment = engine.map { ["PEEKABOO_CAPTURE_ENGINE": $0] } ?? [:]
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: .init(positional: [], options: ["bridge-socket": [socket]], flags: ["window-exists"]),
            commandType: VerifyCommand.self,
            environment: environment
        ).applyingEnvironmentOverrides(environment: environment)
        let handshake = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: "fixture",
            supportedOperations: [.invalidateImplicitLatestSnapshot],
            permissions: .init(screenRecording: false, accessibility: true, appleScript: false, postEvent: false)
        ).withProducerBoundSnapshotFixture()
        var handshakes: [String] = []
        var localFactories = 0
        var captureProbes = 0
        let cache = RuntimeHostResolver.RemoteHandshakeCache(
            identity: .init(bundleIdentifier: "synthetic.client", teamIdentifier: nil, processIdentifier: 123),
            handshakeProvider: { candidate, _ in
                handshakes.append(candidate.socketPath)
                return handshake
            }
        )
        let result = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: environment,
            configurationInput: nil,
            dependencies: ScreenCaptureKitOwnerRuntimeTests.inertDependencies(
                makeLocalServices: { _ in
                    localFactories += 1
                    return OwnerPolicyFixtureServices(ownerAware: true)
                },
                claimScreenCaptureKitOwner: {
                    captureProbes += 1
                    throw POSIXError(.ENOTSUP)
                },
                inspectScreenCaptureKitOwner: {
                    captureProbes += 1
                    return ScreenCaptureKitOwnerRuntimeTests.ownerReceipt()
                },
                inspectScreenCaptureKitSafety: { _, _, _, _ in
                    captureProbes += 1
                    return .init(
                        socketPath: "/synthetic/unrelated-owner.sock",
                        processIdentifier: nil,
                        processStartIdentity: nil,
                        buildIdentity: "legacy"
                    )
                },
                recordScreenCaptureKitSafetyBlocker: { _ in captureProbes += 1 },
                makeRemoteHandshakeCache: { cache }
            )
        )
        #expect(result.selectedRemoteSocketPath == socket)
        #expect(result.toolCapturePreflightRefusal == nil)
        #expect(result.captureEngineSafetyOverride == nil)
        #expect(options.captureEnginePreference == nil)
        #expect(options.usesPerToolSnapshotInvalidation)
        #expect(options.requiresProducerBoundSnapshotReferences)
        #expect(handshakes == [socket])
        #expect(localFactories == 0)
        #expect(captureProbes == 0)
    }
}
