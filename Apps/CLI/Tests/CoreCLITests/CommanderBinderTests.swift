import Commander
import Foundation
import PeekabooAutomation
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

struct CommanderBinderTests {
    @Test
    func `Runtime options map verbose flag`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: ["verbose"])
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed)
        #expect(options.verbose == true)
        #expect(options.jsonOutput == false)
    }

    @Test
    func `Runtime options map json flag`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: ["jsonOutput"])
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed)
        #expect(options.verbose == false)
        #expect(options.jsonOutput == true)
    }

    @Test
    func `Only dynamic Agent runtimes eagerly construct the Agent service`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])

        for commandType in [AgentRunSubcommand.self, MCPCommand.Serve.self] as [any ParsableCommand.Type] {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(options.requiresAgentService, "Missing Agent service for \(commandType)")
        }

        for commandType in [ToolsListSubcommand.self, SeeCommand.self, TypeCommand.self, ClickCommand.self]
            as [any ParsableCommand.Type] {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(!options.requiresAgentService, "Eager Agent service for \(commandType)")
        }
    }

    @Test
    func `Runtime options map log level option`() throws {
        let parsed = ParsedValues(positional: [], options: ["logLevel": ["error"]], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed)
        #expect(options.logLevel == .error)
    }

    @Test
    func `Runtime options map input strategy option for policy-local routing`() throws {
        let parsed = ParsedValues(positional: [], options: ["inputStrategy": ["actionFirst"]], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed)
        #expect(options.inputStrategy?.rawValue == "actionFirst")
        #expect(options.preferRemote)
        #expect(RuntimeHostResolver.inputPolicyRequiresLocal(
            options: options,
            environment: [:],
            configurationInput: nil
        ))
    }

    @Test
    func `See capture engine option remains remotely routable`() throws {
        let parsed = ParsedValues(positional: [], options: ["captureEngine": ["cg"]], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: SeeCommand.self)
        #expect(options.captureEnginePreference == "cg")
        #expect(options.preferRemote)
        #expect(options.transportsCaptureEnginePreference)
        #expect(options.requiresCaptureEnginePreferenceHost)
        #expect(options.requiresDesktopObservation)
    }

    @Test
    func `See capture engine environment override remains remotely routable`() throws {
        let base = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: SeeCommand.self
        )
        let options = base.applyingEnvironmentOverrides(environment: [
            "PEEKABOO_CAPTURE_ENGINE": " modern ",
        ])

        #expect(options.captureEnginePreference == "modern")
        #expect(options.preferRemote)
        #expect(options.transportsCaptureEnginePreference)
        #expect(options.requiresCaptureEnginePreferenceHost)
        #expect(options.requiresDesktopObservation)
    }

    @Test
    func `Capture engine option stays local when a command cannot transport it`() throws {
        let parsed = ParsedValues(positional: [], options: ["captureEngine": ["cg"]], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: CaptureLiveCommand.self)

        #expect(options.captureEnginePreference == "cg")
        #expect(!options.preferRemote)
        #expect(!options.transportsCaptureEnginePreference)
        #expect(!options.requiresCaptureEnginePreferenceHost)
    }

    @Test
    func `Tree only see rejects an unused capture engine`() {
        #expect(throws: CommanderBindingError.self) {
            try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(
                    positional: [],
                    options: ["captureEngine": ["cg"]],
                    flags: ["noScreenshot"]
                ),
                commandType: SeeCommand.self
            )
        }
    }

    @Test
    func `See rejects an unknown capture engine before runtime resolution`() {
        #expect(throws: CommanderBindingError.self) {
            try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(
                    positional: [],
                    options: ["captureEngine": ["warp-drive"]],
                    flags: []
                ),
                commandType: SeeCommand.self
            )
        }
    }

    @Test
    func `Capture engine environment override forces local mode`() {
        let options = CommandRuntimeOptions().applyingEnvironmentOverrides(environment: [
            "PEEKABOO_CAPTURE_ENGINE": " modern ",
        ])

        #expect(options.captureEnginePreference == "modern")
        #expect(options.preferRemote == false)
    }

    @Test
    func `Blank capture engine environment override is ignored`() {
        let options = CommandRuntimeOptions().applyingEnvironmentOverrides(environment: [
            "PEEKABOO_CAPTURE_ENGINE": " ",
        ])

        #expect(options.captureEnginePreference == nil)
        #expect(options.preferRemote == true)
    }

    @Test
    func `CLI capture engine preference takes precedence over environment`() {
        var base = CommandRuntimeOptions()
        base.captureEnginePreference = "cg"
        base.preferRemote = false

        let options = base.applyingEnvironmentOverrides(environment: [
            "PEEKABOO_CAPTURE_ENGINE": "modern",
        ])

        #expect(options.captureEnginePreference == "cg")
        #expect(options.preferRemote == false)
    }

    @Test
    func `Input strategy environment overrides force local runtime`() {
        #expect(CommandRuntime.hasInputStrategyEnvironmentOverride(environment: [
            "PEEKABOO_INPUT_STRATEGY": "synthOnly",
        ]))
        #expect(CommandRuntime.hasInputStrategyEnvironmentOverride(environment: [
            "PEEKABOO_CLICK_INPUT_STRATEGY": " actionFirst ",
        ]))
        #expect(!CommandRuntime.hasInputStrategyEnvironmentOverride(environment: [
            "PEEKABOO_INPUT_STRATEGY": " ",
            "OTHER": "synthOnly",
        ]))
        #expect(!CommandRuntime.hasInputStrategyEnvironmentOverride(environment: [
            "PEEKABOO_INPUT_STRATEGY": "action-first",
        ]))
    }

    @Test
    func `Input strategy config overrides force local runtime`() {
        #expect(CommandRuntime.hasInputStrategyConfigOverride(input: Configuration.InputConfig(click: .synthOnly)))
        #expect(CommandRuntime.hasInputStrategyConfigOverride(input: Configuration.InputConfig(
            perApp: [
                "com.example.Editor": Configuration.AppInputConfig(scroll: .actionFirst),
            ]
        )))
        #expect(!CommandRuntime.hasInputStrategyConfigOverride(input: nil))
        #expect(!CommandRuntime.hasInputStrategyConfigOverride(input: Configuration.InputConfig()))
        #expect(!CommandRuntime.hasInputStrategyConfigOverride(input: Configuration.InputConfig(
            perApp: [
                "com.example.Empty": Configuration.AppInputConfig(),
            ]
        )))
    }

    @Test
    func `Element actions require bridge protocol and operation support`() {
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.setValue, .performAction],
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.setValueResultTargetBinding,
                PeekabooBridgeHostCapability.processGenerationBoundElementMutations,
            ]
        )
        let oldProtocol = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 36),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.setValue, .performAction],
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.setValueResultTargetBinding,
                PeekabooBridgeHostCapability.processGenerationBoundElementMutations,
            ]
        )
        let missingOperation = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.setValue],
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.setValueResultTargetBinding,
                PeekabooBridgeHostCapability.processGenerationBoundElementMutations,
            ]
        )
        let missingCapability = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.setValue, .performAction],
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.setValueResultTargetBinding,
            ]
        )
        let disabledOperation = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.setValue, .performAction],
            enabledOperations: [.setValue],
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.setValueResultTargetBinding,
                PeekabooBridgeHostCapability.processGenerationBoundElementMutations,
            ]
        )
        let actionOnly = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.performAction],
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.processGenerationBoundElementMutations,
            ]
        )

        #expect(CommandRuntime.supportsElementActions(for: current))
        #expect(!CommandRuntime.supportsElementActions(for: oldProtocol))
        #expect(CommandRuntime.supportsElementActions(for: missingOperation))
        #expect(!CommandRuntime.supportsElementActions(for: missingCapability))
        #expect(CommandRuntime.supportsElementActions(for: disabledOperation))
        #expect(CommandRuntime.supportsElementAction(.setValue, for: missingOperation))
        #expect(!CommandRuntime.supportsElementAction(.performAction, for: missingOperation))
        #expect(CommandRuntime.supportsElementAction(.setValue, for: disabledOperation))
        #expect(!CommandRuntime.supportsElementAction(.performAction, for: disabledOperation))
        #expect(CommandRuntime.supportsElementAction(.performAction, for: actionOnly))
        #expect(!CommandRuntime.supportsElementAction(.setValue, for: actionOnly))
        #expect(CommandRuntime.supportsElementActions(for: actionOnly))
    }

    @Test
    func `Application launch options require bridge protocol and operation support`() {
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationPinnedInteractionVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.launchApplicationWithOptions]
        )
        let oldProtocol = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 8),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.launchApplicationWithOptions]
        )
        let missingOperation = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationPinnedInteractionVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: []
        )

        #expect(CommandRuntime.supportsApplicationLaunchOptions(for: current))
        #expect(!CommandRuntime.supportsApplicationLaunchOptions(for: oldProtocol))
        #expect(!CommandRuntime.supportsApplicationLaunchOptions(for: missingOperation))
    }

    @Test
    func `New application instance launch requires bridge protocol 1_13`() {
        let supportedOperations: [PeekabooBridgeOperation] = [.captureScreen, .launchApplicationWithOptions]
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 13),
            hostKind: .gui,
            build: nil,
            supportedOperations: supportedOperations
        )
        let old = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 12),
            hostKind: .gui,
            build: nil,
            supportedOperations: supportedOperations
        )
        var options = CommandRuntimeOptions()
        options.requiresApplicationLaunchOptions = true
        options.requiresNewApplicationInstanceLaunch = true
        options.requiresApplicationWindowReadiness = true

        #expect(CommandRuntime.supportsRemoteRequirements(for: current, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: old, options: options))
    }

    @Test
    func `window-instance-pinned mutations require bridge protocol 1_18`() {
        let operations: [PeekabooBridgeOperation] = [.moveWindow, .closeWindow, .maximizeWindow]
        let legacy = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 17),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations
        )
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 18),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations
        )

        #expect(!BridgeCapabilityPolicy.supportsPinnedWindowMutations(for: legacy))
        #expect(BridgeCapabilityPolicy.supportsPinnedWindowMutations(for: current))
    }

    @Test
    func `Launch commands require a bridge host with launch options`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: ["foreground"])
        let commandTypes: [any ParsableCommand.Type] = [
            AppCommand.LaunchSubcommand.self,
            AppCommand.RelaunchSubcommand.self,
        ]

        for commandType in commandTypes {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(options.requiresApplicationLaunchOptions)
            #expect(options.requiresApplicationRelaunch == (commandType == AppCommand.RelaunchSubcommand.self))
        }
    }

    @Test
    func `Snapshot-mutating commands require implicit invalidation support`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: ["foreground", "activate"])
        let commandTypes: [any ParsableCommand.Type] = [
            AppCommand.LaunchSubcommand.self,
            AppCommand.RelaunchSubcommand.self,
            AppCommand.QuitSubcommand.self,
            AppCommand.HideSubcommand.self,
            AppCommand.UnhideSubcommand.self,
            AppCommand.SwitchSubcommand.self,
            ClickCommand.self,
            MoveCommand.self,
            TypeCommand.self,
            PressCommand.self,
            PasteCommand.self,
            ScrollCommand.self,
            DragCommand.self,
            SetValueCommand.self,
            ActionCommand.self,
            CaptureActionCommand.self,
            WindowCommand.FocusSubcommand.self,
            WindowCommand.CloseSubcommand.self,
            WindowCommand.MinimizeSubcommand.self,
            WindowCommand.RestoreSubcommand.self,
            WindowCommand.MaximizeSubcommand.self,
            WindowCommand.MoveSubcommand.self,
            WindowCommand.ResizeSubcommand.self,
            WindowCommand.SetBoundsSubcommand.self,
            MenuCommand.ClickSubcommand.self,
            MenuCommand.ListSubcommand.self,
            DockCommand.LaunchSubcommand.self,
            DockCommand.RightClickSubcommand.self,
            DockCommand.HideSubcommand.self,
            DockCommand.ShowSubcommand.self,
            SwitchSubcommand.self,
            MoveWindowSubcommand.self,
        ]

        for commandType in commandTypes {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(options.requiresImplicitSnapshotInvalidation, "Missing invalidation requirement: \(commandType)")
        }

        for commandType in [
            SwitchSubcommand.self,
            MoveWindowSubcommand.self,
            CaptureActionCommand.self,
        ] as [any ParsableCommand.Type] {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(options.requiresCallerDesktopMutationBarrier)
        }
        let menuBarClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: MenuBarCommand.ClickSubcommand.self
        )
        #expect(menuBarClick.requiresImplicitSnapshotInvalidation)
        let menuBarList = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: MenuBarCommand.ListSubcommand.self
        )
        #expect(!menuBarList.requiresImplicitSnapshotInvalidation)

        let browserClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["click"], options: [:], flags: []),
            commandType: BrowserCommand.self
        )
        #expect(browserClick.requiresImplicitSnapshotInvalidation)
        let browserStatus = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["status"], options: [:], flags: []),
            commandType: BrowserCommand.self
        )
        #expect(!browserStatus.requiresImplicitSnapshotInvalidation)

        let seeWithWebFocus = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["webFocus"]),
            commandType: SeeCommand.self
        )
        #expect(seeWithWebFocus.requiresImplicitSnapshotInvalidation)
        let seeDefault = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: SeeCommand.self
        )
        #expect(!seeDefault.requiresImplicitSnapshotInvalidation)
        let seeWithoutWebFocus = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["noWebFocus"]),
            commandType: SeeCommand.self
        )
        #expect(!seeWithoutWebFocus.requiresImplicitSnapshotInvalidation)
    }

    @Test
    func `Menu list requires invalidation only when auto focus may run`() throws {
        let background = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: MenuCommand.ListSubcommand.self
        )
        #expect(!background.requiresImplicitSnapshotInvalidation)

        let foreground = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["foreground"]),
            commandType: MenuCommand.ListSubcommand.self
        )
        #expect(foreground.requiresImplicitSnapshotInvalidation)

        let foregroundWithoutFocus = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["foreground", "noAutoFocus"]),
            commandType: MenuCommand.ListSubcommand.self
        )
        #expect(!foregroundWithoutFocus.requiresImplicitSnapshotInvalidation)
    }

    @Test
    func `Clipboard writes require caller-side invalidation while reads and saves do not`() throws {
        let mutatingCommands: [any ParsableCommand.Type] = [
            ClipboardCommand.SetSubcommand.self,
            ClipboardCommand.ClearSubcommand.self,
            ClipboardCommand.RestoreSubcommand.self,
        ]
        for commandType in mutatingCommands {
            let options = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: [], options: [:], flags: []),
                commandType: commandType
            )
            #expect(options.requiresImplicitSnapshotInvalidation, "Missing clipboard invalidation: \(commandType)")
            #expect(options.requiresCallerDesktopMutationBarrier, "Missing clipboard barrier: \(commandType)")
        }

        let readOnlyCommands: [any ParsableCommand.Type] = [
            ClipboardCommand.GetSubcommand.self,
            ClipboardCommand.SaveSubcommand.self,
        ]
        for commandType in readOnlyCommands {
            let options = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: [], options: [:], flags: []),
                commandType: commandType
            )
            #expect(!options.requiresImplicitSnapshotInvalidation, "Unexpected invalidation: \(commandType)")
            #expect(!options.requiresCallerDesktopMutationBarrier, "Unexpected barrier: \(commandType)")
        }
    }

    @Test
    func `Interactive permission requests invalidate implicit snapshots`() throws {
        for kind in ["screen-recording", "accessibility", "event-synthesizing"] {
            let options = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: [kind], options: [:], flags: []),
                commandType: PermissionsCommand.RequestSubcommand.self
            )
            #expect(options.requiresImplicitSnapshotInvalidation, "Missing invalidation: \(kind)")
            #expect(!options.requiresCallerDesktopMutationBarrier, "Unexpected caller barrier: \(kind)")
        }

        for kind in ["screen-recording", "accessibility"] {
            let options = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: [kind], options: [:], flags: []),
                commandType: PermissionsCommand.RequestSubcommand.self
            )
            #expect(!options.preferRemote, "Caller-local prompt routed remotely: \(kind)")

            let explicitSocketOptions = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(
                    positional: [kind],
                    options: ["bridge-socket": ["/tmp/permission-host.sock"]],
                    flags: []
                ),
                commandType: PermissionsCommand.RequestSubcommand.self
            )
            #expect(
                !explicitSocketOptions.preferRemote,
                "Explicit socket routed caller-local prompt remotely: \(kind)"
            )
            #expect(explicitSocketOptions.bridgeSocketPath == "/tmp/permission-host.sock")
        }
    }

    @Test
    func `Capture commands require invalidation only when their focus policy may mutate the desktop`() throws {
        let ownerAwareBridge = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen, .desktopObservation],
            hostCapabilities: [PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership]
        ).withProducerBoundSnapshotFixture()

        let readOnlyCaptures: [(any ParsableCommand.Type, ParsedValues)] = [
            (SeeCommand.self, ParsedValues(positional: [], options: [:], flags: [])),
            (SeeCommand.self, ParsedValues(
                positional: [],
                options: ["mode": ["screen"], "app": ["TextEdit"]],
                flags: []
            )),
            (SeeCommand.self, ParsedValues(
                positional: [],
                options: ["app": ["TextEdit"]],
                flags: []
            )),
            (CaptureLiveCommand.self, ParsedValues(
                positional: [],
                options: ["mode": ["screen"], "app": ["TextEdit"]],
                flags: []
            )),
            (CaptureLiveCommand.self, ParsedValues(
                positional: [],
                options: ["app": ["TextEdit"]],
                flags: []
            )),
            (CaptureLiveCommand.self, ParsedValues(
                positional: [],
                options: ["app": ["TextEdit"], "captureFocus": ["background"]],
                flags: []
            )),
        ]

        for (commandType, parsed) in readOnlyCaptures {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(!options.requiresImplicitSnapshotInvalidation, "Unexpected invalidation: \(commandType)")
            #expect(CommandRuntime.supportsRemoteRequirements(for: ownerAwareBridge, options: options))
        }

        let focusingCaptures: [(any ParsableCommand.Type, ParsedValues)] = [
            (CaptureLiveCommand.self, ParsedValues(
                positional: [],
                options: ["app": ["TextEdit"], "captureFocus": ["foreground"]],
                flags: []
            )),
        ]

        for (commandType, parsed) in focusingCaptures {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(options.requiresImplicitSnapshotInvalidation, "Missing invalidation: \(commandType)")
        }
    }

    @Test
    func `Implicit snapshot invalidation requires protocol and enabled operation`() {
        let operations: [PeekabooBridgeOperation] = [
            .captureScreen,
            .invalidateImplicitLatestSnapshot,
        ]
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations
        )
        let stale = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 8),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations
        )
        let missing = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen]
        )
        let disabled = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            enabledOperations: [.captureScreen]
        )
        var options = CommandRuntimeOptions()
        options.requiresImplicitSnapshotInvalidation = true

        #expect(CommandRuntime.supportsImplicitSnapshotInvalidation(for: current))
        #expect(CommandRuntime.supportsRemoteRequirements(for: current, options: options))
        #expect(!CommandRuntime.supportsImplicitSnapshotInvalidation(for: stale))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: stale, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: missing, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: disabled, options: options))

        options.requiresImplicitSnapshotInvalidation = false
        options.usesPerToolSnapshotInvalidation = true
        #expect(CommandRuntime.supportsRemoteRequirements(for: current, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: stale, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: missing, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: disabled, options: options))
    }

    @Test
    func `Snapshot mutation leases require protocol and both enabled operations`() {
        let operations: [PeekabooBridgeOperation] = [.beginSnapshotMutation, .finishSnapshotMutation]
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.snapshotMutationLeaseVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations
        )
        let stale = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 23),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations
        )
        let missing = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.snapshotMutationLeaseVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.beginSnapshotMutation]
        )
        let disabled = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.snapshotMutationLeaseVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            enabledOperations: [.beginSnapshotMutation]
        )

        #expect(CommandRuntime.supportsSnapshotMutationLeases(for: current))
        #expect(!CommandRuntime.supportsSnapshotMutationLeases(for: stale))
        #expect(!CommandRuntime.supportsSnapshotMutationLeases(for: missing))
        #expect(!CommandRuntime.supportsSnapshotMutationLeases(for: disabled))
    }

    @Test
    func `Background press requires process-generation-pinned Bridge hotkeys`() throws {
        let background = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["a"], options: ["pid": ["42"]], flags: []),
            commandType: PressCommand.self
        )
        let foreground = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["a"], options: [:], flags: ["foreground"]),
            commandType: PressCommand.self
        )
        let operations: [PeekabooBridgeOperation] = [
            .targetedHotkey,
            .invalidateImplicitLatestSnapshot,
        ]
        let legacy = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 18),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            enabledOperations: operations
        )
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationPinnedHotkeyVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            enabledOperations: operations
        )

        #expect(background.requiresProcessGenerationPinnedHotkeys)
        #expect(!foreground.requiresProcessGenerationPinnedHotkeys)
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: background))
        #expect(CommandRuntime.supportsRemoteRequirements(for: current, options: background))
        #expect(CommandRuntime.supportsRemoteRequirements(for: legacy, options: foreground))
    }

    @Test
    func `Process-targeted input requires Bridge protocol 1_22 receipts`() throws {
        let type = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["hello"], options: ["app": ["TextEdit"]], flags: []),
            commandType: TypeCommand.self
        )
        let click = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: ["on": ["B1"]], flags: []),
            commandType: ClickCommand.self
        )
        let exactClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"], "windowId": ["42"], "app": ["TextEdit"]],
                flags: []
            ),
            commandType: ClickCommand.self
        )
        let paste = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["hello"], options: ["app": ["TextEdit"]], flags: []),
            commandType: PasteCommand.self
        )
        let foreground = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["hello"], options: [:], flags: ["foreground"]),
            commandType: TypeCommand.self
        )
        let operations: [PeekabooBridgeOperation] = [
            .targetedHotkey,
            .targetedTypeActions,
            .targetedClick,
            .exactWindowTargetedClick,
            .invalidateImplicitLatestSnapshot,
        ]
        let legacy = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 21),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            permissions: PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: operations
        )
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationPinnedInteractionVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            permissions: PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: operations
        )
        let policyCapable = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.targetedClickAccessibilityValueDeliveryVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            permissions: PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: operations,
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery,
            ]
        )

        #expect(type.requiresProcessGenerationPinnedTypeActions)
        #expect(click.requiresProcessGenerationPinnedClicks)
        #expect(click.requiresTargetedClickAccessibilityValueDelivery)
        #expect(!exactClick.requiresProcessGenerationPinnedClicks)
        #expect(exactClick.requiresTargetedClickAccessibilityValueDelivery)
        #expect(paste.requiresProcessGenerationPinnedTypeActions)
        #expect(paste.requiresProcessGenerationPinnedHotkeys)
        #expect(!foreground.requiresProcessGenerationPinnedTypeActions)
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: type))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: click))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: paste))
        #expect(CommandRuntime.supportsRemoteRequirements(for: current, options: type))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: current, options: click))
        #expect(CommandRuntime.supportsRemoteRequirements(for: current, options: paste))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: exactClick))
        #expect(CommandRuntime.supportsRemoteRequirements(for: policyCapable, options: click))
        #expect(CommandRuntime.supportsRemoteRequirements(for: policyCapable, options: exactClick))
        #expect(CommandRuntime.supportsRemoteRequirements(for: legacy, options: foreground))
    }

    @Test
    func `Click delivery selects the permission required by its actual path`() throws {
        let coordinate = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["at": ["10,20"]],
                flags: []
            ),
            commandType: ClickCommand.self
        )
        let coordinateDouble = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["at": ["10,20"]],
                flags: ["double"]
            ),
            commandType: ClickCommand.self
        )
        let coordinateRight = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["at": ["10,20"]],
                flags: ["right"]
            ),
            commandType: ClickCommand.self
        )
        let unconsentedLongPress = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["longPress"]
            ),
            commandType: ClickCommand.self
        )
        let longPress = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["longPress", "foreground"]
            ),
            commandType: ClickCommand.self
        )
        let doubleClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["double"]
            ),
            commandType: ClickCommand.self
        )
        let singleClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: []
            ),
            commandType: ClickCommand.self
        )
        let rightClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["right"]
            ),
            commandType: ClickCommand.self
        )
        let conflictingVariants = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["double", "right"]
            ),
            commandType: ClickCommand.self
        )
        let foregroundCoordinate = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["at": ["10,20"]],
                flags: ["foreground"]
            ),
            commandType: ClickCommand.self
        )
        let foregroundDoubleClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["double", "foreground"]
            ),
            commandType: ClickCommand.self
        )

        #expect(!coordinate.requiresPostEventPermission)
        #expect(coordinateDouble.requiresPostEventPermission)
        #expect(coordinateRight.requiresPostEventPermission)
        #expect(!unconsentedLongPress.requiresPostEventPermission)
        #expect(!unconsentedLongPress.requiresLongPressClick)
        #expect(unconsentedLongPress.requiresAccessibilityPermission)
        #expect(longPress.requiresPostEventPermission)
        #expect(longPress.requiresLongPressClick)
        #expect(!longPress.requiresAccessibilityPermission)
        #expect(doubleClick.requiresPostEventPermission)
        #expect(!singleClick.requiresPostEventPermission)
        #expect(!rightClick.requiresPostEventPermission)
        #expect(conflictingVariants.requiresPostEventPermission)
        #expect(foregroundCoordinate.requiresPostEventPermission)
        #expect(foregroundDoubleClick.requiresPostEventPermission)
        #expect(coordinate.requiresAccessibilityPermission)
        #expect(singleClick.requiresAccessibilityPermission)
        #expect(!foregroundCoordinate.requiresAccessibilityPermission)

        let operations: [PeekabooBridgeOperation] = [
            .captureScreen,
            .invalidateImplicitLatestSnapshot,
            .targetedClick,
        ]
        let accessibilityOnly = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.targetedClickAccessibilityValueDeliveryVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: false
            ),
            enabledOperations: operations,
            permissionTags: [PeekabooBridgeOperation.targetedClick.rawValue: []],
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery,
            ]
        )
        let fullyPermitted = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.targetedClickAccessibilityValueDeliveryVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: true
            ),
            enabledOperations: operations,
            permissionTags: [PeekabooBridgeOperation.targetedClick.rawValue: []],
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery,
            ]
        )

        #expect(CommandRuntime.supportsRemoteRequirements(for: accessibilityOnly, options: singleClick))
        #expect(CommandRuntime.supportsRemoteRequirements(for: accessibilityOnly, options: rightClick))
        #expect(CommandRuntime.supportsRemoteRequirements(for: accessibilityOnly, options: coordinate))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: accessibilityOnly, options: doubleClick))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: accessibilityOnly, options: foregroundCoordinate))
        #expect(CommandRuntime.supportsRemoteRequirements(for: fullyPermitted, options: coordinate))
        #expect(CommandRuntime.supportsRemoteRequirements(for: fullyPermitted, options: doubleClick))
        #expect(CommandRuntime.supportsRemoteRequirements(for: fullyPermitted, options: foregroundCoordinate))
    }
}

