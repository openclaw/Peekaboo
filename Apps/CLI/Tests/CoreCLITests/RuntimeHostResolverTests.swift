import Commander
import PeekabooAutomation
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct RuntimeHostResolverTests {
    @Test
    func `only mutation barriers prevalidate historical daemon inventory`() {
        #expect(!RuntimeHostResolver.requiresValidatedHistoricalDaemonInventory(
            options: CommandRuntimeOptions()
        ))

        var implicitInvalidation = CommandRuntimeOptions()
        implicitInvalidation.requiresImplicitSnapshotInvalidation = true
        #expect(RuntimeHostResolver.requiresValidatedHistoricalDaemonInventory(
            options: implicitInvalidation
        ))

        var perToolInvalidation = CommandRuntimeOptions()
        perToolInvalidation.usesPerToolSnapshotInvalidation = true
        #expect(RuntimeHostResolver.requiresValidatedHistoricalDaemonInventory(
            options: perToolInvalidation
        ))
    }

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
            commandType: ToolsCommand.self
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
        let handshake = BridgeTestFixtures.handshake(
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
        options.requiresPostEventPermission = true
        let accessibilityOnly = BridgeTestFixtures.handshake(
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
        let postEventCapable = BridgeTestFixtures.handshake(
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

    @Test
    func `snapshot-producing command skips old same-minor host for a capable peer`() async throws {
        let oldCandidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/old-snapshot-host.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let currentCandidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/current-snapshot-host.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let oldHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 34),
            supportedOperations: [.desktopObservation],
            hostCapabilities: [PeekabooBridgeHostCapability.attestedOperationReceipts]
        )
        let currentHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 34),
            supportedOperations: [.desktopObservation, .ownsSnapshot],
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.producerBoundSnapshotReferences,
            ]
        )
        var options = CommandRuntimeOptions()
        options.requiresDesktopObservation = true
        options.requiresProducerBoundSnapshotReferences = true
        var permissionRejections: [String] = []

        let resolution = try await RuntimeHostResolver.resolveRemoteServices(
            candidates: [oldCandidate, currentCandidate],
            identity: PeekabooBridgeClientIdentity(
                bundleIdentifier: "boo.peekaboo.snapshot-selection-tests",
                teamIdentifier: nil,
                processIdentifier: 42
            ),
            options: options,
            snapshotInvalidationRemoteSocketPaths: [],
            permissionRejections: &permissionRejections,
            handshake: { candidate, _ in
                candidate == oldCandidate ? oldHandshake : currentHandshake
            }
        )

        #expect(resolution?.selectedRemoteSocketPath == currentCandidate.socketPath)
        #expect(permissionRejections.isEmpty)
    }

    @Test
    func `action resolution skips a policy disabled first host for an eligible peer`() async throws {
        let disabledCandidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/disabled-element-action-host.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let eligibleCandidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/eligible-element-action-host.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let capabilities = [
            PeekabooBridgeHostCapability.attestedOperationReceipts,
            PeekabooBridgeHostCapability.setValueResultTargetBinding,
            PeekabooBridgeHostCapability.processGenerationBoundElementMutations,
        ]
        let disabledHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion,
            supportedOperations: [.setValue, .performAction],
            enabledOperations: [.setValue],
            hostCapabilities: capabilities
        )
        let eligibleHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion,
            supportedOperations: [.setValue, .performAction],
            enabledOperations: [.setValue, .performAction],
            hostCapabilities: capabilities
        )
        var options = CommandRuntimeOptions()
        options.requiredElementActionOperations = [.performAction]
        var permissionRejections: [String] = []

        let resolution = try await RuntimeHostResolver.resolveRemoteServices(
            candidates: [disabledCandidate, eligibleCandidate],
            identity: PeekabooBridgeClientIdentity(
                bundleIdentifier: "boo.peekaboo.element-action-selection-tests",
                teamIdentifier: nil,
                processIdentifier: 42
            ),
            options: options,
            snapshotInvalidationRemoteSocketPaths: [],
            permissionRejections: &permissionRejections,
            handshake: { candidate, _ in
                candidate == disabledCandidate ? disabledHandshake : eligibleHandshake
            }
        )

        #expect(resolution?.selectedRemoteSocketPath == eligibleCandidate.socketPath)
        #expect(permissionRejections.isEmpty)
    }

    @Test
    func `set value resolution accepts a host that does not expose perform action`() async throws {
        let setValueCandidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/set-value-only-host.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let fallbackCandidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/element-action-fallback-host.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let capabilities = [
            PeekabooBridgeHostCapability.attestedOperationReceipts,
            PeekabooBridgeHostCapability.setValueResultTargetBinding,
            PeekabooBridgeHostCapability.processGenerationBoundElementMutations,
        ]
        let setValueHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion,
            supportedOperations: [.setValue],
            enabledOperations: [.setValue],
            hostCapabilities: capabilities
        )
        let fallbackHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion,
            supportedOperations: [.setValue, .performAction],
            enabledOperations: [.setValue, .performAction],
            hostCapabilities: capabilities
        )
        var options = CommandRuntimeOptions()
        options.requiredElementActionOperations = [.setValue]
        var permissionRejections: [String] = []

        let resolution = try await RuntimeHostResolver.resolveRemoteServices(
            candidates: [setValueCandidate, fallbackCandidate],
            identity: PeekabooBridgeClientIdentity(
                bundleIdentifier: "boo.peekaboo.set-value-selection-tests",
                teamIdentifier: nil,
                processIdentifier: 42
            ),
            options: options,
            snapshotInvalidationRemoteSocketPaths: [],
            permissionRejections: &permissionRejections,
            handshake: { candidate, _ in
                candidate == setValueCandidate ? setValueHandshake : fallbackHandshake
            }
        )

        #expect(resolution?.selectedRemoteSocketPath == setValueCandidate.socketPath)
        #expect(resolution?.services.automation is any ElementActionAutomationServiceProtocol)
        #expect(permissionRejections.isEmpty)
    }

    @Test
    func `Candidate validation rejects pre-long-press bridge hosts`() async {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        var options = CommandRuntimeOptions()
        options.requiresPostEventPermission = true
        options.requiresLongPressClick = true

        func handshake(minor: Int, supportsClick: Bool = true) -> PeekabooBridgeHandshakeResponse {
            let operations: [PeekabooBridgeOperation] = supportsClick
                ? [.captureScreen, .click, .targetedClick]
                : [.captureScreen, .targetedClick]
            return BridgeTestFixtures.handshake(
                negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: minor),
                hostKind: .gui,
                build: nil,
                supportedOperations: operations,
                permissions: PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    postEvent: true
                ),
                enabledOperations: operations
            )
        }

        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: handshake(minor: 9),
            options: options
        ) == nil)
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: handshake(minor: 10),
            options: options
        ) != nil)
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: handshake(minor: 10, supportsClick: false),
            options: options
        ) == nil)
    }

    @Test
    func `Candidate validation skips legacy hosts for mutations but preserves read-only compatibility`() async throws {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let operations: [PeekabooBridgeOperation] = [
            .captureScreen,
            .listWindows,
            .moveWindow,
            .invalidateImplicitLatestSnapshot,
        ]
        func handshake(minor: Int) -> PeekabooBridgeHandshakeResponse {
            BridgeTestFixtures.handshake(
                negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: minor),
                hostKind: .gui,
                build: nil,
                supportedOperations: operations,
                enabledOperations: operations
            )
        }

        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let mutationOptions = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: WindowCommand.MoveSubcommand.self
        )
        let listingOptions = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: WindowCommand.WindowListSubcommand.self
        )

        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: handshake(minor: 17),
            options: mutationOptions
        ) == nil)
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: handshake(minor: 18),
            options: mutationOptions
        ) != nil)
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: handshake(minor: 15),
            options: listingOptions
        ) != nil)
    }

    @Test
    func `Window restore requires supported and enabled protocol 1_18 operation`() async throws {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let required: [PeekabooBridgeOperation] = [
            .captureScreen,
            .listWindows,
            .restoreWindow,
            .invalidateImplicitLatestSnapshot,
        ]
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: WindowCommand.RestoreSubcommand.self
        )
        func handshake(
            supported: [PeekabooBridgeOperation],
            enabled: [PeekabooBridgeOperation]
        ) -> PeekabooBridgeHandshakeResponse {
            BridgeTestFixtures.handshake(
                negotiatedVersion: .init(major: 1, minor: 18),
                hostKind: .gui,
                build: nil,
                supportedOperations: supported,
                enabledOperations: enabled
            )
        }

        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: handshake(
                supported: required.filter { $0 != .restoreWindow },
                enabled: required.filter { $0 != .restoreWindow }
            ),
            options: options
        ) == nil)
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: handshake(
                supported: required,
                enabled: required.filter { $0 != .restoreWindow }
            ),
            options: options
        ) == nil)
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: handshake(supported: required, enabled: required),
            options: options
        ) != nil)
    }

    @Test
    func `Quit target shapes reject legacy hosts and require enabled pinned quit support`() async throws {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/daemon.sock",
            requireReusableDaemon: true,
            requiredHostKind: .onDemand,
            requiresValidatedHistoricalDaemon: false
        )
        let operations: [PeekabooBridgeOperation] = [
            .captureScreen,
            .quitApplication,
            .invalidateImplicitLatestSnapshot,
        ]
        func handshake(minor: Int, enabledOperations: [PeekabooBridgeOperation]? = nil)
        -> PeekabooBridgeHandshakeResponse {
            BridgeTestFixtures.handshake(
                negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: minor),
                hostKind: .onDemand,
                build: nil,
                supportedOperations: operations,
                enabledOperations: enabledOperations ?? operations
            )
        }
        let reusableStatus = PeekabooDaemonStatus(
            running: true,
            pid: 4242,
            mode: .manual,
            bridge: PeekabooDaemonBridgeStatus(
                socketPath: candidate.socketPath,
                hostKind: .onDemand,
                allowedOperations: operations
            )
        )
        let targetShapes = [
            ParsedValues(positional: [], options: ["app": ["TextEdit"]], flags: []),
            ParsedValues(positional: [], options: ["pid": ["123"]], flags: []),
            ParsedValues(positional: [], options: [:], flags: ["all"]),
        ]

        for parsed in targetShapes {
            let options = try CommanderCLIBinder.makeRuntimeOptions(
                from: parsed,
                commandType: AppCommand.QuitSubcommand.self
            )
            #expect(options.requiresProcessGenerationPinnedApplicationQuit)
            #expect(await RuntimeHostResolver.validateRemoteCandidate(
                candidate,
                handshake: handshake(minor: 15),
                options: options,
                fetchReusableDaemonStatus: { _ in reusableStatus }
            ) == nil)
            #expect(await RuntimeHostResolver.validateRemoteCandidate(
                candidate,
                handshake: handshake(minor: 16),
                options: options,
                fetchReusableDaemonStatus: { _ in reusableStatus }
            ) != nil)
            #expect(await RuntimeHostResolver.validateRemoteCandidate(
                candidate,
                handshake: handshake(
                    minor: 16,
                    enabledOperations: [.captureScreen, .invalidateImplicitLatestSnapshot]
                ),
                options: options,
                fetchReusableDaemonStatus: { _ in reusableStatus }
            ) == nil)
        }
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
        let unpermissioned = BridgeTestFixtures.handshake(
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
        let noScreenRecording = BridgeTestFixtures.handshake(
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
}

// MARK: - Candidate permissions and protocol compatibility

extension RuntimeHostResolverTests {
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
        let untagged = BridgeTestFixtures.handshake(
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
        let unknownPermissions = BridgeTestFixtures.handshake(
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
    func `Implicit current-host selection rejects a compatible older protocol without breaking fallback`() async {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/daemon.sock",
            requireReusableDaemon: true,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let olderProtocol = PeekabooBridgeProtocolVersion(
            major: PeekabooBridgeConstants.protocolVersion.major,
            minor: PeekabooBridgeConstants.protocolVersion.minor - 1
        )
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: olderProtocol,
            hostKind: .onDemand,
            build: "legacy",
            supportedOperations: [.captureScreen]
        )
        let reusableStatus = PeekabooDaemonStatus(
            running: true,
            pid: 4242,
            mode: .manual,
            bridge: PeekabooDaemonBridgeStatus(
                socketPath: candidate.socketPath,
                hostKind: .onDemand,
                allowedOperations: [.daemonStatus]
            )
        )

        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: handshake,
            options: CommandRuntimeOptions(),
            requiredProtocolVersion: PeekabooBridgeConstants.protocolVersion,
            fetchReusableDaemonStatus: { _ in reusableStatus }
        ) == nil)
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: handshake,
            options: CommandRuntimeOptions(),
            fetchReusableDaemonStatus: { _ in reusableStatus }
        ) != nil)
    }

    @Test
    func `Exact build preference applies only to stateful implicit standard daemon routing`() {
        let buildScopedSocketPath = "/tmp/daemon-current.sock"
        var snapshotProducer = CommandRuntimeOptions()
        snapshotProducer.requiresScreenCapturePermission = true
        var snapshotInspection = CommandRuntimeOptions()
        snapshotInspection.requiresInspectAccessibilityTree = true
        var snapshotMutation = CommandRuntimeOptions()
        snapshotMutation.requiresImplicitSnapshotInvalidation = true
        var longLivedSnapshotRuntime = CommandRuntimeOptions()
        longLivedSnapshotRuntime.usesPerToolSnapshotInvalidation = true
        var browserRuntime = CommandRuntimeOptions()
        browserRuntime.requiresBrowserMCP = true
        var applicationInventory = snapshotProducer
        applicationInventory.requiresHostApplicationInventory = true
        var applicationLaunch = snapshotMutation
        applicationLaunch.requiresApplicationLaunchOptions = true

        #expect(RuntimeHostResolver.prefersExactBuildScopedHost(
            options: snapshotProducer,
            explicitSocket: nil,
            buildScopedDaemonSocketPath: buildScopedSocketPath
        ))
        #expect(RuntimeHostResolver.prefersExactBuildScopedHost(
            options: snapshotInspection,
            explicitSocket: nil,
            buildScopedDaemonSocketPath: buildScopedSocketPath
        ))
        #expect(RuntimeHostResolver.prefersExactBuildScopedHost(
            options: snapshotMutation,
            explicitSocket: nil,
            buildScopedDaemonSocketPath: buildScopedSocketPath
        ))
        #expect(RuntimeHostResolver.prefersExactBuildScopedHost(
            options: longLivedSnapshotRuntime,
            explicitSocket: nil,
            buildScopedDaemonSocketPath: buildScopedSocketPath
        ))
        #expect(RuntimeHostResolver.prefersExactBuildScopedHost(
            options: browserRuntime,
            explicitSocket: nil,
            buildScopedDaemonSocketPath: buildScopedSocketPath
        ))
        #expect(!RuntimeHostResolver.prefersExactBuildScopedHost(
            options: snapshotProducer,
            explicitSocket: "/tmp/legacy-explicit.sock",
            buildScopedDaemonSocketPath: buildScopedSocketPath
        ))
        #expect(!RuntimeHostResolver.prefersExactBuildScopedHost(
            options: snapshotProducer,
            explicitSocket: nil,
            buildScopedDaemonSocketPath: nil
        ))
        #expect(!RuntimeHostResolver.prefersExactBuildScopedHost(
            options: applicationInventory,
            explicitSocket: nil,
            buildScopedDaemonSocketPath: buildScopedSocketPath
        ))
        #expect(!RuntimeHostResolver.prefersExactBuildScopedHost(
            options: applicationLaunch,
            explicitSocket: nil,
            buildScopedDaemonSocketPath: buildScopedSocketPath
        ))
        #expect(!RuntimeHostResolver.prefersExactBuildScopedHost(
            options: CommandRuntimeOptions(),
            explicitSocket: nil,
            buildScopedDaemonSocketPath: buildScopedSocketPath
        ))
    }

    @Test
    func `Candidate validation selects hosts that hold the required permissions`() async {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: .gui,
            requiresValidatedHistoricalDaemon: false
        )
        let permissioned = BridgeTestFixtures.handshake(
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
        let captureOnlyPermissions = BridgeTestFixtures.handshake(
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
        let unpermissioned = BridgeTestFixtures.handshake(
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
