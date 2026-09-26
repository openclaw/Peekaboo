import Commander
import Darwin
import Foundation
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooBridgeTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct ExplicitSocketInputPolicyRuntimeTests {
    @Test(arguments: [false, true], PolicySource.allCases)
    func `explicit sockets refuse caller input policy before local construction`(
        environmentSocket: Bool,
        policy: PolicySource
    ) async throws {
        let fixture = Fixture()
        var environment: [String: String] = [:]
        var options = try self.clickOptions(environmentSocket: environmentSocket, environment: &environment)
        let configuration = policy.apply(options: &options, environment: &environment)

        let error = await #expect(throws: BridgeExplicitSocketUnavailableError.self) {
            _ = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: environment,
                configurationInput: configuration,
                dependencies: fixture.dependencies()
            )
        }

        #expect(options.requiresStatelessClickVariants)
        #expect(!options.requiresBackgroundStatelessClickVariants)
        #expect(error?.socketPath == Self.socket)
        #expect(error?.envelopeCode == .BRIDGE_UNAVAILABLE)
        #expect(error?.localizedDescription.contains("input strategy policy") == true)
        #expect(error?.envelopeHint?.contains("--no-remote") == true)
        #expect(fixture.localFactoryCalls == 0)
        #expect(fixture.handshakeFactoryCalls == 0)
        #expect(fixture.probedSockets.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func `explicit local opt-in wins over socket and input policy`(
        environmentSocket: Bool,
        environmentIsolation: Bool
    ) async throws {
        let fixture = Fixture()
        var environment: [String: String] = [:]
        var options = try self.clickOptions(environmentSocket: environmentSocket, environment: &environment)
        options.inputStrategy = .synthOnly
        if environmentIsolation {
            environment["PEEKABOO_NO_REMOTE"] = "1"
        } else {
            options.remoteIsolationRequested = true
            options.preferRemote = false
        }

        let result = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: environment,
            configurationInput: nil,
            dependencies: fixture.dependencies()
        )

        #expect(result.selectedRemoteSocketPath == nil)
        #expect(result.requiredHostFailure == nil)
        #expect(result.snapshotInvalidationRemoteSocketPaths.isEmpty)
        #expect(fixture.localFactoryCalls == 1)
        #expect(fixture.candidatePlanCalls == 0)
        #expect(fixture.handshakeFactoryCalls == 0)
    }

    @Test(arguments: PolicySource.allCases)
    func `implicit policy-local routing retains snapshot invalidation endpoints`(policy: PolicySource) async throws {
        let fixture = Fixture()
        var environment: [String: String] = [:]
        var options = try self.clickOptions(environmentSocket: false, environment: &environment)
        options.bridgeSocketPath = nil
        let configuration = policy.apply(options: &options, environment: &environment)

        let result = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: environment,
            configurationInput: configuration,
            dependencies: fixture.dependencies()
        )

        #expect(result.selectedRemoteSocketPath == nil)
        #expect(result.requiredHostFailure == nil)
        #expect(result.snapshotInvalidationRemoteSocketPaths.contains("/synthetic/daemon.sock"))
        #expect(fixture.localFactoryCalls == 1)
        #expect(fixture.handshakeFactoryCalls == 0)
    }

    @Test(arguments: ObservationCommand.allCases, [false, true])
    func `observation commands refuse explicit sockets with caller input policy`(
        command: ObservationCommand,
        environmentSocket: Bool
    ) async throws {
        for policy in PolicySource.allCases {
            let fixture = Fixture(allowsCapturePreflight: true)
            var environment: [String: String] = [:]
            var options = try self.observationOptions(
                command, environmentSocket: environmentSocket, environment: &environment
            )
            let configuration = policy.apply(options: &options, environment: &environment)

            let error = await #expect(throws: BridgeExplicitSocketUnavailableError.self) {
                _ = try await RuntimeHostResolver.resolveServices(
                    options: options,
                    environment: environment,
                    configurationInput: configuration,
                    dependencies: fixture.dependencies()
                )
            }

            #expect(options.captureEnginePreference == nil)
            #expect(options.requiresScreenCapturePermission)
            #expect(error?.socketPath == Self.socket)
            #expect(error?.envelopeCode == .BRIDGE_UNAVAILABLE)
            #expect(error?.localizedDescription.contains("input strategy policy") == true)
            #expect(fixture.localFactoryCalls == 0)
            #expect(fixture.candidatePlanCalls == 1)
            #expect(fixture.handshakeFactoryCalls == 1)
            #expect(fixture.captureSafetyInspections == 1)
            #expect(fixture.captureOwnerInspections == (command == .see ? 1 : 0))
            #expect(fixture.handshakeCalls == (command == .see ? 1 : 0))
            #expect(fixture.probedSockets.isEmpty)
        }
    }

    @Test(arguments: [ObservationCommand.live, .action], ["auto", "classic", "modern"])
    func `explicit capture engines do not bypass selected socket input policy conflicts`(
        command: ObservationCommand,
        engine: String
    ) async throws {
        for policy in PolicySource.allCases {
            let fixture = Fixture(allowsCapturePreflight: true)
            var environment: [String: String] = [:]
            var options = try self.observationOptions(
                command, environmentSocket: false, engine: engine, environment: &environment
            )
            let configuration = policy.apply(options: &options, environment: &environment)

            let error = await #expect(throws: BridgeExplicitSocketUnavailableError.self) {
                _ = try await RuntimeHostResolver.resolveServices(
                    options: options,
                    environment: environment,
                    configurationInput: configuration,
                    dependencies: fixture.dependencies()
                )
            }

            #expect(options.requiresDesktopObservationInlinePixels)
            #expect(error?.socketPath == Self.socket)
            #expect(error?.localizedDescription.contains("input strategy policy") == true)
            #expect(fixture.localFactoryCalls == 0)
            #expect(fixture.probedSockets.isEmpty)
        }
    }

    @Test(arguments: ObservationCommand.allCases, PolicySource.allCases)
    func `observation commands retain implicit policy-local execution`(
        command: ObservationCommand,
        policy: PolicySource
    ) async throws {
        let fixture = Fixture(allowsCapturePreflight: true)
        var environment: [String: String] = [:]
        var options = try self.observationOptions(command, environmentSocket: false, environment: &environment)
        options.bridgeSocketPath = nil
        let configuration = policy.apply(options: &options, environment: &environment)

        let result = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: environment,
            configurationInput: configuration,
            dependencies: fixture.dependencies()
        )

        #expect(result.selectedRemoteSocketPath == nil)
        #expect(result.requiredHostFailure == nil)
        #expect(result.snapshotInvalidationRemoteSocketPaths.contains("/synthetic/daemon.sock"))
        #expect(fixture.localFactoryCalls == 1)
        #expect(fixture.captureSafetyInspections == 1)
        #expect(fixture.captureOwnerInspections == (command == .see ? 1 : 0))
        #expect(fixture.handshakeCalls == 0)
        #expect(fixture.probedSockets.isEmpty)
    }

    @Test(arguments: ObservationCommand.allCases, [false, true])
    func `observation local opt-in wins over explicit sockets and input policy`(
        command: ObservationCommand,
        environmentIsolation: Bool
    ) async throws {
        for environmentSocket in [false, true] {
            let fixture = Fixture(allowsCapturePreflight: true)
            var environment: [String: String] = [:]
            if environmentIsolation {
                environment["PEEKABOO_NO_REMOTE"] = "1"
            }
            var options = try self.observationOptions(
                command,
                environmentSocket: environmentSocket,
                flags: environmentIsolation ? [] : ["no-remote"],
                environment: &environment
            )
            options.inputStrategy = .synthOnly

            let result = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: environment,
                configurationInput: nil,
                dependencies: fixture.dependencies()
            )

            #expect(result.selectedRemoteSocketPath == nil)
            #expect(result.requiredHostFailure == nil)
            #expect(result.snapshotInvalidationRemoteSocketPaths.isEmpty)
            #expect(fixture.localFactoryCalls == 1)
            #expect(fixture.captureSafetyInspections == 1)
            #expect(fixture.captureOwnerInspections == 0)
            #expect(fixture.handshakeCalls == 0)
            #expect(fixture.probedSockets.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func `concrete modifier and pixel-focus snapshots keep their explicit producer route`(
        pixelFocus: Bool
    ) async throws {
        let fixture = Fixture()
        fixture.probeResult = .owner
        var options = self.snapshotOptions(pixelFocus: pixelFocus)
        options.inputStrategy = .synthOnly

        let result = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: fixture.dependencies()
        )

        #expect(result.selectedRemoteSocketPath == Self.socket)
        #expect(result.requiredHostFailure == nil)
        #expect(fixture.localFactoryCalls == 0)
        #expect(fixture.probedSockets == [Self.socket])
        #expect(fixture.handshakeCalls == 1)
    }

    @Test(arguments: [
        RuntimeHostResolver.SnapshotAffinityProbeResult.missing,
        .unavailable,
        .incompatible,
    ])
    func `concrete snapshot failures retain affinity errors without local fallback`(
        probeResult: RuntimeHostResolver.SnapshotAffinityProbeResult
    ) async {
        let fixture = Fixture()
        fixture.probeResult = probeResult
        var options = self.snapshotOptions(pixelFocus: false)
        options.inputStrategy = .synthOnly

        let error = await #expect(throws: PreDispatchActionError.self) {
            _ = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: [:],
                configurationInput: nil,
                dependencies: fixture.dependencies()
            )
        }

        #expect(error?.code == .SNAPSHOT_NOT_FOUND)
        #expect(fixture.localFactoryCalls == 0)
        #expect(fixture.probedSockets == [Self.socket])
        #expect(fixture.handshakeCalls == 0)
    }

    @Test
    func `latest snapshot does not bypass the input policy conflict`() async throws {
        let fixture = Fixture()
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: [
                    "at": ["100,200"],
                    "snapshot": ["latest"],
                    "bridge-socket": [Self.socket],
                    "inputStrategy": ["actionOnly"]
                ],
                flags: ["foreground"]
            ),
            commandType: ClickCommand.self,
            environment: [:]
        )

        #expect(options.explicitSnapshotID == nil)
        await #expect(throws: BridgeExplicitSocketUnavailableError.self) {
            _ = try await RuntimeHostResolver.resolveServices(
                options: options, environment: [:], configurationInput: nil, dependencies: fixture.dependencies()
            )
        }
        #expect(fixture.localFactoryCalls == 0)
        #expect(fixture.handshakeFactoryCalls == 0)
    }

    @Test(arguments: [false, true])
    func `local snapshot opt-in checks only caller ownership`(pixelFocus: Bool) async throws {
        let fixture = Fixture()
        var options = self.snapshotOptions(pixelFocus: pixelFocus)
        options.explicitSnapshotID = try await fixture.snapshots.createSnapshot()
        options.inputStrategy = .synthOnly
        options.remoteIsolationRequested = true
        options.preferRemote = false

        let result = try await RuntimeHostResolver.resolveServices(
            options: options, environment: [:], configurationInput: nil, dependencies: fixture.dependencies()
        )

        #expect(result.selectedRemoteSocketPath == nil)
        #expect(result.requiredHostFailure == nil)
        #expect(fixture.localFactoryCalls == 1)
        #expect(fixture.candidatePlanCalls == 0)
        #expect(fixture.handshakeCalls == 0)
        #expect(fixture.probedSockets.isEmpty)
    }

    @Test
    func `malformed concrete snapshot retains affinity validation`() async {
        let fixture = Fixture()
        var options = self.snapshotOptions(pixelFocus: false)
        options.explicitSnapshotID = "invalid"
        options.inputStrategy = .synthOnly

        let error = await #expect(throws: PreDispatchActionError.self) {
            _ = try await RuntimeHostResolver.resolveServices(
                options: options, environment: [:], configurationInput: nil, dependencies: fixture.dependencies()
            )
        }

        #expect(error?.code == .VALIDATION_ERROR)
        #expect(fixture.localFactoryCalls == 0)
        #expect(fixture.handshakeCalls == 0)
        #expect(fixture.probedSockets.isEmpty)
    }

    @Test
    func `Bridge diagnostics retain their local reporting escape hatch`() async throws {
        let fixture = Fixture()
        var options = CommandRuntimeOptions()
        options.bridgeSocketPath = Self.socket
        options.inputStrategy = .synthOnly
        options.permitsExplicitSocketDiagnosticFallback = true

        let result = try await RuntimeHostResolver.resolveServices(
            options: options, environment: [:], configurationInput: nil, dependencies: fixture.dependencies()
        )

        #expect(result.selectedRemoteSocketPath == nil)
        #expect(fixture.localFactoryCalls == 1)
        #expect(fixture.handshakeFactoryCalls == 0)
    }

    private static let socket = "/synthetic/selected.sock"

    private func clickOptions(
        environmentSocket: Bool,
        environment: inout [String: String]
    ) throws -> CommandRuntimeOptions {
        var values = ["at": ["100,200"]]
        if environmentSocket {
            environment["PEEKABOO_BRIDGE_SOCKET"] = Self.socket
        } else {
            values["bridge-socket"] = [Self.socket]
        }
        return try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: values, flags: ["foreground", "middle"]),
            commandType: ClickCommand.self,
            environment: environment
        )
    }

    private func snapshotOptions(pixelFocus: Bool) -> CommandRuntimeOptions {
        var options = CommandRuntimeOptions()
        options.bridgeSocketPath = Self.socket
        options.explicitSnapshotID = "ps1_11111111111111111111111111111111"
        options.requiresForegroundModifierClickSnapshotLease = !pixelFocus
        options.requiresExactWindowPixelFocusTyping = pixelFocus
        return options
    }

    private func observationOptions(
        _ command: ObservationCommand,
        environmentSocket: Bool,
        engine: String? = nil,
        flags: Set<String> = [],
        environment: inout [String: String]
    ) throws -> CommandRuntimeOptions {
        var values: [String: [String]] = [:]
        if let engine {
            values["captureEngine"] = [engine]
        }
        if environmentSocket {
            environment["PEEKABOO_BRIDGE_SOCKET"] = Self.socket
        } else {
            values["bridge-socket"] = [Self.socket]
        }
        let commandType: any ParsableCommand.Type = switch command {
        case .see: SeeCommand.self
        case .live: CaptureLiveCommand.self
        case .action: CaptureActionCommand.self
        }
        return try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: values, flags: flags),
            commandType: commandType,
            environment: environment
        )
    }

    enum ObservationCommand: CaseIterable {
        case see, live, action
    }

    enum PolicySource: CaseIterable {
        case cli, environmentDefault, environmentVerb, configDefault, configVerb, configApp

        func apply(
            options: inout CommandRuntimeOptions,
            environment: inout [String: String]
        ) -> Configuration.InputConfig? {
            switch self {
            case .cli:
                options.inputStrategy = .synthOnly
            case .environmentDefault:
                environment["PEEKABOO_INPUT_STRATEGY"] = "synthOnly"
            case .environmentVerb:
                environment["PEEKABOO_CLICK_INPUT_STRATEGY"] = "synthOnly"
            case .configDefault:
                return .init(defaultStrategy: .synthOnly)
            case .configVerb:
                return .init(click: .synthOnly)
            case .configApp:
                return .init(perApp: ["boo.peekaboo.fixture": .init(click: .synthOnly)])
            }
            return nil
        }
    }

    @MainActor
    private final class Fixture {
        let snapshots = InMemorySnapshotManager()
        let allowsCapturePreflight: Bool
        var localFactoryCalls = 0
        var candidatePlanCalls = 0
        var handshakeFactoryCalls = 0
        var handshakeCalls = 0
        var captureOwnerInspections = 0
        var captureSafetyInspections = 0
        var probedSockets: [String] = []
        var probeResult: RuntimeHostResolver.SnapshotAffinityProbeResult = .missing

        init(allowsCapturePreflight: Bool = false) {
            self.allowsCapturePreflight = allowsCapturePreflight
        }

        func dependencies() -> RuntimeHostResolver.Dependencies {
            ScreenCaptureKitOwnerRuntimeTests.inertDependencies(
                makeLocalServices: { _ in
                    self.localFactoryCalls += 1
                    return OwnerPolicyFixtureServices(ownerAware: true, snapshots: self.snapshots)
                },
                claimScreenCaptureKitOwner: { fatalError("Input routing must not claim capture ownership") },
                inspectScreenCaptureKitOwner: {
                    guard self.allowsCapturePreflight else { fatalError("Unexpected capture ownership inspection") }
                    self.captureOwnerInspections += 1
                    return nil
                },
                inspectScreenCaptureKitSafety: { _, _, _, _ in
                    guard self.allowsCapturePreflight else { fatalError("Unexpected capture safety inspection") }
                    self.captureSafetyInspections += 1
                    return nil
                },
                remoteCandidatePlan: { options, environment in
                    self.candidatePlanCalls += 1
                    let socket = BridgeSocketResolver.explicitBridgeSocket(options: options, environment: environment)
                    return .init(
                        explicitSocket: socket,
                        daemonSocketPath: "/synthetic/daemon.sock",
                        runtimeBuildIdentity: "fixture",
                        buildScopedDaemonSocketPath: nil,
                        historicalBuildScopedDaemonSocketPaths: [],
                        candidates: socket.map { [.init(
                            socketPath: $0,
                            requireReusableDaemon: false,
                            requiredHostKind: nil,
                            requiresValidatedHistoricalDaemon: false
                        )] } ?? []
                    )
                },
                makeRemoteHandshakeCache: {
                    self.handshakeFactoryCalls += 1
                    return RuntimeHostResolver.RemoteHandshakeCache(
                        identity: .init(
                            bundleIdentifier: "boo.peekaboo.test.client",
                            teamIdentifier: nil,
                            processIdentifier: getpid()
                        ),
                        handshakeProvider: { _, _ in
                            self.handshakeCalls += 1
                            return BridgeTestFixtures.handshake(
                                negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
                                supportedOperations: [.foregroundModifierClick, .exactWindowPixelFocusType],
                                hostCapabilities: [PeekabooBridgeHostCapability.foregroundModifierClickSnapshotLease]
                            )
                        }
                    )
                },
                snapshotAffinityProbe: { candidate, _, _, _ in
                    self.probedSockets.append(candidate.socketPath)
                    return self.probeResult
                }
            )
        }
    }
}
