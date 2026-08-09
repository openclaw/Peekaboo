import Commander
import PeekabooAutomation
import PeekabooBridge
import Testing
@testable import PeekabooCLI

struct RuntimeHostApplicationSelectionTests {
    @Test
    func `Non-capture commands do not require the capture operation`() async {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let applicationOnly = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.launchApplicationWithOptions, .listApplications],
            permissions: PermissionsStatus(
                screenRecording: false,
                accessibility: false,
                appleScript: false,
                postEvent: false
            ),
            enabledOperations: [.launchApplicationWithOptions, .listApplications]
        )
        var launchOptions = CommandRuntimeOptions()
        launchOptions.requiresApplicationLaunchOptions = true
        var inventoryOptions = CommandRuntimeOptions()
        inventoryOptions.requiresHostApplicationInventory = true
        var captureOptions = CommandRuntimeOptions()
        captureOptions.requiresScreenCapturePermission = true
        captureOptions.requiresSilentCapture = true

        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: applicationOnly,
            options: launchOptions
        ) != nil)
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: applicationOnly,
            options: inventoryOptions
        ) != nil)
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: applicationOnly,
            options: captureOptions
        ) == nil)
    }

    @Test
    func `Remote requirements skip stale bridge hosts for launch commands`() {
        let current = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .launchApplicationWithOptions]
        )
        let stale = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 8),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .launchApplication]
        )
        var options = CommandRuntimeOptions()
        options.requiresApplicationLaunchOptions = true

        #expect(CommandRuntime.supportsRemoteRequirements(for: current, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: stale, options: options))
    }

    @Test
    @MainActor
    func `Launch commands prefer GUI host before reusable daemon`() {
        var options = CommandRuntimeOptions()
        options.requiresApplicationLaunchOptions = true

        let candidates = RuntimeHostResolver.implicitRemoteCandidates(
            options: options,
            daemonSocketPath: "/tmp/peekaboo-daemon.sock",
            buildScopedDaemonSocketPath: "/tmp/peekaboo-daemon-current.sock"
        )

        #expect(candidates.map(\.socketPath) == [
            PeekabooBridgeConstants.peekabooSocketPath,
            "/tmp/peekaboo-daemon-current.sock",
            "/tmp/peekaboo-daemon.sock",
        ])
        #expect(candidates.first?.requiredHostKind == .gui)
        #expect(candidates.last?.requireReusableDaemon == true)
    }

    @Test
    @MainActor
    func `Relaunch commands use only a reusable daemon host`() {
        var options = CommandRuntimeOptions()
        options.requiresApplicationLaunchOptions = true
        options.requiresApplicationRelaunch = true

        let candidates = RuntimeHostResolver.implicitRemoteCandidates(
            options: options,
            daemonSocketPath: "/tmp/peekaboo-daemon.sock"
        )

        #expect(candidates.map(\.socketPath) == ["/tmp/peekaboo-daemon.sock"])
        #expect(candidates.first?.requireReusableDaemon == true)
    }

    @Test
    @MainActor
    func `Quit commands use only a reusable daemon host`() throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: AppCommand.QuitSubcommand.self
        )

        #expect(options.requiresSurvivingApplicationHost)
        #expect(options.requiresProcessGenerationPinnedApplicationQuit)
        #expect(!options.requiresApplicationRelaunch)
        let candidates = RuntimeHostResolver.implicitRemoteCandidates(
            options: options,
            daemonSocketPath: "/tmp/peekaboo-daemon.sock"
        )
        #expect(candidates.map(\.socketPath) == ["/tmp/peekaboo-daemon.sock"])
        #expect(candidates.first?.requireReusableDaemon == true)

        let operations: [PeekabooBridgeOperation] = [
            .captureScreen,
            .invalidateImplicitLatestSnapshot,
            .quitApplication,
        ]
        let daemonHost = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 16),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            enabledOperations: operations
        )
        let guiHost = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 16),
            hostKind: .gui,
            build: nil,
            supportedOperations: operations,
            enabledOperations: operations
        )
        let legacyDaemonHost = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 15),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            enabledOperations: operations
        )
        #expect(CommandRuntime.supportsRemoteRequirements(for: daemonHost, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: guiHost, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacyDaemonHost, options: options))
    }

    @Test
    @MainActor
    func `Application inventory prefers GUI host before reusable daemon`() {
        var options = CommandRuntimeOptions()
        options.requiresHostApplicationInventory = true

        let candidates = RuntimeHostResolver.implicitRemoteCandidates(
            options: options,
            daemonSocketPath: "/tmp/peekaboo-daemon.sock",
            buildScopedDaemonSocketPath: "/tmp/peekaboo-daemon-current.sock"
        )

        #expect(candidates.map(\.socketPath) == [
            PeekabooBridgeConstants.peekabooSocketPath,
            "/tmp/peekaboo-daemon-current.sock",
            "/tmp/peekaboo-daemon.sock",
        ])
        #expect(candidates.first?.requiredHostKind == .gui)
        #expect(candidates.last?.requireReusableDaemon == true)
    }

    @Test
    func `Remote routing intent survives launch host fallback but respects isolation`() {
        var launchOptions = CommandRuntimeOptions()
        launchOptions.requiresApplicationLaunchOptions = true

        #expect(RuntimeHostResolver.remoteRoutingAllowed(
            options: launchOptions,
            environment: ["PEEKABOO_INPUT_STRATEGY": "synthOnly"],
            configurationInput: nil
        ))
        #expect(!RuntimeHostResolver.remoteRoutingAllowed(
            options: launchOptions,
            environment: ["PEEKABOO_NO_REMOTE": "1"],
            configurationInput: nil
        ))

        launchOptions.preferRemote = false
        #expect(!RuntimeHostResolver.remoteRoutingAllowed(
            options: launchOptions,
            environment: [:],
            configurationInput: nil
        ))
    }
}