extension CommanderBinderTests {
    @Test
    func `Background scroll requires strict targeted bridge capability`() throws {
        let background = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["direction": ["down"], "on": ["S1"]],
                flags: []
            ),
            commandType: ScrollCommand.self
        )
        let foreground = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["direction": ["down"]],
                flags: ["foreground"]
            ),
            commandType: ScrollCommand.self
        )

        #expect(background.requiresTargetedScroll)
        #expect(background.requiresAccessibilityPermission)
        #expect(!background.requiresPostEventPermission)
        #expect(!foreground.requiresTargetedScroll)
        #expect(!foreground.requiresAccessibilityPermission)
        #expect(foreground.requiresPostEventPermission)

        let legacy = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 10),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen, .scroll, .invalidateImplicitLatestSnapshot],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: true
            ),
            enabledOperations: [.captureScreen, .scroll, .invalidateImplicitLatestSnapshot]
        )
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen, .scroll, .targetedScroll, .invalidateImplicitLatestSnapshot],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: true
            ),
            enabledOperations: [.captureScreen, .scroll, .targetedScroll, .invalidateImplicitLatestSnapshot],
            hostCapabilities: [PeekabooBridgeHostCapability.requestPinnedExactWindowScrollReceipt]
        ).withProducerBoundSnapshotFixture()
        let receiptlessCurrent = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen, .scroll, .targetedScroll, .invalidateImplicitLatestSnapshot],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: true
            ),
            enabledOperations: [.captureScreen, .scroll, .targetedScroll, .invalidateImplicitLatestSnapshot],
            hostCapabilities: [PeekabooBridgeHostCapability.requestPinnedExactWindowScrollReceipt]
        )

        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: background))
        #expect(CommandRuntime.supportsRemoteRequirements(for: current, options: background))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: receiptlessCurrent, options: background))
        #expect(CommandRuntime.supportsRemoteRequirements(for: legacy, options: foreground))
    }

    @Test
    func `Background exact-window clicks require an enabled bridge capability`() throws {
        let explicitWindow = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["windowId": ["42"]],
                flags: []
            ),
            commandType: ClickCommand.self
        )
        let relativeAppCoordinates = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["at": ["10,20"], "app": ["TextEdit"]],
                flags: []
            ),
            commandType: ClickCommand.self
        )
        let globalAppCoordinates = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["at": ["10,20"], "app": ["TextEdit"]],
                flags: ["global"]
            ),
            commandType: ClickCommand.self
        )
        let foregroundWindow = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["windowId": ["42"]],
                flags: ["foreground"]
            ),
            commandType: ClickCommand.self
        )
        let longPressWindow = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["windowId": ["42"]],
                flags: ["longPress", "foreground"]
            ),
            commandType: ClickCommand.self
        )

        #expect(explicitWindow.requiresExactWindowTargetedClicks)
        #expect(relativeAppCoordinates.requiresExactWindowTargetedClicks)
        #expect(!globalAppCoordinates.requiresExactWindowTargetedClicks)
        #expect(!foregroundWindow.requiresExactWindowTargetedClicks)
        #expect(!longPressWindow.requiresExactWindowTargetedClicks)

        let operations: [PeekabooBridgeOperation] = [
            .captureScreen,
            .exactWindowTargetedClick,
        ]
        let capable = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 17),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations
        )
        let preCompletionValidation = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 16),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations
        )
        let missing = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 17),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen]
        )
        let disabled = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 17),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            enabledOperations: [.captureScreen]
        )
        var exactOptions = CommandRuntimeOptions()
        exactOptions.requiresExactWindowTargetedClicks = true

        #expect(CommandRuntime.supportsRemoteRequirements(for: capable, options: exactOptions))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: preCompletionValidation, options: exactOptions))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: missing, options: exactOptions))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: disabled, options: exactOptions))
    }

    @Test
    func `Relaunch requires the atomic bridge capability`() {
        let operations: [PeekabooBridgeOperation] = [
            .captureScreen,
            .launchApplicationWithOptions,
            .relaunchApplicationWithOptions,
        ]
        let capable = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 18),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations
        )
        let relaunchDisabled = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 18),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            enabledOperations: operations.filter { $0 != .relaunchApplicationWithOptions }
        )
        let guiHost = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 18),
            hostKind: .gui,
            build: nil,
            supportedOperations: operations
        )
        var options = CommandRuntimeOptions()
        options.requiresApplicationLaunchOptions = true
        options.requiresApplicationRelaunch = true

        #expect(CommandRuntime.supportsRemoteRequirements(for: capable, options: options))
        #expect(CommandRuntime.supportsApplicationRelaunch(for: capable))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: relaunchDisabled, options: options))
        #expect(!CommandRuntime.supportsApplicationRelaunch(for: guiHost))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: guiHost, options: options))
        for missingOperation in [
            PeekabooBridgeOperation.launchApplicationWithOptions,
            .relaunchApplicationWithOptions,
        ] {
            let incomplete = BridgeTestFixtures.handshake(
                negotiatedVersion: .init(major: 1, minor: 9),
                hostKind: .onDemand,
                build: nil,
                supportedOperations: operations.filter { $0 != missingOperation }
            )
            #expect(!CommandRuntime.supportsRemoteRequirements(for: incomplete, options: options))
        }

        options.requiresApplicationRelaunch = false
        let launchOnly = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .launchApplicationWithOptions]
        )
        #expect(CommandRuntime.supportsRemoteRequirements(for: launchOnly, options: options))
    }

    @Test
    func `Launch commands ignore unrelated input and capture runtime overrides`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "inputStrategy": ["actionFirst"],
                "captureEngine": ["cg"],
            ],
            flags: []
        )

        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: AppCommand.LaunchSubcommand.self
        )
        let ambientBase = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: AppCommand.LaunchSubcommand.self
        )
        let environmentOptions = ambientBase.applyingEnvironmentOverrides(environment: [
            "PEEKABOO_CAPTURE_ENGINE": "legacy",
        ])

        #expect(options.requiresApplicationLaunchOptions)
        #expect(options.preferRemote)
        #expect(environmentOptions.captureEnginePreference == "legacy")
        #expect(environmentOptions.preferRemote)
    }

    @Test
    func `Snapshot invalidation routes include explicit GUI and daemon sockets once`() {
        let paths = RuntimeHostResolver.snapshotInvalidationRemoteSocketPaths(
            explicitSocket: "/tmp/custom.sock",
            daemonSocketPath: PeekabooBridgeConstants.peekabooSocketPath
        )

        #expect(paths == [
            "/tmp/custom.sock",
            PeekabooBridgeConstants.peekabooSocketPath,
        ])
    }

    @Test
    func `Build-scoped daemon participates in routing and snapshot invalidation`() throws {
        let buildScopedPath = try #require(DaemonLaunchPolicy.buildScopedDaemonSocketPath(
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            runtimeBuildIdentity: "test-build"
        ))
        let historicalPath = URL(fileURLWithPath: PeekabooBridgeConstants.daemonSocketPath)
            .deletingLastPathComponent()
            .appendingPathComponent("daemon-bbbbbbbbbbbbbbbb.sock")
            .path
        let candidates = RuntimeHostResolver.implicitRemoteCandidates(
            options: CommandRuntimeOptions(),
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            buildScopedDaemonSocketPath: buildScopedPath,
            historicalBuildScopedDaemonSocketPaths: [buildScopedPath, historicalPath, historicalPath]
        )
        let invalidationPaths = RuntimeHostResolver.snapshotInvalidationRemoteSocketPaths(
            explicitSocket: nil,
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            buildScopedDaemonSocketPath: buildScopedPath,
            historicalBuildScopedDaemonSocketPaths: [historicalPath, historicalPath]
        )

        #expect(Array(candidates.map(\.socketPath).prefix(3)) == [
            buildScopedPath,
            PeekabooBridgeConstants.daemonSocketPath,
            historicalPath,
        ])
        #expect(candidates[0].requiresValidatedHistoricalDaemon == false)
        #expect(candidates[1].requiresValidatedHistoricalDaemon == false)
        #expect(candidates[2].requiredHostKind == .onDemand)
        #expect(candidates[2].requiresValidatedHistoricalDaemon)
        #expect(invalidationPaths.count(where: { $0 == buildScopedPath }) == 1)
        #expect(invalidationPaths.count(where: { $0 == historicalPath }) == 1)
    }

    @Test
    func `Historical daemon discovery preserves explicit and custom socket isolation`() {
        #expect(RuntimeHostResolver.shouldDiscoverHistoricalDaemons(
            explicitSocket: nil,
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath
        ))
        #expect(!RuntimeHostResolver.shouldDiscoverHistoricalDaemons(
            explicitSocket: "/tmp/explicit.sock",
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath
        ))
        #expect(!RuntimeHostResolver.shouldDiscoverHistoricalDaemons(
            explicitSocket: nil,
            daemonSocketPath: "/tmp/custom-daemon.sock"
        ))
    }

    @Test
    func `Element action commands require bridge element action support`() throws {
        let setValueOptions = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: SetValueCommand.self
        )
        let performActionOptions = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: ActionCommand.self
        )
        let seeOptions = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: SeeCommand.self
        )

        #expect(setValueOptions.requiredElementActionOperations == [.setValue])
        #expect(performActionOptions.requiredElementActionOperations == [.performAction])
        #expect(seeOptions.requiredElementActionOperations.isEmpty)
    }

    @Test
    func `Remote requirements skip bridges missing required element action support`() {
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .setValue, .performAction],
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.setValueResultTargetBinding,
                PeekabooBridgeHostCapability.processGenerationBoundElementMutations,
            ]
        )
        let oldProtocol = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 36),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .setValue, .performAction],
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.setValueResultTargetBinding,
                PeekabooBridgeHostCapability.processGenerationBoundElementMutations,
            ]
        )
        let ordinaryOptions = CommandRuntimeOptions()
        var elementActionOptions = CommandRuntimeOptions()
        elementActionOptions.requiredElementActionOperations = [.setValue]

        #expect(CommandRuntime.supportsRemoteRequirements(for: current, options: elementActionOptions))
        #expect(CommandRuntime.supportsRemoteRequirements(for: oldProtocol, options: ordinaryOptions))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: oldProtocol, options: elementActionOptions))
        #expect(CommandRuntime.supportsRemoteRequirements(for: oldProtocol, options: ordinaryOptions))
    }

    @Test
    func `Runtime options validate log level`() {
        let parsed = ParsedValues(positional: [], options: ["logLevel": ["nope"]], flags: [])
        #expect(throws: CommanderBindingError.invalidArgument(
            label: "logLevel",
            value: "nope",
            reason: "Unable to parse LogLevel"
        )) {
            _ = try CommanderCLIBinder.makeRuntimeOptions(from: parsed)
        }
    }

    @Test
    func `Runtime options validate input strategy`() {
        let parsed = ParsedValues(positional: [], options: ["inputStrategy": ["nope"]], flags: [])
        #expect(throws: CommanderBindingError.invalidArgument(
            label: "input-strategy",
            value: "nope",
            reason: "expected one of actionFirst, synthFirst, actionOnly, synthOnly"
        )) {
            _ = try CommanderCLIBinder.makeRuntimeOptions(from: parsed)
        }
    }

    @Test
    func `Agent runtime defaults to local host mode`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: AgentRunSubcommand.self)
        #expect(options.preferRemote == false)
        #expect(options.usesPerToolSnapshotInvalidation)
        #expect(!options.requiresImplicitSnapshotInvalidation)
    }

    @Test
    func `Agent runtime honors explicit bridge socket`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: ["bridge-socket": ["/tmp/agent-host.sock"]],
            flags: []
        )
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: AgentRunSubcommand.self)

        #expect(options.preferRemote)
        #expect(options.bridgeSocketPath == "/tmp/agent-host.sock")
    }

    @Test
    func `Agent runtime honors bridge socket environment override`() throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: AgentRunSubcommand.self,
            environment: ["PEEKABOO_BRIDGE_SOCKET": "/tmp/agent-host.sock"]
        )

        #expect(options.preferRemote)
    }

    @Test
    func `Agent no remote flag wins over bridge socket environment override`() throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["no-remote"]),
            commandType: AgentRunSubcommand.self,
            environment: ["PEEKABOO_BRIDGE_SOCKET": "/tmp/agent-host.sock"]
        )

        #expect(!options.preferRemote)
        #expect(options.remoteIsolationRequested)
    }

    @Test
    func `Long-lived tool runtimes discover sibling snapshot hosts while staying local`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        for commandType in [AgentRunSubcommand.self, MCPCommand.Serve.self] as [any ParsableCommand.Type] {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(options.usesPerToolSnapshotInvalidation)
            #expect(!options.requiresScreenCaptureKitOwnerCapability)
            #expect(!options.preferRemote)
            #expect(RuntimeHostResolver.shouldResolveKnownRemoteEndpoints(
                options: options,
                environment: [:],
                configurationInput: nil
            ))
            #expect(RuntimeHostResolver.initialRoutingDecision(
                options: options,
                environment: [:],
                configurationInput: nil,
                knownSnapshotInvalidationRemoteSocketPaths: ["/tmp/sibling.sock"]
            ) == .local(
                snapshotInvalidationRemoteSocketPaths: ["/tmp/sibling.sock"]
            ))
        }
    }

    @Test
    func `Automation runtime keeps remote daemon mode by default`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: SeeCommand.self)
        #expect(options.preferRemote == true)
    }

    @Test
    func `Pure local runtime commands do not auto start daemon`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let toolsOptions = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: ToolsCommand.self)

        #expect(toolsOptions.preferRemote == false)
    }

    @Test
    func `Image runtime defaults to daemon host mode`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: SeeCommand.self)
        #expect(options.preferRemote == true)
    }

    @Test
    func `See runtime defaults to daemon host mode`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: SeeCommand.self)
        #expect(options.preferRemote == true)
    }

    @Test
    func `Local inventory runtimes default to local host mode`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let commandTypes: [any ParsableCommand.Type] = [
            ToolsCommand.self,
        ]

        for commandType in commandTypes {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(options.preferRemote == false)
        }
    }

    @Test
    func `Application list runtimes use bridge host inventory`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let commandTypes: [any ParsableCommand.Type] = [
            AppCommand.ListSubcommand.self,
        ]

        for commandType in commandTypes {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(options.preferRemote == true)
            #expect(options.requiresHostApplicationInventory)
            #expect(!options.requiresApplicationLaunchOptions)
        }
    }

    @Test
    func `Application inventory requires an enabled bridge operation`() {
        var options = CommandRuntimeOptions()
        options.requiresHostApplicationInventory = true
        let legacyCapable = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 8),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen, .listApplications]
        )
        let unsupported = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen]
        )
        let disabled = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .listApplications],
            enabledOperations: [.captureScreen]
        )
        let preProtocol = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 0, minor: 9),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen, .listApplications]
        )

        #expect(CommandRuntime.supportsRemoteRequirements(for: legacyCapable, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: unsupported, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: disabled, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: preProtocol, options: options))

        options.requiresHostApplicationInventory = false
        #expect(CommandRuntime.supportsRemoteRequirements(for: unsupported, options: options))
    }

    @Test
    func `Application inventory ignores unrelated automation runtime overrides`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "inputStrategy": ["actionFirst"],
                "captureEngine": ["cg"],
            ],
            flags: []
        )
        let commandTypes: [any ParsableCommand.Type] = [
            AppCommand.ListSubcommand.self,
        ]

        for commandType in commandTypes {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            let environmentOptions = options.applyingEnvironmentOverrides(environment: [
                "PEEKABOO_CAPTURE_ENGINE": "legacy",
            ])

            #expect(options.preferRemote)
            #expect(options.requiresHostApplicationInventory)
            #expect(environmentOptions.preferRemote)
            #expect(!RuntimeHostResolver.inputPolicyRequiresLocal(
                options: options,
                environment: ["PEEKABOO_INPUT_STRATEGY": "synthOnly"],
                configurationInput: Configuration.InputConfig(click: .synthOnly)
            ))
        }
    }

    @Test
    func `Ordinary automation still honors input policy local routing`() {
        var options = CommandRuntimeOptions()
        options.inputStrategy = .actionFirst

        #expect(RuntimeHostResolver.inputPolicyRequiresLocal(
            options: options,
            environment: [:],
            configurationInput: nil
        ))
    }

    @Test
    func `List screens runtime defaults to local host mode`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: ScreenCommand.ListSubcommand.self
        )
        #expect(options.preferRemote == false)
    }

    @Test
    func `Permission inventory keeps remote host mode by default`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: PermissionsCommand.StatusSubcommand.self
        )
        #expect(options.preferRemote == true)
    }

    @Test
    func `Screen recording permission request uses local host mode`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: PermissionsCommand.RequestSubcommand.self
        )
        #expect(options.preferRemote == false)
    }

    @Test
    func `Image runtime honors explicit bridge socket`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: ["bridge-socket": ["/tmp/peekaboo.sock"]],
            flags: []
        )
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: SeeCommand.self)
        #expect(options.preferRemote == true)
        #expect(options.bridgeSocketPath == "/tmp/peekaboo.sock")
    }

    @Test
    func `See runtime honors explicit bridge socket`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: ["bridge-socket": ["/tmp/peekaboo.sock"]],
            flags: []
        )
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: SeeCommand.self)
        #expect(options.preferRemote == true)
        #expect(options.bridgeSocketPath == "/tmp/peekaboo.sock")
    }

    @Test
    func `Permission request commands opt out of host permission gating`() throws {
        let parsed = ParsedValues(positional: ["event-synthesizing"], options: [:], flags: [])
        let requestOptions = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: PermissionsCommand.RequestSubcommand.self
        )
        let captureOptions = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: SeeCommand.self
        )
        #expect(requestOptions.requestsHostPermissionGrant)
        #expect(!captureOptions.requestsHostPermissionGrant)
    }

    @Test
    func `Screen capture permission is required only by capture commands`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let captureCommands: [any ParsableCommand.Type] = [
            SeeCommand.self,
            CaptureLiveCommand.self,
            CaptureActionCommand.self,
        ]
        for commandType in captureCommands {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(options.requiresScreenCapturePermission, "Expected capture gating for \(commandType)")
        }

        let nonCaptureCommands: [any ParsableCommand.Type] = [
            CaptureVideoCommand.self,
            ClickCommand.self,
            ScrollCommand.self,
            TypeCommand.self,
            AppCommand.LaunchSubcommand.self,
            AppCommand.ListSubcommand.self,
        ]
        for commandType in nonCaptureCommands {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(!options.requiresScreenCapturePermission, "Unexpected capture gating for \(commandType)")
        }
        let treeOnly = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["tree", "noScreenshot"]),
            commandType: SeeCommand.self
        )
        #expect(!treeOnly.requiresScreenCapturePermission)
        #expect(treeOnly.requiresInspectAccessibilityTree)
    }

    @Test
    func `Commands with implicit silent observation reject pre-1_12 bridge hosts`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let silentCommands: [(any ParsableCommand.Type, ParsedValues)] = [
            (SeeCommand.self, parsed),
            (CaptureLiveCommand.self, parsed),
            (CaptureActionCommand.self, parsed),
            (AgentRunSubcommand.self, parsed),
            (MCPCommand.Serve.self, parsed),
            (ClickCommand.self, ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["foreground"]
            )),
            (ScrollCommand.self, ParsedValues(
                positional: [],
                options: ["on": ["S1"]],
                flags: []
            )),
            (MoveCommand.self, ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["foreground"]
            )),
            (DragCommand.self, ParsedValues(
                positional: [],
                options: ["from": ["B1"], "to": ["B2"]],
                flags: ["foreground"]
            )),
        ]
        let legacy = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 11),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen]
        )
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 12),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen]
        )

        for (commandType, commandValues) in silentCommands {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: commandValues, commandType: commandType)
            #expect(options.requiresSilentCapture, "Expected silent-capture gating for \(commandType)")
        }

        let legacyVisualizerOnly = try [
            CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: [], options: ["on": ["B1"]], flags: []),
                commandType: ClickCommand.self
            ),
            CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: [], options: [:], flags: ["foreground"]),
                commandType: ScrollCommand.self
            ),
        ]
        #expect(legacyVisualizerOnly.allSatisfy { !$0.requiresSilentCapture })

        var silentOptions = CommandRuntimeOptions()
        silentOptions.requiresSilentCapture = true
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: silentOptions))
        #expect(CommandRuntime.supportsRemoteRequirements(for: current, options: silentOptions))
    }

    @Test
    func `Coordinate-only drag does not require silent capture`() throws {
        let coordinates = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["from": ["100,200"], "to": ["300,400"]],
                flags: ["foreground"]
            ),
            commandType: DragCommand.self
        )
        #expect(!coordinates.requiresSilentCapture)

        let elements = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["from": ["source-id"], "to": ["300,400"]],
                flags: ["foreground"]
            ),
            commandType: DragCommand.self
        )
        #expect(elements.requiresSilentCapture)
    }
}
