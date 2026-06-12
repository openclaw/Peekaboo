import Darwin
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import Tachikoma
import Testing
@testable import PeekabooCLI

struct CommandRuntimeInjectionTests {
    @Test
    @MainActor
    func `uses the injected service provider`() {
        let services = RecordingPeekabooServices()
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: services
        )
        #expect(services.ensureVisualizerConnectionCallCount == 1)
        #expect(runtime.services is RecordingPeekabooServices)
    }

    @Test
    @MainActor
    func `installs MCP/tool defaults when constructed`() {
        let services = RecordingPeekabooServices()
        _ = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: services
        )

        let context = MCPToolContext.shared
        #expect(ObjectIdentifier(context.snapshots as AnyObject) ==
            ObjectIdentifier(services.snapshots as AnyObject))

        let tools = ToolRegistry.allTools()
        #expect(!tools.isEmpty)
    }

    @Test
    @MainActor
    func `aligns Tachikoma profile directory with Peekaboo`() {
        let previousProfile = TachikomaConfiguration.profileDirectoryName
        defer { TachikomaConfiguration.profileDirectoryName = previousProfile }

        TachikomaConfiguration.profileDirectoryName = ".tachikoma"
        let services = RecordingPeekabooServices()
        _ = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: services
        )

        #expect(TachikomaConfiguration.profileDirectoryPath == PeekabooCore.ConfigurationManager.baseDir)
    }

    @Test
    func `targeted hotkey support requires enabled bridge operation`() {
        let supported = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 1),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedHotkey],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: false
            ),
            enabledOperations: [.captureScreen],
            permissionTags: [
                PeekabooBridgeOperation.targetedHotkey.rawValue: [.postEvent],
            ]
        )

        let enabled = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 1),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedHotkey],
            enabledOperations: [.captureScreen, .targetedHotkey]
        )

        #expect(!CommandRuntime.supportsTargetedHotkeys(for: supported))
        #expect(CommandRuntime.supportsTargetedHotkeys(for: enabled))

        let availability = CommandRuntime.targetedHotkeyAvailability(for: supported)
        #expect(availability.unavailableReason?.contains("Event Synthesizing") == true)
        #expect(availability.missingPermissions == [.postEvent])
    }

    @Test
    func `targeted hotkey availability does not require accessibility`() {
        let handshake = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 1),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.targetedHotkey],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: false,
                postEvent: true
            ),
            enabledOperations: [.targetedHotkey],
            permissionTags: [
                PeekabooBridgeOperation.targetedHotkey.rawValue: [.postEvent],
            ]
        )

        #expect(CommandRuntime.supportsTargetedHotkeys(for: handshake))
        let availability = CommandRuntime.targetedHotkeyAvailability(for: handshake)
        #expect(availability.isEnabled)
        #expect(availability.unavailableReason == nil)
        #expect(availability.missingPermissions.isEmpty)
    }

    @Test
    func `targeted type support requires protocol 1_8 and enabled bridge operation`() {
        let supported = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 8),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedTypeActions],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: false
            ),
            enabledOperations: [.captureScreen],
            permissionTags: [
                PeekabooBridgeOperation.targetedTypeActions.rawValue: [.postEvent],
            ]
        )

        let enabled = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 8),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedTypeActions],
            enabledOperations: [.captureScreen, .targetedTypeActions]
        )

        let oldProtocol = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 7),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedTypeActions],
            enabledOperations: [.captureScreen, .targetedTypeActions]
        )

        #expect(!CommandRuntime.supportsTargetedTypeActions(for: supported))
        #expect(CommandRuntime.supportsTargetedTypeActions(for: enabled))
        #expect(!CommandRuntime.supportsTargetedTypeActions(for: oldProtocol))

        let availability = CommandRuntime.targetedTypeAvailability(for: supported)
        #expect(availability.unavailableReason?.contains("Event Synthesizing") == true)
        #expect(availability.missingPermissions == [.postEvent])
    }

    @Test
    func `targeted click support requires enabled bridge operation`() {
        let supported = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 6),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedClick],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: false
            ),
            enabledOperations: [.captureScreen],
            permissionTags: [
                PeekabooBridgeOperation.targetedClick.rawValue: [.postEvent],
            ]
        )

        let enabled = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 6),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedClick],
            enabledOperations: [.captureScreen, .targetedClick]
        )

        #expect(!CommandRuntime.supportsTargetedClicks(for: supported))
        #expect(CommandRuntime.supportsTargetedClicks(for: enabled))

        let availability = CommandRuntime.targetedClickAvailability(for: supported)
        #expect(availability.unavailableReason?.contains("Event Synthesizing") == true)
        #expect(availability.missingPermissions == [.postEvent])
    }

    @Test
    func `post event permission request support requires advertised protocol operation`() {
        let supported = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 2),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .requestPostEventPermission]
        )
        let older = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 1),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .requestPostEventPermission]
        )
        let hidden = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 2),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen]
        )

        #expect(CommandRuntime.supportsPostEventPermissionRequest(for: supported))
        #expect(!CommandRuntime.supportsPostEventPermissionRequest(for: older))
        #expect(!CommandRuntime.supportsPostEventPermissionRequest(for: hidden))
    }

    @Test
    func `desktop observation support requires advertised protocol operation`() {
        let supported = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 5),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .desktopObservation]
        )
        let older = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 4),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .desktopObservation]
        )
        let hidden = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 5),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen]
        )

        #expect(CommandRuntime.supportsDesktopObservation(for: supported))
        #expect(!CommandRuntime.supportsDesktopObservation(for: older))
        #expect(!CommandRuntime.supportsDesktopObservation(for: hidden))
    }

    @Test
    func `inspect UI support requires advertised protocol operation`() {
        let supported = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 7),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .inspectAccessibilityTree]
        )
        let older = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 6),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .inspectAccessibilityTree]
        )
        let hidden = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 7),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen]
        )

        #expect(CommandRuntime.supportsInspectAccessibilityTree(for: supported))
        #expect(!CommandRuntime.supportsInspectAccessibilityTree(for: older))
        #expect(!CommandRuntime.supportsInspectAccessibilityTree(for: hidden))
    }

    @Test
    func `remote requirements reject inspect UI when required capability is unavailable`() {
        var options = CommandRuntimeOptions()
        options.requiresInspectAccessibilityTree = true
        let supported = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 7),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .inspectAccessibilityTree]
        )
        let unsupported = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 6),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .inspectAccessibilityTree]
        )

        #expect(CommandRuntime.supportsRemoteRequirements(for: supported, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: unsupported, options: options))
    }

    @Test
    func `remote requirements reject browser MCP when required capability is unavailable`() {
        var options = CommandRuntimeOptions()
        options.requiresBrowserMCP = true
        let supported = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 4),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .browserStatus, .browserConnect, .browserDisconnect, .browserExecute]
        )
        let older = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 3),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .browserStatus, .browserConnect, .browserDisconnect, .browserExecute]
        )
        let missingExecute = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 4),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .browserStatus, .browserConnect, .browserDisconnect]
        )

        #expect(CommandRuntime.supportsBrowserMCP(for: supported))
        #expect(!CommandRuntime.supportsBrowserMCP(for: older))
        #expect(!CommandRuntime.supportsBrowserMCP(for: missingExecute))
        #expect(CommandRuntime.supportsRemoteRequirements(for: supported, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: older, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: missingExecute, options: options))
    }

    @Test
    func `environment bridge socket disables daemon auto start`() {
        let options = CommandRuntimeOptions()
        let environment = ["PEEKABOO_BRIDGE_SOCKET": "/tmp/explicit.sock"]

        #expect(CommandRuntime.explicitBridgeSocket(options: options, environment: environment) == "/tmp/explicit.sock")
        #expect(!CommandRuntime.shouldAutoStartDaemon(options: options, environment: environment))
    }

    @Test
    func `cli bridge socket takes precedence over environment bridge socket`() {
        var options = CommandRuntimeOptions()
        options.bridgeSocketPath = "/tmp/cli.sock"
        let environment = ["PEEKABOO_BRIDGE_SOCKET": "/tmp/env.sock"]

        #expect(CommandRuntime.explicitBridgeSocket(options: options, environment: environment) == "/tmp/cli.sock")
        #expect(!CommandRuntime.shouldAutoStartDaemon(options: options, environment: environment))
    }

    @Test
    func `daemon socket environment configures auto start target without becoming explicit bridge socket`() {
        let options = CommandRuntimeOptions()
        let environment = ["PEEKABOO_DAEMON_SOCKET": "/tmp/daemon.sock"]

        #expect(CommandRuntime.explicitBridgeSocket(options: options, environment: environment) == nil)
        #expect(CommandRuntime.daemonSocketPath(environment: environment) == "/tmp/daemon.sock")
        #expect(CommandRuntime.shouldAutoStartDaemon(options: options, environment: environment))
    }

    @Test
    func `daemon defaults to its dedicated socket`() {
        #expect(CommandRuntime.daemonSocketPath(environment: [:]) == PeekabooBridgeConstants.daemonSocketPath)
        #expect(CommandRuntime.daemonSocketPath(environment: [:]) != PeekabooBridgeConstants.peekabooSocketPath)
        #expect(DaemonLaunchPolicy.shouldMigrateLegacyDaemon(
            targetSocketPath: PeekabooBridgeConstants.daemonSocketPath
        ))
        #expect(!DaemonLaunchPolicy.shouldMigrateLegacyDaemon(targetSocketPath: "/tmp/custom-daemon.sock"))
    }

    @Test
    func `implicit runtime candidates preserve the default app fallback only`() {
        #expect(DaemonLaunchPolicy.implicitRuntimeCandidateRole(
            socketPath: PeekabooBridgeConstants.daemonSocketPath,
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath
        ) == .reusableDaemon)
        #expect(DaemonLaunchPolicy.implicitRuntimeCandidateRole(
            socketPath: PeekabooBridgeConstants.peekabooSocketPath,
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath
        ) == .defaultAppFallback)
        #expect(DaemonLaunchPolicy.implicitRuntimeCandidateRole(
            socketPath: PeekabooBridgeConstants.peekabooSocketPath,
            daemonSocketPath: "/tmp/custom-daemon.sock"
        ) == nil)
    }

    @Test
    func `default app fallback accepts GUI hosts and legacy daemons`() {
        let guiHandshake = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen]
        )
        let daemonHandshake = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen]
        )
        let embeddedHandshake = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .inProcess,
            build: nil,
            supportedOperations: [.captureScreen]
        )
        let daemonStatus = PeekabooDaemonStatus(running: true, mode: .auto)

        #expect(DaemonLaunchPolicy.isSelectableImplicitRuntimeCandidate(
            role: .defaultAppFallback,
            handshake: guiHandshake,
            daemonStatus: nil
        ))
        #expect(DaemonLaunchPolicy.isSelectableImplicitRuntimeCandidate(
            role: .defaultAppFallback,
            handshake: daemonHandshake,
            daemonStatus: daemonStatus
        ))
        #expect(!DaemonLaunchPolicy.isSelectableImplicitRuntimeCandidate(
            role: .defaultAppFallback,
            handshake: embeddedHandshake,
            daemonStatus: nil
        ))
        #expect(!DaemonLaunchPolicy.isSelectableImplicitRuntimeCandidate(
            role: .reusableDaemon,
            handshake: guiHandshake,
            daemonStatus: nil
        ))
    }

    @Test
    func `bridge diagnostics select only runtime-routed sockets`() {
        let options = CommandRuntimeOptions()
        let environment = ["PEEKABOO_DAEMON_SOCKET": "/tmp/custom-daemon.sock"]

        #expect(BridgeDiagnostics.runtimeCandidateSocketPaths(
            runtimeOptions: options,
            environment: environment
        ) == ["/tmp/custom-daemon.sock"])

        let diagnosticPaths = BridgeDiagnostics.diagnosticSocketPaths(
            runtimeOptions: options,
            environment: environment
        )
        #expect(diagnosticPaths.first == "/tmp/custom-daemon.sock")
        #expect(diagnosticPaths.contains(PeekabooBridgeConstants.peekabooSocketPath))
        #expect(diagnosticPaths.contains(PeekabooBridgeConstants.claudeSocketPath))
    }

    @Test
    func `default bridge diagnostics include the legacy runtime fallback`() {
        let runtimePaths = BridgeDiagnostics.runtimeCandidateSocketPaths(
            runtimeOptions: CommandRuntimeOptions(),
            environment: [:]
        )

        #expect(runtimePaths == [
            PeekabooBridgeConstants.daemonSocketPath,
            PeekabooBridgeConstants.peekabooSocketPath,
        ])
    }

    @Test
    func `explicit bridge diagnostics probe only the explicit runtime socket`() {
        var options = CommandRuntimeOptions()
        options.bridgeSocketPath = "/tmp/explicit.sock"

        #expect(BridgeDiagnostics.diagnosticSocketPaths(
            runtimeOptions: options,
            environment: ["PEEKABOO_DAEMON_SOCKET": "/tmp/ignored.sock"]
        ) == ["/tmp/explicit.sock"])
    }

    @Test
    func `on demand daemon arguments use auto mode and idle timeout`() {
        let args = CommandRuntime.onDemandDaemonArguments(socketPath: "/tmp/daemon.sock", idleTimeoutSeconds: 12.5)

        #expect(args.contains("auto"))
        #expect(args.contains("/tmp/daemon.sock"))
        #expect(args.contains("--idle-timeout-seconds"))
        #expect(args.contains("12.500"))
    }

    @Test
    func `manual daemon migration preserves mode without idle timeout`() {
        let args = DaemonLaunchPolicy.daemonArguments(
            socketPath: "/tmp/daemon.sock",
            mode: .manual,
            pollIntervalMs: 375,
            idleTimeoutSeconds: 12.5
        )

        #expect(args.contains("manual"))
        #expect(args.contains("--poll-interval-ms"))
        #expect(args.contains("375"))
        #expect(!args.contains("--idle-timeout-seconds"))
    }

    @Test
    func `automatic daemon migration preserves live settings`() {
        let status = PeekabooDaemonStatus(
            running: true,
            mode: .auto,
            windowTracker: PeekabooDaemonWindowTrackerStatus(
                trackedWindows: 1,
                lastEventAt: nil,
                lastPollAt: nil,
                axObserverCount: 1,
                cgPollIntervalMs: 425
            ),
            activity: PeekabooDaemonActivityStatus(
                activeRequests: 0,
                lastActivityAt: nil,
                idleTimeoutSeconds: 47.5,
                idleExitAt: nil
            ),
            supportsConditionalStop: true
        )

        let args = DaemonLaunchPolicy.migratedDaemonArguments(
            socketPath: "/tmp/daemon.sock",
            status: status,
            fallbackIdleTimeoutSeconds: 300
        )

        #expect(args?.contains("auto") == true)
        #expect(args?.contains("425") == true)
        #expect(args?.contains("47.500") == true)
    }

    @Test
    func `daemon startup waits for a draining lease`() async throws {
        let socketPath = "/tmp/peekaboo-daemon-wait-\(UUID().uuidString).sock"
        let leasePath = "\(socketPath).lock"
        let leaseFD = open(
            leasePath,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        #expect(leaseFD >= 0)
        defer {
            if leaseFD >= 0 {
                flock(leaseFD, LOCK_UN)
                close(leaseFD)
            }
            unlink(leasePath)
        }
        #expect(flock(leaseFD, LOCK_EX | LOCK_NB) == 0)

        let waitTask = Task {
            await DaemonLaunchPolicy.waitForDaemonSocketAvailability(
                socketPath: socketPath,
                client: DaemonControlClient(socketPath: socketPath),
                timeout: 1
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(flock(leaseFD, LOCK_UN) == 0)

        #expect(await waitTask.value == .available)
    }

    @Test
    @MainActor
    func `replacement rollback retries after active work drains`() async throws {
        let socketPath = "/tmp/peekaboo-daemon-rollback-\(UUID().uuidString).sock"
        defer {
            unlink(socketPath)
            unlink("\(socketPath).lock")
        }
        let daemon = PeekabooDaemon(configuration: .init(
            mode: .manual,
            bridgeSocketPath: socketPath,
            allowlistedTeams: [],
            windowTrackingEnabled: false,
            hostKind: .onDemand
        ))
        try await daemon.startChecked()
        #expect(await daemon.admitActivity(operation: .captureScreen))

        let status = await daemon.daemonStatus()
        let rollbackTask = Task {
            await DaemonLaunchPolicy.stopReplacement(
                client: DaemonControlClient(socketPath: socketPath),
                replacement: .init(status: status, processID: getpid())
            )
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        await daemon.recordActivityEnd(operation: .captureScreen)

        #expect(await rollbackTask.value)
        await daemon.waitUntilStopped()
    }

    @Test
    func `daemon idle timeout environment falls back to default for invalid values`() {
        #expect(CommandRuntime.daemonIdleTimeoutSeconds(environment: [:]) ==
            CommandRuntime.defaultDaemonIdleTimeoutSeconds)
        #expect(CommandRuntime.daemonIdleTimeoutSeconds(environment: [
            "PEEKABOO_DAEMON_IDLE_TIMEOUT_SECONDS": "0",
        ]) == CommandRuntime.defaultDaemonIdleTimeoutSeconds)
        #expect(CommandRuntime.daemonIdleTimeoutSeconds(environment: [
            "PEEKABOO_DAEMON_IDLE_TIMEOUT_SECONDS": "42.5",
        ]) == 42.5)
    }

    @Test
    func `daemon log helper creates missing file and appends`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-daemon-log-\(UUID().uuidString)")
        let logURL = directory.appendingPathComponent("daemon.log")

        let firstHandle = try #require(DaemonPaths.openFileForAppend(at: logURL))
        try firstHandle.write(contentsOf: Data("first\n".utf8))
        try firstHandle.close()

        let secondHandle = try #require(DaemonPaths.openFileForAppend(at: logURL))
        try secondHandle.write(contentsOf: Data("second\n".utf8))
        try secondHandle.close()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        #expect(contents == "first\nsecond\n")
    }
}

