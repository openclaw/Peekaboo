import Commander
import Foundation
import MCP
import PeekabooCore
import TachikomaMCP
import Testing
@testable import PeekabooCLI

extension ScreenCaptureKitOwnerRuntimeTests {
    @Test
    func `explicit dynamic host starts while unrelated legacy owner blocks only capture tools`() async throws {
        let selectedSocket = "/tmp/peekaboo-dynamic-selected-\(UUID().uuidString).sock"
        let selectedHost = try await Self.startHost(
            socketPath: selectedSocket,
            processIdentifier: 4242,
            processStartIdentity: 9001,
            codeSignatureHash: "selected-build"
        )
        defer { Task { await selectedHost.stop() } }

        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["bridge-socket": [selectedSocket]],
                flags: []
            ),
            commandType: MCPCommand.Serve.self
        )
        #expect(options.bridgeSocketPath == selectedSocket)
        #expect(options.usesPerToolSnapshotInvalidation)
        #expect(!options.requiresScreenCaptureKitOwnerCapability)
        #expect(!options.requiresScreenCaptureKitOwnerCapability)
        var inspectOwnerCalls = 0
        var localFactoryCalls = 0
        let legacyOwner = RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost(
            socketPath: "/tmp/unrelated-legacy-owner.sock",
            processIdentifier: nil,
            processStartIdentity: nil,
            buildIdentity: "legacy-build"
        )

        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: .init(
                makeLocalServices: { _ in
                    localFactoryCalls += 1
                    return PeekabooServices()
                },
                claimScreenCaptureKitOwner: { Self.ownerReceipt() },
                inspectScreenCaptureKitOwner: {
                    inspectOwnerCalls += 1
                    return nil
                },
                inspectScreenCaptureKitSafety: { _, _, _, _ in legacyOwner },
                remoteCandidatePlan: { _, _ in
                    RuntimeHostResolver.RemoteCandidatePlan(
                        explicitSocket: selectedSocket,
                        daemonSocketPath: "/tmp/peekaboo-unused-daemon.sock",
                        runtimeBuildIdentity: "current-build",
                        buildScopedDaemonSocketPath: nil,
                        historicalBuildScopedDaemonTargets: [],
                        historicalBuildScopedDaemonSocketPaths: [],
                        candidates: [.init(
                            socketPath: selectedSocket,
                            requireReusableDaemon: false,
                            requiredHostKind: nil,
                            requiresValidatedHistoricalDaemon: false
                        )]
                    )
                }
            )
        )

        #expect(resolution.selectedRemoteSocketPath == selectedSocket)
        #expect(inspectOwnerCalls == 1)
        #expect(localFactoryCalls == 0)
        let refusal = try #require(resolution.toolCapturePreflightRefusal)
        #expect(refusal.message.contains(selectedSocket))
        #expect(refusal.message.contains(legacyOwner.socketPath))
        #expect(refusal.message.contains("No capture was dispatched"))
        #expect(refusal.hint?.contains("Do not stop any process") == true)
        #expect(refusal.hint?.contains("start a fresh session") == true)
        await selectedHost.stop()
    }

    @Test
    func `explicit dynamic host remains fail closed when the selected socket is unavailable`() async throws {
        let selectedSocket = "/tmp/peekaboo-dynamic-missing-\(UUID().uuidString).sock"
        var options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["bridge-socket": [selectedSocket]],
                flags: []
            ),
            commandType: MCPCommand.Serve.self
        )
        options.autoStartDaemon = false
        var localFactoryCalls = 0

        let error = await #expect(throws: BridgeExplicitSocketUnavailableError.self) {
            _ = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: [:],
                configurationInput: nil,
                dependencies: .init(
                    makeLocalServices: { _ in
                        localFactoryCalls += 1
                        return PeekabooServices()
                    },
                    claimScreenCaptureKitOwner: { Self.ownerReceipt() },
                    inspectScreenCaptureKitOwner: { nil },
                    inspectScreenCaptureKitSafety: { _, _, _, _ in
                        RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost(
                            socketPath: "/tmp/unrelated-legacy-owner.sock",
                            processIdentifier: nil,
                            processStartIdentity: nil
                        )
                    },
                    remoteCandidatePlan: { _, _ in
                        RuntimeHostResolver.RemoteCandidatePlan(
                            explicitSocket: selectedSocket,
                            daemonSocketPath: "/tmp/peekaboo-unused-daemon.sock",
                            runtimeBuildIdentity: "current-build",
                            buildScopedDaemonSocketPath: nil,
                            historicalBuildScopedDaemonTargets: [],
                            historicalBuildScopedDaemonSocketPaths: [],
                            candidates: [.init(
                                socketPath: selectedSocket,
                                requireReusableDaemon: false,
                                requiredHostKind: nil,
                                requiresValidatedHistoricalDaemon: false
                            )]
                        )
                    }
                )
            )
        }

        #expect(error?.socketPath == selectedSocket)
        #expect(localFactoryCalls == 0)
    }

    @Test
    func `explicit verify screenshot inherits deferred capture refusal`() async throws {
        let selectedSocket = "/tmp/peekaboo-verify-selected-\(UUID().uuidString).sock"
        let selectedHost = try await Self.startHost(
            socketPath: selectedSocket,
            processIdentifier: 4242,
            processStartIdentity: 9001,
            codeSignatureHash: "selected-build"
        )
        defer { Task { await selectedHost.stop() } }

        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: [
                    "app": ["Finder"],
                    "bridge-socket": [selectedSocket],
                    "screenshot": ["/tmp/peekaboo-verify-never-written.png"],
                ],
                flags: ["window-exists"]
            ),
            commandType: VerifyCommand.self
        )
        #expect(options.bridgeSocketPath == selectedSocket)
        #expect(options.usesPerToolSnapshotInvalidation)

        let legacyOwner = RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost(
            socketPath: "/tmp/unrelated-legacy-owner.sock",
            processIdentifier: nil,
            processStartIdentity: nil,
            buildIdentity: "legacy-build"
        )
        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: .init(
                makeLocalServices: { _ in PeekabooServices() },
                claimScreenCaptureKitOwner: { Self.ownerReceipt() },
                inspectScreenCaptureKitOwner: { nil },
                inspectScreenCaptureKitSafety: { _, _, _, _ in legacyOwner },
                remoteCandidatePlan: { _, _ in
                    RuntimeHostResolver.RemoteCandidatePlan(
                        explicitSocket: selectedSocket,
                        daemonSocketPath: "/tmp/peekaboo-unused-daemon.sock",
                        runtimeBuildIdentity: "current-build",
                        buildScopedDaemonSocketPath: nil,
                        historicalBuildScopedDaemonTargets: [],
                        historicalBuildScopedDaemonSocketPaths: [],
                        candidates: [.init(
                            socketPath: selectedSocket,
                            requireReusableDaemon: false,
                            requiredHostKind: nil,
                            requiresValidatedHistoricalDaemon: false
                        )]
                    )
                }
            )
        )
        let refusal = try #require(resolution.toolCapturePreflightRefusal)
        let runtime = CommandRuntime(
            configuration: options.makeConfiguration(),
            services: resolution.services,
            hostDescription: resolution.hostDescription,
            selectedRemoteSocketPath: resolution.selectedRemoteSocketPath,
            selectedRemoteHostProcessIdentifier: resolution.selectedRemoteHostProcessIdentifier,
            captureEngineSafetyOverride: resolution.captureEngineSafetyOverride,
            toolCapturePreflightRefusal: refusal,
            snapshotInvalidationRemoteSocketPaths: resolution.snapshotInvalidationRemoteSocketPaths,
            applicationRelaunchAllowed: resolution.applicationRelaunchAllowed,
            requiredHostFailure: resolution.requiredHostFailure
        )
        let context = VerifyCommand.makeToolContext(using: runtime)
        let counter = VerifyCaptureInvocationCounter()
        let response = try await context.execute(
            tool: VerifyCaptureInvocationProbe(counter: counter),
            arguments: ToolArguments(value: .object(["final_screenshot": .bool(true)]))
        )

        #expect(response.isError)
        #expect(await !counter.wasInvoked)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["error_code"] == .string("CAPTURE_FAILED"))
        #expect(metadata["mutation_dispatched"] == .bool(false))
        #expect(metadata["retry_safe"] == .bool(true))

        let nonCaptureCounter = VerifyCaptureInvocationCounter()
        let nonCapture = try await context.execute(
            tool: VerifyCaptureInvocationProbe(counter: nonCaptureCounter),
            arguments: ToolArguments(value: .object(["final_screenshot": .bool(false)]))
        )
        #expect(!nonCapture.isError)
        #expect(await nonCaptureCounter.wasInvoked)
        await selectedHost.stop()
    }
}

private actor VerifyCaptureInvocationCounter {
    private var invoked = false

    var wasInvoked: Bool {
        self.invoked
    }

    func record() {
        self.invoked = true
    }
}

private struct VerifyCaptureInvocationProbe: MCPTool {
    let counter: VerifyCaptureInvocationCounter
    let name = "verify_state"
    let description = "Verify capture refusal probe"

    var inputSchema: Value {
        SchemaBuilder.object(
            properties: ["final_screenshot": SchemaBuilder.boolean()],
            required: []
        )
    }

    func execute(arguments _: ToolArguments) async throws -> ToolResponse {
        await self.counter.record()
        return ToolResponse.text("invoked")
    }
}
