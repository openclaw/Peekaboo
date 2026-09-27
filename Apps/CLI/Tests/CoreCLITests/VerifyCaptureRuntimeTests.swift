import Commander
import Foundation
import PeekabooBridge
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct VerifyCaptureRuntimeTests {
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
