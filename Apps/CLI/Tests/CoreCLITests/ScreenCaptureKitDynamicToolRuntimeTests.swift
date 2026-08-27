import Commander
import Foundation
import MCP
import PeekabooBridge
import PeekabooBridgeTestSupport
import PeekabooCore
import TachikomaMCP
import Testing
@testable import PeekabooCLI

extension ScreenCaptureKitOwnerRuntimeTests {
    @Test
    func `browser-only MCP runtime never consults an unrelated ScreenCaptureKit owner`() async throws {
        let buildScopedSocket = "/tmp/peekaboo-browser-only-build-\(UUID().uuidString).sock"
        var options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: MCPCommand.Serve.self,
            environment: ["PEEKABOO_ALLOW_TOOLS": "browser"]
        )
        options.autoStartDaemon = false
        var claimCalls = 0
        var inspectOwnerCalls = 0
        var inspectSafetyCalls = 0
        var localFactoryCalls = 0

        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: ["PEEKABOO_ALLOW_TOOLS": "browser"],
            configurationInput: nil,
            dependencies: .init(
                makeLocalServices: { _ in
                    localFactoryCalls += 1
                    return PeekabooServices()
                },
                claimScreenCaptureKitOwner: {
                    claimCalls += 1
                    return Self.ownerReceipt()
                },
                inspectScreenCaptureKitOwner: {
                    inspectOwnerCalls += 1
                    return Self.ownerReceipt()
                },
                inspectScreenCaptureKitSafety: { _, _, _, _ in
                    inspectSafetyCalls += 1
                    return RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost(
                        socketPath: "/tmp/unrelated-old-owner.sock",
                        processIdentifier: 28611,
                        processStartIdentity: 1_787_493_920_650_462,
                        buildIdentity: "unrelated-old-build"
                    )
                },
                remoteCandidatePlan: { _, _ in
                    RuntimeHostResolver.RemoteCandidatePlan(
                        explicitSocket: nil,
                        daemonSocketPath: "/tmp/peekaboo-browser-only-daemon.sock",
                        runtimeBuildIdentity: "browser-only-build",
                        buildScopedDaemonSocketPath: buildScopedSocket,
                        historicalBuildScopedDaemonSocketPaths: [],
                        candidates: [.init(
                            socketPath: buildScopedSocket,
                            requireReusableDaemon: true,
                            requiredHostKind: .onDemand,
                            requiresValidatedHistoricalDaemon: false
                        )]
                    )
                }
            )
        )

        #expect(resolution.selectedRemoteSocketPath == nil)
        #expect(resolution.toolCapturePreflightRefusal == nil)
        #expect(claimCalls == 0)
        #expect(inspectOwnerCalls == 0)
        #expect(inspectSafetyCalls == 0)
        #expect(localFactoryCalls == 1)
    }

    @Test
    func `capture-capable MCP runtime remains bound to the exact ScreenCaptureKit owner`() async throws {
        let buildScopedSocket = "/tmp/peekaboo-browser-capture-build-\(UUID().uuidString).sock"
        var options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: MCPCommand.Serve.self,
            environment: ["PEEKABOO_ALLOW_TOOLS": "browser,see"]
        )
        options.autoStartDaemon = false
        var claimCalls = 0
        var inspectOwnerCalls = 0
        var inspectSafetyCalls = 0
        var localFactoryCalls = 0

        let error = await #expect(throws: PreDispatchActionError.self) {
            _ = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: ["PEEKABOO_ALLOW_TOOLS": "browser,see"],
                configurationInput: nil,
                dependencies: .init(
                    makeLocalServices: { _ in
                        localFactoryCalls += 1
                        return PeekabooServices()
                    },
                    claimScreenCaptureKitOwner: {
                        claimCalls += 1
                        return Self.ownerReceipt()
                    },
                    inspectScreenCaptureKitOwner: {
                        inspectOwnerCalls += 1
                        return Self.ownerReceipt()
                    },
                    inspectScreenCaptureKitSafety: { _, _, _, _ in
                        inspectSafetyCalls += 1
                        return nil
                    },
                    remoteCandidatePlan: { _, _ in
                        RuntimeHostResolver.RemoteCandidatePlan(
                            explicitSocket: nil,
                            daemonSocketPath: "/tmp/peekaboo-browser-capture-daemon.sock",
                            runtimeBuildIdentity: "browser-capture-build",
                            buildScopedDaemonSocketPath: buildScopedSocket,
                            historicalBuildScopedDaemonSocketPaths: [],
                            candidates: [.init(
                                socketPath: buildScopedSocket,
                                requireReusableDaemon: true,
                                requiredHostKind: .onDemand,
                                requiresValidatedHistoricalDaemon: false
                            )]
                        )
                    }
                )
            )
        }

        #expect(error?.code == .CAPTURE_FAILED)
        #expect(error?.localizedDescription.contains(buildScopedSocket) == true)
        #expect(claimCalls == 0)
        #expect(inspectOwnerCalls == 1)
        #expect(inspectSafetyCalls == 1)
        #expect(localFactoryCalls == 0)
    }

    @Test
    func `explicit persistent capture safety is scoped to its selected socket`() {
        let selectedSocket = "/tmp/persistent-selected.sock"
        let plan = RuntimeHostResolver.RemoteCandidatePlan(
            explicitSocket: selectedSocket,
            daemonSocketPath: "/tmp/unrelated-daemon.sock",
            runtimeBuildIdentity: "fixture-build",
            buildScopedDaemonSocketPath: "/tmp/unrelated-build-daemon.sock",
            historicalBuildScopedDaemonSocketPaths: ["/tmp/unrelated-historical.sock"],
            candidates: [.init(
                socketPath: selectedSocket,
                requireReusableDaemon: false,
                requiredHostKind: nil,
                requiresValidatedHistoricalDaemon: false
            )]
        )
        var options = CommandRuntimeOptions()
        options.requiresAgentService = true
        options.usesPerToolSnapshotInvalidation = true

        let candidates = RuntimeHostResolver.screenCaptureKitSafetyCandidates(
            from: plan,
            options: options
        )

        #expect(candidates.map(\.socketPath) == [selectedSocket])
    }

    @Test
    func `one-shot and implicit capture safety retain broad legacy-owner discovery`() {
        let selectedSocket = "/tmp/one-shot-selected.sock"
        let daemonSocket = "/tmp/one-shot-daemon.sock"
        let buildSocket = "/tmp/one-shot-build-daemon.sock"
        let historicalSocket = "/tmp/one-shot-historical.sock"
        let plan = RuntimeHostResolver.RemoteCandidatePlan(
            explicitSocket: selectedSocket,
            daemonSocketPath: daemonSocket,
            runtimeBuildIdentity: "fixture-build",
            buildScopedDaemonSocketPath: buildSocket,
            historicalBuildScopedDaemonSocketPaths: [historicalSocket],
            candidates: [.init(
                socketPath: selectedSocket,
                requireReusableDaemon: false,
                requiredHostKind: nil,
                requiresValidatedHistoricalDaemon: false
            )]
        )

        let candidates = RuntimeHostResolver.screenCaptureKitSafetyCandidates(
            from: plan,
            options: CommandRuntimeOptions()
        ).map(\.socketPath)

        #expect(candidates.first == selectedSocket)
        #expect(candidates.contains(daemonSocket))
        #expect(candidates.contains(buildSocket))
        #expect(candidates.contains(historicalSocket))
        #expect(candidates.contains(PeekabooBridgeConstants.peekabooSocketPath))
        #expect(candidates.contains(PeekabooBridgeConstants.claudeSocketPath))
        #expect(candidates.contains(PeekabooBridgeConstants.clawdbotSocketPath))
        #expect(Set(candidates).count == candidates.count)
    }

    @Test
    func `explicit dynamic host ignores unrelated legacy owner and reuses selected generation`() async throws {
        let selectedSocket = "/tmp/peekaboo-dynamic-selected-\(UUID().uuidString).sock"
        let unrelatedSocket = "/tmp/peekaboo-dynamic-unrelated-\(UUID().uuidString).sock"
        var selectedHandshakeCount = 0
        var unrelatedHandshakeCount = 0
        let selectedHost = try await Self.startHost(
            socketPath: selectedSocket,
            processIdentifier: 4242,
            processStartIdentity: 9001,
            codeSignatureHash: "selected-build",
            maximumProtocolVersion: PeekabooBridgeConstants.protocolVersion,
            usesCurrentHostIdentity: true,
            permissionEvaluationObserver: { selectedHandshakeCount += 1 }
        )
        let unrelatedHost = try await Self.startHost(
            socketPath: unrelatedSocket,
            processIdentifier: 5151,
            processStartIdentity: 6161,
            codeSignatureHash: "legacy-build",
            ownerAware: false,
            permissionEvaluationObserver: { unrelatedHandshakeCount += 1 }
        )
        defer {
            Task {
                await selectedHost.stop()
                await unrelatedHost.stop()
            }
        }

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
        #expect(options.usesPersistentDynamicToolRuntime)
        #expect(!options.requiresScreenCaptureKitOwnerCapability)
        var inspectOwnerCalls = 0
        var localFactoryCalls = 0
        var inspectedCandidates: [String] = []

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
                inspectScreenCaptureKitSafety: { _, _, candidates, handshakeCache in
                    let candidates = try #require(candidates)
                    inspectedCandidates = candidates.map(\.socketPath)
                    return try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
                        candidates: candidates,
                        identity: handshakeCache.identity,
                        handshakeCache: handshakeCache,
                        externalHostPresence: { _ in .absent }
                    )
                },
                remoteCandidatePlan: { _, _ in
                    RuntimeHostResolver.RemoteCandidatePlan(
                        explicitSocket: selectedSocket,
                        daemonSocketPath: "/tmp/peekaboo-unused-daemon.sock",
                        runtimeBuildIdentity: "current-build",
                        buildScopedDaemonSocketPath: nil,
                        historicalBuildScopedDaemonSocketPaths: [],
                        candidates: [.init(
                            socketPath: selectedSocket,
                            requireReusableDaemon: false,
                            requiredHostKind: nil,
                            requiresValidatedHistoricalDaemon: false
                        )]
                    )
                },
                makeRemoteHandshakeCache: { Self.authenticatedHandshakeCache() }
            )
        )

        #expect(resolution.selectedRemoteSocketPath == selectedSocket)
        #expect(inspectOwnerCalls == 1)
        #expect(localFactoryCalls == 0)
        #expect(resolution.toolCapturePreflightRefusal == nil)
        #expect(inspectedCandidates == [selectedSocket])
        #expect(selectedHandshakeCount == 1)
        #expect(unrelatedHandshakeCount == 0)

        let permissions = try await resolution.services.permissionsStatus()
        #expect(permissions.screenRecording)
        #expect(selectedHandshakeCount == 2)
        #expect(unrelatedHandshakeCount == 0)
        await selectedHost.stop()
        await unrelatedHost.stop()
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
            codeSignatureHash: "selected-build",
            maximumProtocolVersion: PeekabooBridgeConstants.protocolVersion,
            usesCurrentHostIdentity: true
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
        let handshakeCache = Self.authenticatedHandshakeCache()
        let selectedCandidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: selectedSocket,
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )

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
                inspectScreenCaptureKitSafety: { _, _, _, cache in
                    _ = try await cache.handshake(selectedCandidate, identity: cache.identity)
                    return legacyOwner
                },
                remoteCandidatePlan: { _, _ in
                    RuntimeHostResolver.RemoteCandidatePlan(
                        explicitSocket: selectedSocket,
                        daemonSocketPath: "/tmp/peekaboo-unused-daemon.sock",
                        runtimeBuildIdentity: "current-build",
                        buildScopedDaemonSocketPath: nil,
                        historicalBuildScopedDaemonSocketPaths: [],
                        candidates: [selectedCandidate]
                    )
                },
                makeRemoteHandshakeCache: { handshakeCache }
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

    private static func authenticatedHandshakeCache() -> RuntimeHostResolver.RemoteHandshakeCache {
        RuntimeHostResolver.RemoteHandshakeCache(
            identity: PeekabooBridgeClientIdentity(
                bundleIdentifier: "boo.peekaboo.dynamic-snapshot-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()
            ),
            clientFactory: { BridgeTestFixtures.authenticatedClient(socketPath: $0) }
        )
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
