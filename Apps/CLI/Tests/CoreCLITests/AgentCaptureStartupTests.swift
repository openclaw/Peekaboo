import Commander
import Darwin
import Foundation
import PeekabooAgentRuntime
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct AgentCaptureStartupTests {
    private nonisolated static let commands = [
        ["agent", "Inspect"], ["agent", "run", "Inspect"], ["agent", "chat"],
        ["agent", "resume"], ["agent", "sessions"],
    ]

    @Test(arguments: Self.commands)
    func `Agent startup uses the effective explicit tool catalog`(command: [String]) throws {
        let environments: [([String: String], Bool)] = [
            (["PEEKABOO_ALLOW_TOOLS": "inspect_ui,click,type,set_value,press"], false),
            (["PEEKABOO_ALLOW_TOOLS": "browser,see", "PEEKABOO_DISABLE_TOOLS": "see"], false),
            ([:], true),
            (["PEEKABOO_ALLOW_TOOLS": ""], true),
            (["PEEKABOO_ALLOW_TOOLS": " , "], true),
            (["PEEKABOO_ALLOW_TOOLS": "see"], true),
            (["PEEKABOO_ALLOW_TOOLS": "image"], true),
            (["PEEKABOO_ALLOW_TOOLS": "capture"], true),
            (["PEEKABOO_ALLOW_TOOLS": "verify_state"], true),
            (["PEEKABOO_ALLOW_TOOLS": "agent"], true),
            (["PEEKABOO_ALLOW_TOOLS": "future_tool"], true),
        ]
        for noContext in command.last == "sessions" ? [false] : [false, true] {
            let resolved = try CommanderRuntimeRouter.resolve(
                argv: ["peekaboo"] + command + (noContext ? ["--no-desktop-context"] : [])
            )
            for (environment, captureReachable) in environments {
                let options = try CommanderCLIBinder.makeRuntimeOptions(
                    from: resolved.parsedValues,
                    commandType: resolved.type,
                    environment: environment
                )
                #expect(options.dynamicToolScreenCaptureReachable == captureReachable)
                #expect(options.usesPersistentDynamicCaptureRuntime == captureReachable)
                #expect(options.requiresSilentCapture == captureReachable)
                Self.expectDynamicSafety(options)
            }
        }
    }

    @Test(arguments: 0..<16)
    func `every visual enhancement conservatively retains capture capability`(bits: Int) {
        let options = AgentEnhancementOptions(
            contextAware: bits & 1 != 0,
            verifyActions: bits & 2 != 0,
            smartCapture: bits & 4 != 0,
            regionFocusAfterAction: bits & 8 != 0
        )
        #expect(options.mayCaptureScreen == (bits & 14 != 0))
        #expect(!AgentEnhancementOptions.default.mayCaptureScreen)
        #expect(!AgentEnhancementOptions.minimal.mayCaptureScreen)
        #expect(AgentEnhancementOptions.full.mayCaptureScreen)
        #expect(AgentEnhancementOptions.verified.mayCaptureScreen)
    }

    @Test(arguments: Self.commands)
    func `public noncapturing Agent entrypoints skip capture startup probes`(command: [String]) async throws {
        let names = ["PEEKABOO_ALLOW_TOOLS", "PEEKABOO_DISABLE_TOOLS"]
        let previous = names.map { getenv($0).map { String(cString: $0) } }
        setenv(names[0], "inspect_ui,click,type,set_value,press", 1)
        unsetenv(names[1])
        defer {
            for (name, value) in zip(names, previous) {
                if let value {
                    setenv(name, value, 1)
                } else {
                    unsetenv(name)
                }
            }
        }
        for noContext in command.last == "sessions" ? [false] : [false, true] {
            let probe = CaptureStartupProbe()
            await #expect(throws: CaptureStartupProbe.Stop.self) {
                try await CommanderRuntimeExecutor.resolveAndRun(
                    arguments: ["peekaboo"] + command + ["--no-remote"] +
                        (noContext ? ["--no-desktop-context"] : []),
                    runtimeFactory: .init { options in
                        Self.expectDynamicSafety(options)
                        #expect(!options.dynamicToolScreenCaptureReachable)
                        _ = try await probe.resolve(options: options)
                        throw CaptureStartupProbe.Stop.beforeAgentExecution
                    }
                )
            }
            #expect(probe.localFactoryCalls == 1)
            #expect(probe.captureProbeCalls == 0)
            #expect(probe.candidatePlanCalls == 0)
            #expect(probe.handshakeFactoryCalls == 0)
        }
    }

    @Test(arguments: ["see", "image", "capture", "verify_state", "agent", "future_tool"])
    func `capturing Agent allowlists retain runtime safety inspection`(tool: String) async throws {
        let resolved = try CommanderRuntimeRouter.resolve(
            argv: ["peekaboo", "agent", "Inspect", "--no-remote", "--no-desktop-context"]
        )
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: resolved.parsedValues,
            commandType: resolved.type,
            environment: ["PEEKABOO_ALLOW_TOOLS": tool]
        )
        let probe = CaptureStartupProbe()
        _ = try await probe.resolve(options: options)
        #expect(probe.captureProbeCalls > 0)
        #expect(probe.candidatePlanCalls == 1)
        #expect(probe.handshakeFactoryCalls == 1)
        #expect(probe.localFactoryCalls == 1)
    }

    private static func expectDynamicSafety(_ options: CommandRuntimeOptions) {
        #expect(options.requiresAgentService)
        #expect(options.usesPerToolSnapshotInvalidation)
        #expect(options.requiresProducerBoundSnapshotReferences)
        #expect(options.requiresProcessGenerationPinnedHotkeys)
        #expect(options.requiresTargetedClickAccessibilityValueDelivery)
    }
}

@MainActor
private final class CaptureStartupProbe {
    enum Stop: Error { case beforeAgentExecution }

    var localFactoryCalls = 0
    var captureProbeCalls = 0
    var candidatePlanCalls = 0
    var handshakeFactoryCalls = 0

    func resolve(options: CommandRuntimeOptions) async throws -> RuntimeHostResolver.Resolution {
        let result = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: ScreenCaptureKitOwnerRuntimeTests.inertDependencies(
                makeLocalServices: { _ in
                    self.localFactoryCalls += 1
                    return OwnerPolicyFixtureServices(ownerAware: true)
                },
                claimScreenCaptureKitOwner: {
                    self.captureProbeCalls += 1
                    throw Stop.beforeAgentExecution
                },
                inspectScreenCaptureKitOwner: {
                    self.captureProbeCalls += 1
                    return nil
                },
                inspectScreenCaptureKitSafety: { _, _, _, _ in
                    self.captureProbeCalls += 1
                    return nil
                },
                recordScreenCaptureKitSafetyBlocker: { _ in self.captureProbeCalls += 1 },
                remoteCandidatePlan: { _, _ in
                    self.candidatePlanCalls += 1
                    return .init(
                        explicitSocket: nil,
                        daemonSocketPath: "/synthetic/daemon.sock",
                        runtimeBuildIdentity: "fixture",
                        buildScopedDaemonSocketPath: nil,
                        historicalBuildScopedDaemonSocketPaths: [],
                        candidates: []
                    )
                },
                makeRemoteHandshakeCache: {
                    self.handshakeFactoryCalls += 1
                    return ScreenCaptureKitOwnerRuntimeTests.inertHandshakeCache()
                }
            )
        )
        #expect(result.selectedRemoteSocketPath == nil)
        #expect(result.toolCapturePreflightRefusal == nil)
        #expect(result.captureEngineSafetyOverride == nil)
        return result
    }
}
