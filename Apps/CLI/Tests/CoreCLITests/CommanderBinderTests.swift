import Commander
import Foundation
import PeekabooAutomation
import PeekabooBridge
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
    func `Runtime options map capture engine option and force local mode`() throws {
        let parsed = ParsedValues(positional: [], options: ["captureEngine": ["cg"]], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: ImageCommand.self)
        #expect(options.captureEnginePreference == "cg")
        #expect(options.preferRemote == false)
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
        let current = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 3),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.setValue, .performAction]
        )
        let oldProtocol = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 2),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.setValue, .performAction]
        )
        let missingOperation = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 3),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.setValue]
        )

        #expect(CommandRuntime.supportsElementActions(for: current))
        #expect(!CommandRuntime.supportsElementActions(for: oldProtocol))
        #expect(!CommandRuntime.supportsElementActions(for: missingOperation))
    }

    @Test
    func `Application launch options require bridge protocol and operation support`() {
        let current = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.launchApplicationWithOptions]
        )
        let oldProtocol = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 8),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.launchApplicationWithOptions]
        )
        let missingOperation = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .gui,
            build: nil,
            supportedOperations: []
        )

        #expect(CommandRuntime.supportsApplicationLaunchOptions(for: current))
        #expect(!CommandRuntime.supportsApplicationLaunchOptions(for: oldProtocol))
        #expect(!CommandRuntime.supportsApplicationLaunchOptions(for: missingOperation))
    }

    @Test
    func `Launch commands require a bridge host with launch options`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let commandTypes: [any ParsableCommand.Type] = [
            OpenCommand.self,
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
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let commandTypes: [any ParsableCommand.Type] = [
            OpenCommand.self,
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
            HotkeyCommand.self,
            PasteCommand.self,
            ScrollCommand.self,
            SwipeCommand.self,
            DragCommand.self,
            SetValueCommand.self,
            PerformActionCommand.self,
            CaptureActionCommand.self,
            WindowCommand.FocusSubcommand.self,
            WindowCommand.CloseSubcommand.self,
            WindowCommand.MinimizeSubcommand.self,
            WindowCommand.MaximizeSubcommand.self,
            WindowCommand.MoveSubcommand.self,
            WindowCommand.ResizeSubcommand.self,
            WindowCommand.SetBoundsSubcommand.self,
            DialogCommand.ClickSubcommand.self,
            DialogCommand.DismissSubcommand.self,
            DialogCommand.InputSubcommand.self,
            DialogCommand.FileSubcommand.self,
            MenuCommand.ClickSubcommand.self,
            MenuCommand.ClickExtraSubcommand.self,
            MenuCommand.ListSubcommand.self,
            DockCommand.LaunchSubcommand.self,
            DockCommand.RightClickSubcommand.self,
            DockCommand.HideSubcommand.self,
            DockCommand.ShowSubcommand.self,
            SwitchSubcommand.self,
            MoveWindowSubcommand.self,
            RunCommand.self,
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
        let remoteHostedClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: ClickCommand.self
        )
        #expect(!remoteHostedClick.requiresCallerDesktopMutationBarrier)

        let inspectOptions = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: InspectUICommand.self
        )
        #expect(!inspectOptions.requiresImplicitSnapshotInvalidation)
        #expect(inspectOptions.usesPerToolSnapshotInvalidation)

        let menuBarClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["click"], options: [:], flags: []),
            commandType: MenuBarCommand.self
        )
        #expect(menuBarClick.requiresImplicitSnapshotInvalidation)
        let menuBarList = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["list"], options: [:], flags: []),
            commandType: MenuBarCommand.self
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
            from: parsed,
            commandType: SeeCommand.self
        )
        #expect(seeWithWebFocus.requiresImplicitSnapshotInvalidation)
        let seeWithoutWebFocus = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["noWebFocus"]),
            commandType: SeeCommand.self
        )
        #expect(seeWithoutWebFocus.requiresImplicitSnapshotInvalidation)

        let readOnly = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: ListCommand.AppsSubcommand.self
        )
        #expect(!readOnly.requiresImplicitSnapshotInvalidation)

        let untargetedDialogList = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: DialogCommand.ListSubcommand.self
        )
        #expect(!untargetedDialogList.requiresImplicitSnapshotInvalidation)

        let targetedDialogList = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: ["app": ["TextEdit"]], flags: []),
            commandType: DialogCommand.ListSubcommand.self
        )
        #expect(targetedDialogList.requiresImplicitSnapshotInvalidation)

        let backgroundDialogList = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["app": ["TextEdit"]],
                flags: ["noAutoFocus"]
            ),
            commandType: DialogCommand.ListSubcommand.self
        )
        #expect(!backgroundDialogList.requiresImplicitSnapshotInvalidation)

        for option in ["windowId", "windowTitle", "windowIndex"] {
            let targetedBackgroundDialogList = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(
                    positional: [],
                    options: [option: ["1"]],
                    flags: ["noAutoFocus"]
                ),
                commandType: DialogCommand.ListSubcommand.self
            )
            #expect(
                targetedBackgroundDialogList.requiresImplicitSnapshotInvalidation,
                "Window-targeted dialog lookup may use visibility assist: \(option)"
            )
        }
    }

    @Test
    func `Menu list requires invalidation only when auto focus may run`() throws {
        let autoFocus = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: MenuCommand.ListSubcommand.self
        )
        #expect(autoFocus.requiresImplicitSnapshotInvalidation)

        let background = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["noAutoFocus"]),
            commandType: MenuCommand.ListSubcommand.self
        )
        #expect(!background.requiresImplicitSnapshotInvalidation)
    }

    @Test
    func `Clipboard writes require caller-side invalidation while reads and saves do not`() throws {
        for action in ["set", "load", "clear", "restore"] {
            let options = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: [action], options: [:], flags: []),
                commandType: ClipboardCommand.self
            )
            #expect(options.requiresImplicitSnapshotInvalidation, "Missing clipboard invalidation: \(action)")
            #expect(options.requiresCallerDesktopMutationBarrier, "Missing clipboard barrier: \(action)")
        }

        let optionAlias = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: ["actionOption": ["set"]], flags: []),
            commandType: ClipboardCommand.self
        )
        #expect(optionAlias.requiresImplicitSnapshotInvalidation)
        #expect(optionAlias.requiresCallerDesktopMutationBarrier)

        let optionAfterEmptyPositional = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: ["  "],
                options: ["actionOption": ["set"]],
                flags: []
            ),
            commandType: ClipboardCommand.self
        )
        #expect(optionAfterEmptyPositional.requiresImplicitSnapshotInvalidation)
        #expect(optionAfterEmptyPositional.requiresCallerDesktopMutationBarrier)

        for action in ["get", "save"] {
            let options = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: [action], options: [:], flags: []),
                commandType: ClipboardCommand.self
            )
            #expect(!options.requiresImplicitSnapshotInvalidation, "Unexpected clipboard invalidation: \(action)")
            #expect(!options.requiresCallerDesktopMutationBarrier, "Unexpected clipboard barrier: \(action)")
        }
    }

    @Test
    func `Interactive permission requests invalidate implicit snapshots`() throws {
        let commandTypes: [any ParsableCommand.Type] = [
            PermissionsCommand.RequestScreenRecordingSubcommand.self,
            PermissionsCommand.RequestEventSynthesizingSubcommand.self,
            PermissionCommand.RequestScreenRecordingSubcommand.self,
            PermissionCommand.RequestAccessibilitySubcommand.self,
            PermissionCommand.RequestEventSynthesizingSubcommand.self,
        ]

        for commandType in commandTypes {
            let options = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: [], options: [:], flags: []),
                commandType: commandType
            )
            #expect(options.requiresImplicitSnapshotInvalidation, "Missing invalidation: \(commandType)")
            #expect(!options.requiresCallerDesktopMutationBarrier, "Unexpected caller barrier: \(commandType)")
        }

        let callerLocalCommandTypes: [any ParsableCommand.Type] = [
            PermissionsCommand.RequestScreenRecordingSubcommand.self,
            PermissionCommand.RequestScreenRecordingSubcommand.self,
            PermissionCommand.RequestAccessibilitySubcommand.self,
        ]
        for commandType in callerLocalCommandTypes {
            let options = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: [], options: [:], flags: []),
                commandType: commandType
            )
            #expect(!options.preferRemote, "Caller-local prompt routed remotely: \(commandType)")

            let explicitSocketOptions = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(
                    positional: [],
                    options: ["bridge-socket": ["/tmp/permission-host.sock"]],
                    flags: []
                ),
                commandType: commandType
            )
            #expect(
                !explicitSocketOptions.preferRemote,
                "Explicit socket routed caller-local prompt remotely: \(commandType)"
            )
            #expect(explicitSocketOptions.bridgeSocketPath == "/tmp/permission-host.sock")
        }
    }

    @Test
    func `Capture commands require invalidation only when their focus policy may mutate the desktop`() throws {
        let oldBridge = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 8),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen]
        )

        let readOnlyCaptures: [(any ParsableCommand.Type, ParsedValues)] = [
            (ImageCommand.self, ParsedValues(positional: [], options: [:], flags: [])),
            (ImageCommand.self, ParsedValues(
                positional: [],
                options: ["mode": ["screen"], "app": ["TextEdit"]],
                flags: []
            )),
            (ImageCommand.self, ParsedValues(
                positional: [],
                options: ["app": ["TextEdit"], "captureFocus": ["background"]],
                flags: []
            )),
            (ImageCommand.self, ParsedValues(
                positional: [],
                options: ["windowId": ["42"], "captureFocus": ["foreground"]],
                flags: []
            )),
            (CaptureLiveCommand.self, ParsedValues(
                positional: [],
                options: ["mode": ["screen"], "app": ["TextEdit"]],
                flags: []
            )),
            (CaptureLiveCommand.self, ParsedValues(
                positional: [],
                options: ["app": ["TextEdit"], "captureFocus": ["background"]],
                flags: []
            )),
            (CaptureWatchAlias.self, ParsedValues(
                positional: [],
                options: ["app": ["TextEdit"], "captureFocus": ["background"]],
                flags: []
            )),
        ]

        for (commandType, parsed) in readOnlyCaptures {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(!options.requiresImplicitSnapshotInvalidation, "Unexpected invalidation: \(commandType)")
            #expect(CommandRuntime.supportsRemoteRequirements(for: oldBridge, options: options))
        }

        let focusingCaptures: [(any ParsableCommand.Type, ParsedValues)] = [
            (ImageCommand.self, ParsedValues(
                positional: [],
                options: ["app": ["TextEdit"]],
                flags: []
            )),
            (ImageCommand.self, ParsedValues(
                positional: [],
                options: ["mode": ["multi"], "pid": ["123"]],
                flags: []
            )),
            (CaptureLiveCommand.self, ParsedValues(
                positional: [],
                options: ["app": ["TextEdit"]],
                flags: []
            )),
            (CaptureWatchAlias.self, ParsedValues(
                positional: [],
                options: ["mode": ["window"], "pid": ["123"]],
                flags: []
            )),
        ]

        for (commandType, parsed) in focusingCaptures {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(options.requiresImplicitSnapshotInvalidation, "Missing invalidation: \(commandType)")
            #expect(!CommandRuntime.supportsRemoteRequirements(for: oldBridge, options: options))
        }
    }

    @Test
    func `Implicit snapshot invalidation requires protocol and enabled operation`() {
        let operations: [PeekabooBridgeOperation] = [
            .captureScreen,
            .invalidateImplicitLatestSnapshot,
        ]
        let current = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations
        )
        let stale = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 8),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations
        )
        let missing = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen]
        )
        let disabled = PeekabooBridgeHandshakeResponse(
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
    func `Synthetic click variants require a post event capable bridge host`() throws {
        let coordinate = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["coords": ["10,20"]],
                flags: []
            ),
            commandType: ClickCommand.self
        )
        let coordinateDouble = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["coords": ["10,20"]],
                flags: ["double"]
            ),
            commandType: ClickCommand.self
        )
        let coordinateRight = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["coords": ["10,20"]],
                flags: ["right"]
            ),
            commandType: ClickCommand.self
        )
        let longPress = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["longPress"]
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
        let rightWinsConflictingFlags = try CommanderCLIBinder.makeRuntimeOptions(
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
                options: ["coords": ["10,20"]],
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

        #expect(coordinate.requiresPostEventClickPermission)
        #expect(coordinateDouble.requiresPostEventClickPermission)
        #expect(coordinateRight.requiresPostEventClickPermission)
        #expect(longPress.requiresPostEventClickPermission)
        #expect(longPress.requiresLongPressClick)
        #expect(doubleClick.requiresPostEventClickPermission)
        #expect(!singleClick.requiresPostEventClickPermission)
        #expect(!rightClick.requiresPostEventClickPermission)
        #expect(!rightWinsConflictingFlags.requiresPostEventClickPermission)
        #expect(!foregroundCoordinate.requiresPostEventClickPermission)
        #expect(!foregroundDoubleClick.requiresPostEventClickPermission)

        let operations: [PeekabooBridgeOperation] = [
            .captureScreen,
            .invalidateImplicitLatestSnapshot,
            .targetedClick,
        ]
        let accessibilityOnly = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: false
            ),
            enabledOperations: operations,
            permissionTags: [PeekabooBridgeOperation.targetedClick.rawValue: []]
        )
        let fullyPermitted = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: true
            ),
            enabledOperations: operations,
            permissionTags: [PeekabooBridgeOperation.targetedClick.rawValue: []]
        )

        #expect(CommandRuntime.supportsRemoteRequirements(for: accessibilityOnly, options: singleClick))
        #expect(CommandRuntime.supportsRemoteRequirements(for: accessibilityOnly, options: rightClick))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: accessibilityOnly, options: coordinate))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: accessibilityOnly, options: doubleClick))
        #expect(CommandRuntime.supportsRemoteRequirements(for: fullyPermitted, options: coordinate))
        #expect(CommandRuntime.supportsRemoteRequirements(for: fullyPermitted, options: doubleClick))
    }
}

