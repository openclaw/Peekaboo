import Commander
import PeekabooAutomation
import PeekabooBridge
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct RuntimeHostResolverTests {
    @Test
    func `Policy-local click retains known snapshot invalidation endpoints`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: ["inputStrategy": ["actionFirst"]],
            flags: []
        )
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: ClickCommand.self)
        let knownPaths = ["/tmp/gui.sock", "/tmp/daemon.sock"]

        let decision = RuntimeHostResolver.initialRoutingDecision(
            options: options,
            environment: [:],
            configurationInput: nil,
            knownSnapshotInvalidationRemoteSocketPaths: knownPaths
        )

        #expect(options.requiresImplicitSnapshotInvalidation)
        #expect(decision == .local(snapshotInvalidationRemoteSocketPaths: knownPaths))
    }

    @Test
    func `Config policy-local click retains known snapshot invalidation endpoints`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: ClickCommand.self)
        let knownPaths = ["/tmp/gui.sock", "/tmp/daemon.sock"]

        let decision = RuntimeHostResolver.initialRoutingDecision(
            options: options,
            environment: [:],
            configurationInput: Configuration.InputConfig(click: .synthOnly),
            knownSnapshotInvalidationRemoteSocketPaths: knownPaths
        )

        #expect(decision == .local(snapshotInvalidationRemoteSocketPaths: knownPaths))
    }

    @Test
    func `Non-explicit local click retains known snapshot invalidation endpoints`() throws {
        let environment = ["PEEKABOO_CAPTURE_ENGINE": "cg"]
        let baseOptions = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: ClickCommand.self
        )
        let options = baseOptions.applyingEnvironmentOverrides(environment: environment)
        let knownPaths = ["/tmp/gui.sock", "/tmp/daemon.sock"]

        let decision = RuntimeHostResolver.initialRoutingDecision(
            options: options,
            environment: environment,
            configurationInput: nil,
            knownSnapshotInvalidationRemoteSocketPaths: knownPaths
        )

        #expect(!options.preferRemote)
        #expect(!options.remoteIsolationRequested)
        #expect(options.requiresImplicitSnapshotInvalidation)
        #expect(RuntimeHostResolver.shouldResolveKnownRemoteEndpoints(
            options: options,
            environment: environment,
            configurationInput: nil
        ))
        #expect(decision == .local(snapshotInvalidationRemoteSocketPaths: knownPaths))
    }

    @Test
    func `Non-mutating local command skips remote endpoint discovery`() throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: SleepCommand.self
        )

        #expect(!options.preferRemote)
        #expect(!options.requiresImplicitSnapshotInvalidation)
        #expect(!RuntimeHostResolver.shouldResolveKnownRemoteEndpoints(
            options: options,
            environment: [:],
            configurationInput: nil
        ))
    }

    @Test
    func `Explicit no-remote keeps policy-local clicks isolated`() throws {
        let knownPaths = ["/tmp/gui.sock", "/tmp/daemon.sock"]
        let cliNoRemote = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["inputStrategy": ["actionFirst"]],
                flags: ["no-remote"]
            ),
            commandType: ClickCommand.self
        )
        let defaultClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: ClickCommand.self
        )

        let cliDecision = RuntimeHostResolver.initialRoutingDecision(
            options: cliNoRemote,
            environment: [:],
            configurationInput: nil,
            knownSnapshotInvalidationRemoteSocketPaths: knownPaths
        )
        let environmentDecision = RuntimeHostResolver.initialRoutingDecision(
            options: defaultClick,
            environment: ["PEEKABOO_NO_REMOTE": "1", "PEEKABOO_INPUT_STRATEGY": "actionFirst"],
            configurationInput: nil,
            knownSnapshotInvalidationRemoteSocketPaths: knownPaths
        )

        #expect(cliNoRemote.remoteIsolationRequested)
        #expect(!RuntimeHostResolver.shouldResolveKnownRemoteEndpoints(
            options: cliNoRemote,
            environment: [:],
            configurationInput: nil
        ))
        #expect(!RuntimeHostResolver.shouldResolveKnownRemoteEndpoints(
            options: defaultClick,
            environment: ["PEEKABOO_NO_REMOTE": "1"],
            configurationInput: nil
        ))
        #expect(cliDecision == .local(snapshotInvalidationRemoteSocketPaths: []))
        #expect(environmentDecision == .local(snapshotInvalidationRemoteSocketPaths: []))
    }

    @Test
    func `Bridge diagnostics mirror policy-local runtime routing`() {
        var explicitPolicy = CommandRuntimeOptions()
        explicitPolicy.inputStrategy = .actionFirst

        #expect(BridgeDiagnostics.remoteSkipReason(
            runtimeOptions: explicitPolicy,
            environment: [:],
            configurationInput: nil
        ) == "input strategy policy")
        #expect(BridgeDiagnostics.remoteSkipReason(
            runtimeOptions: CommandRuntimeOptions(),
            environment: [:],
            configurationInput: Configuration.InputConfig(click: .synthOnly)
        ) == "input strategy policy")
        #expect(BridgeDiagnostics.remoteSkipReason(
            runtimeOptions: CommandRuntimeOptions(),
            environment: [:],
            configurationInput: nil
        ) == nil)
    }

    @Test
    func `Historical diagnostics use runtime candidate validation`() async {
        let socketPath = "/tmp/peekaboo/daemon-bbbbbbbbbbbbbbbb.sock"
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: socketPath,
            requireReusableDaemon: true,
            requiredHostKind: .onDemand,
            requiresValidatedHistoricalDaemon: true
        )
        let handshake = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen]
        )
        let currentOperationNames = [
            PeekabooBridgeOperation.daemonStatus.rawValue,
            PeekabooBridgeOperation.daemonStop.rawValue,
            PeekabooBridgeOperation.launchApplicationWithOptions.rawValue,
            PeekabooBridgeOperation.relaunchApplicationWithOptions.rawValue,
            PeekabooBridgeOperation.invalidateImplicitLatestSnapshot.rawValue,
        ]
        let status = PeekabooDaemonStatus(
            running: true,
            pid: 4242,
            mode: .manual,
            bridge: PeekabooDaemonBridgeStatus(
                socketPath: socketPath,
                hostKind: .onDemand,
                allowedOperations: [.daemonStatus, .daemonStop],
                availableOperationNames: currentOperationNames
            ),
            supportsConditionalStop: true
        )

        let selected = await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: handshake,
            options: CommandRuntimeOptions(),
            fetchReusableDaemonStatus: { _ in status }
        )
        #expect(selected?.reusableDaemonStatus?.pid == 4242)

        let staleStatus = PeekabooDaemonStatus(
            running: true,
            pid: 4242,
            mode: .manual,
            bridge: PeekabooDaemonBridgeStatus(
                socketPath: socketPath,
                hostKind: .onDemand,
                allowedOperations: [.daemonStatus, .daemonStop]
            ),
            supportsConditionalStop: true
        )
        let rejected = await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: handshake,
            options: CommandRuntimeOptions(),
            fetchReusableDaemonStatus: { _ in staleStatus }
        )
        #expect(rejected == nil)
    }

    @Test
    func `Candidate validation rejects synthetic click hosts without post event permission`() async {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        var options = CommandRuntimeOptions()
        options.requiresPostEventClickPermission = true
        let accessibilityOnly = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedClick],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: false
            ),
            enabledOperations: [.captureScreen, .targetedClick]
        )
        let postEventCapable = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedClick],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: true
            ),
            enabledOperations: [.captureScreen, .targetedClick]
        )

        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: accessibilityOnly,
            options: options
        ) == nil)
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: postEventCapable,
            options: options
        ) != nil)
    }

    private static func captureOptions() -> CommandRuntimeOptions {
        var options = CommandRuntimeOptions()
        options.requiresScreenCapturePermission = true
        return options
    }

    @Test
    func `Candidate validation rejects hosts that explicitly lack required capture permission`() async {
        // Mirrors the reproduced bug: a stale GUI build serving bridge.sock while holding zero
        // TCC permissions must not win selection for a capture-dependent command.
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: .gui,
            requiresValidatedHistoricalDaemon: false
        )
        let unpermissioned = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: "stale-debug",
            supportedOperations: [.captureScreen, .listApplications],
            permissions: PermissionsStatus(
                screenRecording: false,
                accessibility: false,
                appleScript: false,
                postEvent: false
            ),
            enabledOperations: [.captureScreen, .listApplications],
            permissionTags: [PeekabooBridgeOperation.captureScreen.rawValue: [.screenRecording]]
        )

        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: unpermissioned,
            options: Self.captureOptions()
        ) == nil)
        #expect(BridgeCapabilityPolicy.explicitlyMissingRemotePermissions(
            for: unpermissioned,
            options: Self.captureOptions()
        ) == [.screenRecording])
    }

    @Test
    func `Non-capture commands tolerate hosts that lack screen recording`() async {
        // Regression: a host that supports the capture operation but reports screenRecording=false,
        // while holding the permissions its own commands need, must NOT be rejected for non-capture
        // commands such as `app launch` (no permission) or `app list` (no permission).
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let noScreenRecording = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen, .launchApplicationWithOptions, .listApplications],
            permissions: PermissionsStatus(
                screenRecording: false,
                accessibility: true,
                appleScript: true,
                postEvent: true
            ),
            enabledOperations: [.captureScreen, .launchApplicationWithOptions, .listApplications],
            permissionTags: [PeekabooBridgeOperation.captureScreen.rawValue: [.screenRecording]]
        )

        var launchOptions = CommandRuntimeOptions()
        launchOptions.requiresApplicationLaunchOptions = true
        var inventoryOptions = CommandRuntimeOptions()
        inventoryOptions.requiresHostApplicationInventory = true

        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: noScreenRecording,
            options: launchOptions
        ) != nil)
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: noScreenRecording,
            options: inventoryOptions
        ) != nil)
        // ... yet the same host is still rejected for a command that actually captures pixels.
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: noScreenRecording,
            options: Self.captureOptions()
        ) == nil)
    }

    @Test
    func `Candidate validation rejects permission-less hosts even without permission tags`() async {
        // Hosts that report permissions but predate permissionTags fall back to the client-side
        // operation-to-permission mapping.
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let untagged = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen],
            permissions: PermissionsStatus(
                screenRecording: false,
                accessibility: false,
                appleScript: false,
                postEvent: false
            )
        )

        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: untagged,
            options: Self.captureOptions()
        ) == nil)
    }

    @Test
    func `Candidate validation accepts hosts that omit the permission report`() async {
        // Back-compat: older hosts do not include permissions in the handshake. Unknown is
        // acceptable; only an explicit false rejects.
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: .gui,
            requiresValidatedHistoricalDaemon: false
        )
        let unknownPermissions = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen]
        )

        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: unknownPermissions,
            options: Self.captureOptions()
        ) != nil)
    }

    @Test
    func `Candidate validation selects hosts that hold the required permissions`() async {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: .gui,
            requiresValidatedHistoricalDaemon: false
        )
        let permissioned = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                appleScript: true,
                postEvent: true
            ),
            enabledOperations: [.captureScreen],
            permissionTags: [PeekabooBridgeOperation.captureScreen.rawValue: [.screenRecording]]
        )

        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: permissioned,
            options: Self.captureOptions()
        ) != nil)
    }

    @Test
    func `Required permissions follow the operations the command uses`() async {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        // Holds Screen Recording but not Accessibility.
        let captureOnlyPermissions = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen, .inspectAccessibilityTree],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: false,
                appleScript: false,
                postEvent: false
            ),
            enabledOperations: [.captureScreen],
            permissionTags: [
                PeekabooBridgeOperation.captureScreen.rawValue: [.screenRecording],
                PeekabooBridgeOperation.inspectAccessibilityTree.rawValue: [.accessibility],
            ]
        )

        var inspectOptions = CommandRuntimeOptions()
        inspectOptions.requiresInspectAccessibilityTree = true

        // A capture command is satisfied (Screen Recording present)...
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: captureOnlyPermissions,
            options: Self.captureOptions()
        ) != nil)
        // ...but an AX-tree inspection command is rejected (Accessibility missing).
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: captureOnlyPermissions,
            options: inspectOptions
        ) == nil)
        #expect(BridgeCapabilityPolicy.explicitlyMissingRemotePermissions(
            for: captureOnlyPermissions,
            options: inspectOptions
        ) == [.accessibility])
    }

    @Test
    func `Permission request commands may target hosts that lack the permission`() async {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: .gui,
            requiresValidatedHistoricalDaemon: false
        )
        let unpermissioned = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .requestPostEventPermission],
            permissions: PermissionsStatus(
                screenRecording: false,
                accessibility: false,
                appleScript: false,
                postEvent: false
            ),
            permissionTags: [PeekabooBridgeOperation.captureScreen.rawValue: [.screenRecording]]
        )

        var requestOptions = CommandRuntimeOptions()
        requestOptions.requestsHostPermissionGrant = true

        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: unpermissioned,
            options: requestOptions
        ) != nil)
    }
}