@MainActor
final class RecordingPeekabooServices: PeekabooServiceProviding {
    private let base = PeekabooServices()
    private(set) var ensureVisualizerConnectionCallCount = 0

    func ensureVisualizerConnection() {
        self.ensureVisualizerConnectionCallCount += 1
    }

    var logging: any LoggingServiceProtocol {
        self.base.logging
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.base.screenCapture
    }

    var applications: any ApplicationServiceProtocol {
        self.base.applications
    }

    var automation: any UIAutomationServiceProtocol {
        self.base.automation
    }

    var windows: any WindowManagementServiceProtocol {
        self.base.windows
    }

    var menu: any MenuServiceProtocol {
        self.base.menu
    }

    var dock: any DockServiceProtocol {
        self.base.dock
    }

    var dialogs: any DialogServiceProtocol {
        self.base.dialogs
    }

    var snapshots: any SnapshotManagerProtocol {
        self.base.snapshots
    }

    var files: any FileServiceProtocol {
        self.base.files
    }

    var clipboard: any ClipboardServiceProtocol {
        self.base.clipboard
    }

    var configuration: PeekabooCore.ConfigurationManager {
        self.base.configuration
    }

    var process: any ProcessServiceProtocol {
        self.base.process
    }

    var permissions: PermissionsService {
        self.base.permissions
    }

    var audioInput: AudioInputService {
        self.base.audioInput
    }

    var screens: any ScreenServiceProtocol {
        self.base.screens
    }

    var browser: any BrowserMCPClientProviding {
        self.base.browser
    }

    var agent: (any AgentServiceProtocol)? {
        self.base.agent
    }
}