extension CommanderBinderTests {
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
                options: ["coords": ["10,20"], "app": ["TextEdit"]],
                flags: []
            ),
            commandType: ClickCommand.self
        )
        let globalAppCoordinates = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["coords": ["10,20"], "app": ["TextEdit"]],
                flags: ["globalCoords"]
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
                flags: ["longPress"]
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
        let capable = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations
        )
        let missing = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen]
        )
        let disabled = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            enabledOperations: [.captureScreen]
        )
        var exactOptions = CommandRuntimeOptions()
        exactOptions.requiresExactWindowTargetedClicks = true

        #expect(CommandRuntime.supportsRemoteRequirements(for: capable, options: exactOptions))
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
        let capable = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations
        )
        let relaunchDisabled = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            enabledOperations: operations.filter { $0 != .relaunchApplicationWithOptions }
        )
        let guiHost = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
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
            let incomplete = PeekabooBridgeHandshakeResponse(
                negotiatedVersion: .init(major: 1, minor: 9),
                hostKind: .onDemand,
                build: nil,
                supportedOperations: operations.filter { $0 != missingOperation }
            )
            #expect(!CommandRuntime.supportsRemoteRequirements(for: incomplete, options: options))
        }

        options.requiresApplicationRelaunch = false
        let launchOnly = PeekabooBridgeHandshakeResponse(
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

        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: OpenCommand.self)
        let ambientBase = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: OpenCommand.self
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
            daemonSocketPath: "/tmp/peekaboo-daemon.sock"
        )

        #expect(candidates.map(\.socketPath) == [
            PeekabooBridgeConstants.peekabooSocketPath,
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
        ]
        let daemonHost = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations
        )
        let guiHost = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .gui,
            build: nil,
            supportedOperations: operations
        )
        #expect(CommandRuntime.supportsRemoteRequirements(for: daemonHost, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: guiHost, options: options))
    }

    @Test
    @MainActor
    func `Application inventory prefers GUI host before reusable daemon`() {
        var options = CommandRuntimeOptions()
        options.requiresHostApplicationInventory = true

        let candidates = RuntimeHostResolver.implicitRemoteCandidates(
            options: options,
            daemonSocketPath: "/tmp/peekaboo-daemon.sock"
        )

        #expect(candidates.map(\.socketPath) == [
            PeekabooBridgeConstants.peekabooSocketPath,
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
            PeekabooBridgeConstants.daemonSocketPath,
            buildScopedPath,
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
            commandType: PerformActionCommand.self
        )
        let seeOptions = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: SeeCommand.self
        )

        #expect(setValueOptions.requiresElementActions)
        #expect(performActionOptions.requiresElementActions)
        #expect(!seeOptions.requiresElementActions)
    }

    @Test
    func `Remote requirements skip bridges missing required element action support`() {
        let current = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 3),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .setValue, .performAction]
        )
        let oldProtocol = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 2),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .setValue, .performAction]
        )
        var ordinaryOptions = CommandRuntimeOptions()
        var elementActionOptions = CommandRuntimeOptions()
        elementActionOptions.requiresElementActions = true

        #expect(CommandRuntime.supportsRemoteRequirements(for: current, options: elementActionOptions))
        #expect(CommandRuntime.supportsRemoteRequirements(for: oldProtocol, options: ordinaryOptions))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: oldProtocol, options: elementActionOptions))

        ordinaryOptions.requiresElementActions = false
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
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: AgentCommand.self)
        #expect(options.preferRemote == false)
        #expect(options.usesPerToolSnapshotInvalidation)
        #expect(!options.requiresImplicitSnapshotInvalidation)
    }

    @Test
    func `Long-lived tool runtimes discover sibling snapshot hosts while staying local`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        for commandType in [AgentCommand.self, MCPCommand.Serve.self] as [any ParsableCommand.Type] {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(options.usesPerToolSnapshotInvalidation)
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
            ) == .local(snapshotInvalidationRemoteSocketPaths: ["/tmp/sibling.sock"]))
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
        let sleepOptions = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: SleepCommand.self)
        let toolsOptions = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: ToolsCommand.self)

        #expect(sleepOptions.preferRemote == false)
        #expect(toolsOptions.preferRemote == false)
    }

    @Test
    func `Image runtime defaults to daemon host mode`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: ImageCommand.self)
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
            ListCommand.AppsSubcommand.self,
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
        let legacyCapable = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 8),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen, .listApplications]
        )
        let unsupported = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen]
        )
        let disabled = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 9),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .listApplications],
            enabledOperations: [.captureScreen]
        )
        let preProtocol = PeekabooBridgeHandshakeResponse(
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
            ListCommand.AppsSubcommand.self,
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
    func `Stateful list inventory runtimes default to daemon host mode`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let commandTypes: [any ParsableCommand.Type] = [
            ListCommand.WindowsSubcommand.self,
            ListCommand.MenuBarSubcommand.self,
        ]

        for commandType in commandTypes {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(options.preferRemote == true)
        }
    }

    @Test
    func `List screens runtime defaults to local host mode`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: ListCommand.ScreensSubcommand.self
        )
        #expect(options.preferRemote == false)
    }

    @Test
    func `Permission inventory keeps remote host mode by default`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: ListCommand.PermissionsSubcommand.self
        )
        #expect(options.preferRemote == true)
    }

    @Test
    func `Screen recording permission request uses local host mode`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: PermissionsCommand.RequestScreenRecordingSubcommand.self
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
        let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: ImageCommand.self)
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
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let requestOptions = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: PermissionsCommand.RequestEventSynthesizingSubcommand.self
        )
        let captureOptions = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: ImageCommand.self
        )
        #expect(requestOptions.requestsHostPermissionGrant)
        #expect(!captureOptions.requestsHostPermissionGrant)
    }

    @Test
    func `Screen capture permission is required only by capture commands`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let captureCommands: [any ParsableCommand.Type] = [
            ImageCommand.self,
            SeeCommand.self,
            CaptureLiveCommand.self,
            CaptureWatchAlias.self,
            CaptureVideoCommand.self,
            CaptureActionCommand.self,
        ]
        for commandType in captureCommands {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(options.requiresScreenCapturePermission, "Expected capture gating for \(commandType)")
        }

        // `run` is intentionally NOT gated: its script may contain only non-capture steps, and the
        // steps are unknown at host-resolution time, so gating would push valid hosts away.
        let nonCaptureCommands: [any ParsableCommand.Type] = [
            ClickCommand.self,
            ScrollCommand.self,
            TypeCommand.self,
            AppCommand.LaunchSubcommand.self,
            ListCommand.AppsSubcommand.self,
            RunCommand.self,
        ]
        for commandType in nonCaptureCommands {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(!options.requiresScreenCapturePermission, "Unexpected capture gating for \(commandType)")
        }
    }
}
