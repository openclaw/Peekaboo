import Commander
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomationKit
import PeekabooFoundation

// MARK: - Binder

enum CommanderCLIBinder {
    static func instantiateCommand(
        type: any ParsableCommand.Type,
        parsedValues: ParsedValues
    ) throws -> any ParsableCommand {
        var command = type.init()
        let runtimeOptions = try makeRuntimeOptions(from: parsedValues, commandType: type)
        if var bindable = command as? any CommanderBindableCommand {
            try bindable.applyCommanderValues(.init(parsedValues: parsedValues))
            guard let rebound = bindable as? any ParsableCommand else {
                preconditionFailure("CommanderBindableCommand cast should always round-trip to original type \(type)")
            }
            command = rebound
        }
        if var configurable = command as? any RuntimeOptionsConfigurable {
            configurable.setRuntimeOptions(runtimeOptions)
            guard let rebound = configurable as? any ParsableCommand else {
                preconditionFailure("RuntimeOptionsConfigurable cast should always round-trip to original type \(type)")
            }
            command = rebound
        }
        return command
    }

    static func instantiateCommand<T: ParsableCommand>(
        ofType type: T.Type,
        parsedValues: ParsedValues
    ) throws -> T {
        guard let command = try instantiateCommand(type: type, parsedValues: parsedValues) as? T else {
            preconditionFailure("Commander instantiation failed to produce expected type \(T.self)")
        }
        return command
    }

    static func makeRuntimeOptions(
        from parsedValues: ParsedValues,
        commandType: (any ParsableCommand.Type)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CommandRuntimeOptions {
        var options = CommandRuntimeOptions()
        let commandValues = CommanderBindableValues(parsedValues: parsedValues)
        try Self.validateApplicationLifecycleBeforeRuntimeResolution(commandType, values: commandValues)
        try Self.validateDialogBeforeRuntimeResolution(commandType, values: commandValues)
        options.requiresApplicationLaunchOptions = Self.requiresApplicationLaunchOptions(commandType)
        options.requiresSafeBackgroundApplicationLaunchNoOp =
            commandType == AppCommand.LaunchSubcommand.self && !commandValues.flag("foreground")
        options.requiresNewApplicationInstanceLaunch = commandType == AppCommand.LaunchSubcommand.self &&
            commandValues.flag("newInstance")
        options.requiresApplicationWindowReadiness =
            commandType == AppCommand.LaunchSubcommand.self &&
            commandValues.flag("waitForWindow")
        options.requiresApplicationRelaunch = commandType == AppCommand.RelaunchSubcommand.self
        options.requiresSurvivingApplicationHost = commandType == AppCommand.QuitSubcommand.self
        options.requiresProcessGenerationPinnedApplicationQuit = commandType == AppCommand.QuitSubcommand.self
        options.requiresProcessGenerationPinnedApplicationActivation =
            commandType == AppCommand.FocusSubcommand.self ||
            commandType == AppCommand.UnhideSubcommand.self ||
            commandType == AppCommand.SwitchSubcommand.self
        options.requiresProcessGenerationPinnedApplicationHide = commandType == AppCommand.HideSubcommand.self
        options.requiresProcessGenerationPinnedHotkeys = commandType == PressCommand.self &&
            !commandValues.flag("foreground")
        let usesBackgroundInput = !commandValues.flag("foreground")
        options.requiresProcessGenerationPinnedTypeActions =
            (commandType == TypeCommand.self || commandType == PasteCommand.self) && usesBackgroundInput
        if commandType == PasteCommand.self, usesBackgroundInput {
            options.requiresProcessGenerationPinnedHotkeys = true
        }
        options.requiresHostApplicationInventory = Self.requiresHostApplicationInventory(commandType)
        let seeSkipsPixels = Self.applySeeRuntimeOptions(&options, commandType, values: commandValues)
        options.transportsCaptureEnginePreference = options.requiresDesktopObservation
        options.requiresScreenCaptureKitOwnerCapability = options.transportsCaptureEnginePreference
        options.ignoresCaptureEnginePreference = seeSkipsPixels
        options.requiresImplicitSnapshotInvalidation = Self.requiresImplicitSnapshotInvalidation(
            commandType,
            parsedValues: parsedValues
        )
        let resolvedSnapshotOption = commandValues.singleOption("snapshot").flatMap { value in
            value.isEmpty ? nil : value
        } ?? parsedValues.options["snapshot"]?.last
        if options.requiresImplicitSnapshotInvalidation,
           let snapshotID = resolvedSnapshotOption,
           !InteractionSnapshotReference.isLatestAlias(snapshotID) {
            guard SnapshotReference(rawValue: snapshotID) != nil else {
                throw ValidationError(
                    "Invalid snapshot reference '\(snapshotID)'; expected ps1_ followed by 32 lowercase " +
                        "hexadecimal digits"
                )
            }
            options.explicitSnapshotID = snapshotID
        }
        let clipboardMayMutate = Self.clipboardMayMutate(commandType)
        options.requiresCallerDesktopMutationBarrier = commandType == SwitchSubcommand.self ||
            commandType == MoveWindowSubcommand.self ||
            commandType == CaptureActionCommand.self ||
            clipboardMayMutate
        options.requiresExactWindowTargetedClicks = Self.requiresExactWindowTargetedClicks(
            commandType,
            parsedValues: parsedValues
        )
        options.requiresStatelessClickVariants = commandType == ClickCommand.self &&
            (commandValues.flag("middle") || commandValues.flag("triple"))
        options.requiresBackgroundStatelessClickVariants =
            options.requiresStatelessClickVariants && usesBackgroundInput
        options.requiresForegroundModifierClickSnapshotLease = commandType == ClickCommand.self &&
            commandValues.singleOption("modifiers") != nil
        options.requiresExactWindowPixelFocusTyping = commandType == TypeCommand.self &&
            commandValues.singleOption("at") != nil
        options.requiresProcessGenerationPinnedClicks = commandType == ClickCommand.self && usesBackgroundInput &&
            !options.requiresExactWindowTargetedClicks
        options.requiresTargetedClickAccessibilityValueDelivery = commandType == ClickCommand.self &&
            usesBackgroundInput
        let servesDynamicTools = Self.isAgentExecutionCommand(commandType) || commandType == MCPCommand.Serve.self
        options.requiresAgentService = servesDynamicTools
        if servesDynamicTools {
            options.requiresSafeBackgroundApplicationLaunchNoOp = true
            options.requiresProcessGenerationPinnedApplicationActivation = true
            options.requiresProcessGenerationPinnedHotkeys = true
            options.requiresProcessGenerationPinnedTypeActions = true
            options.requiresProcessGenerationPinnedClicks = true
            options.requiresTargetedClickAccessibilityValueDelivery = true
        }
        options.requiresTargetedScroll = commandType == ScrollCommand.self &&
            !commandValues.flag("foreground")
        options.requiresPostEventPermission = Self.requiresPostEventPermission(
            commandType,
            parsedValues: parsedValues
        )
        options.requiresAccessibilityPermission = Self.requiresAccessibilityPermission(
            commandType,
            parsedValues: parsedValues
        )
        options.requiresLongPressClick = commandType == ClickCommand.self &&
            commandValues.flag("longPress") && commandValues.flag("foreground")
        options.requiresBackgroundWindowClose = commandType == WindowCommand.CloseSubcommand.self &&
            !commandValues.flag("foreground")
        try Self.applyDialogRuntimeOptions(&options, commandType, commandValues, servesDynamicTools)
        options.requiresSilentCapture = Self.requiresSilentCapture(commandType, parsedValues: parsedValues)
        options.requiresExactWindowROIObservation = commandType == SeeCommand.self &&
            commandValues.singleOption("roi")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        options.requiresPinnedWindowMutations = Self.requiresPinnedWindowMutations(commandType)
        options.requiresWindowRestore = commandType == WindowCommand.RestoreSubcommand.self
        options.requiresScreenCapturePermission = Self.requiresScreenCapturePermission(
            commandType,
            parsedValues: parsedValues
        )
        options.requestsHostPermissionGrant = Self.isInteractivePermissionRequest(commandType)
        options.usesPerToolSnapshotInvalidation = Self.isAgentExecutionCommand(commandType) ||
            commandType == MCPCommand.Serve.self ||
            commandType == VerifyCommand.self
        if commandType == MCPCommand.Serve.self,
           MCPToolCatalog.explicitEnvironmentAllowListProvesNoScreenCaptureKitUse(environment: environment) {
            options.dynamicToolScreenCaptureReachable = false
            options.requiresSilentCapture = false
        }
        options.requiresProducerBoundSnapshotReferences = commandType == SeeCommand.self ||
            options.requiresSilentCapture ||
            options.usesPerToolSnapshotInvalidation
        options.verbose = parsedValues.flags.contains("verbose")
        options.jsonOutput = parsedValues.flags.contains("jsonOutput")
        let values = CommanderBindableValues(parsedValues: parsedValues)
        if let level: LogLevel = try values.decodeOption("logLevel", as: LogLevel.self) {
            options.logLevel = level
        }
        try Self.applyCaptureEnginePreference(to: &options, values: values, seeSkipsPixels: seeSkipsPixels)
        try Self.applyRuntimeTransportOptions(
            &options,
            commandType: commandType,
            parsedValues: parsedValues,
            environment: environment
        )
        if commandType == SetValueCommand.self {
            options.requiredElementActionOperations.insert(.setValue)
        } else if commandType == ActionCommand.self {
            options.requiredElementActionOperations.insert(.performAction)
        }
        if commandType == SeeCommand.self, values.flag("noScreenshot") {
            options.requiresInspectAccessibilityTree = true
        }
        if commandType == BrowserCommand.self {
            options.requiresBrowserMCP = true
            options.requiresBrowserHandoffBridge = !commandValues.optionValues("handoffFile").isEmpty
        }
        try BrowserHandoffCLIInput.configureRuntimeOptions(
            &options,
            commandType: commandType,
            values: commandValues,
            environment: environment
        )
        return options
    }

    private static func applyRuntimeTransportOptions(
        _ options: inout CommandRuntimeOptions,
        commandType: (any ParsableCommand.Type)?,
        parsedValues: ParsedValues,
        environment: [String: String]
    ) throws {
        let values = CommanderBindableValues(parsedValues: parsedValues)
        if let rawInputStrategy = values.singleOption("inputStrategy")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawInputStrategy.isEmpty {
            guard let strategy = UIInputStrategy(rawValue: rawInputStrategy) else {
                throw CommanderBindingError.invalidArgument(
                    label: "input-strategy",
                    value: rawInputStrategy,
                    reason: "expected one of \(UIInputStrategy.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            options.inputStrategy = strategy
        }
        if values.flag("no-remote") {
            options.preferRemote = false
            options.remoteIsolationRequested = true
        }
        let explicitBridgeSocket = values.singleOption("bridge-socket")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentBridgeSocket = environment["PEEKABOO_BRIDGE_SOCKET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExplicitBridgeSocket = explicitBridgeSocket?.isEmpty == false ||
            environmentBridgeSocket?.isEmpty == false
        if commandType == AppCommand.QuitSubcommand.self, hasExplicitBridgeSocket {
            // Implicit quit routing needs a reusable daemon so the selected host cannot be one
            // of the applications being quit. An explicit socket is the caller's selected host;
            // the Bridge server rejects self-quit requests before service dispatch.
            options.requiresSurvivingApplicationHost = false
        }
        if Self.isAgentExecutionCommand(commandType),
           !values.flag("no-remote"),
           !hasExplicitBridgeSocket {
            // Agent execution should stay local by default unless explicitly overridden.
            options.preferRemote = false
        }
        if Self.isDaemonCommand(commandType) {
            options.preferRemote = false
            options.autoStartDaemon = false
        }
        if commandType == BridgeCommand.StatusSubcommand.self {
            options.autoStartDaemon = false
            options.permitsExplicitSocketDiagnosticFallback = true
        }
        if Self.requiresCallerLocalRuntime(commandType, parsedValues: parsedValues) {
            options.preferRemote = false
        } else if Self.prefersLocalRuntime(commandType), !values.flag("no-remote"),
                  explicitBridgeSocket?.isEmpty ?? true {
            options.preferRemote = false
        }
        if let socketPath = explicitBridgeSocket, !socketPath.isEmpty {
            options.bridgeSocketPath = socketPath
        }
    }

    private static func applySeeRuntimeOptions(
        _ options: inout CommandRuntimeOptions,
        _ commandType: (any ParsableCommand.Type)?,
        values: CommanderBindableValues
    ) -> Bool {
        let seeSkipsPixels = commandType == SeeCommand.self && values.flag("noScreenshot")
        options.requiresDesktopObservation = commandType == SeeCommand.self && !seeSkipsPixels
        options.requiresDesktopObservationOCR = commandType == SeeCommand.self && values.flag("ocr")
        options.requiresExplicitSnapshotPublication = commandType == SeeCommand.self &&
            values.flag("noElements") &&
            values.singleOption("windowId") != nil &&
            values.singleOption("path")?.trimmingCharacters(in: .whitespacesAndNewlines) != "-"
        return seeSkipsPixels
    }

    private static func applyCaptureEnginePreference(
        to options: inout CommandRuntimeOptions,
        values: CommanderBindableValues,
        seeSkipsPixels: Bool
    ) throws {
        guard let captureEngine = values.singleOption("captureEngine")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !captureEngine.isEmpty
        else { return }

        guard ObservationCommandSupport.isSupportedCaptureEngineValue(captureEngine) else {
            throw CommanderBindingError.invalidArgument(
                label: "capture-engine",
                value: captureEngine,
                reason: "expected auto, modern/sckit, or classic/cg"
            )
        }
        if seeSkipsPixels {
            throw CommanderBindingError.invalidArgument(
                label: "capture-engine",
                value: captureEngine,
                reason: "cannot be used with --no-screenshot because no capture backend runs"
            )
        }
        options.captureEnginePreference = captureEngine
        if options.transportsCaptureEnginePreference {
            let preference = ObservationCommandSupport.captureEnginePreference(
                cliValue: captureEngine,
                configuredValue: nil
            )
            options.requiresCaptureEnginePreferenceHost = true
            options.requiresCaptureEnginePreferenceCapability = preference != .auto
            options.requiresScreenCaptureKitOwnerCapability = true
        } else if !options.requiresApplicationLaunchOptions, !options.requiresHostApplicationInventory {
            options.preferRemote = false
        }
    }

    private static func requiresApplicationLaunchOptions(_ commandType: (any ParsableCommand.Type)?) -> Bool {
        commandType == AppCommand.LaunchSubcommand.self ||
            commandType == AppCommand.RelaunchSubcommand.self
    }

    private static func validateApplicationLifecycleBeforeRuntimeResolution(
        _ commandType: (any ParsableCommand.Type)?,
        values: CommanderBindableValues
    ) throws {
        if commandType == AppCommand.LaunchSubcommand.self, !values.flag("foreground") {
            if values.flag("newInstance") {
                throw applicationLifecyclePreDispatchError(.backgroundLaunch(
                    "Background new-instance launch is refused before dispatch because a new app process can activate."
                ))
            }
            if !values.optionValues("open").isEmpty {
                throw applicationLifecyclePreDispatchError(.backgroundLaunch(
                    "Background URL or document delivery is refused before dispatch because the target app " +
                        "can activate."
                ))
            }
        }
        if commandType == AppCommand.RelaunchSubcommand.self, !values.flag("foreground") {
            throw applicationLifecyclePreDispatchError(.backgroundLaunch(
                "Background app relaunch is refused before quit because terminating and launching an app " +
                    "can interrupt the user."
            ))
        }
        if commandType == AppCommand.UnhideSubcommand.self, !values.flag("activate") {
            throw applicationLifecyclePreDispatchError(.unhideRequiresForegroundConsent())
        }
    }

    private static func requiresPinnedWindowMutations(_ commandType: (any ParsableCommand.Type)?) -> Bool {
        commandType == WindowCommand.CloseSubcommand.self ||
            commandType == WindowCommand.MinimizeSubcommand.self ||
            commandType == WindowCommand.RestoreSubcommand.self ||
            commandType == WindowCommand.MaximizeSubcommand.self ||
            commandType == WindowCommand.MoveSubcommand.self ||
            commandType == WindowCommand.ResizeSubcommand.self ||
            commandType == WindowCommand.SetBoundsSubcommand.self
    }

    private static func requiresHostApplicationInventory(_ commandType: (any ParsableCommand.Type)?) -> Bool {
        commandType == AppCommand.ListSubcommand.self
    }

    /// Commands that unconditionally acquire screen pixels (capture, element detection, desktop
    /// observation) and therefore need a remote host that holds the Screen Recording permission.
    /// Interaction commands (`click`/`scroll`/`type`) are excluded: they target cached snapshots and
    /// their optional observation barrier degrades gracefully without Screen Recording.
    private static func requiresScreenCapturePermission(
        _ commandType: (any ParsableCommand.Type)?,
        parsedValues: ParsedValues
    ) -> Bool {
        if commandType == SeeCommand.self {
            return !CommanderBindableValues(parsedValues: parsedValues).flag("noScreenshot")
        }
        return
            commandType == CaptureLiveCommand.self ||
            commandType == CaptureActionCommand.self
    }

    private static func requiresSilentCapture(
        _ commandType: (any ParsableCommand.Type)?,
        parsedValues: ParsedValues
    ) -> Bool {
        let values = CommanderBindableValues(parsedValues: parsedValues)
        if commandType == SeeCommand.self {
            return !values.flag("noScreenshot")
        }
        if self.isAgentExecutionCommand(commandType) ||
            commandType == MCPCommand.Serve.self {
            return true
        }
        if commandType == CaptureLiveCommand.self ||
            commandType == CaptureActionCommand.self {
            let focus = values.singleOption("captureFocus")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return focus == nil || focus == "background"
        }

        let mayRefreshObservation = !InteractionSnapshotReference.isConcrete(values.singleOption("snapshot"))
        if commandType == ScrollCommand.self {
            return mayRefreshObservation && values.singleOption("on") != nil
        }
        if commandType == ClickCommand.self {
            let hasElementTarget = values.singleOption("on") != nil ||
                values.positionalValue(at: 0)?.isEmpty == false
            return mayRefreshObservation && values.flag("foreground") && hasElementTarget
        }
        if commandType == DragCommand.self {
            let endpoints = [values.singleOption("from"), values.singleOption("to")]
            return mayRefreshObservation && endpoints.contains { endpoint in
                endpoint != nil && !DragCommand.isCoordinateTarget(endpoint)
            }
        }
        if commandType == MoveCommand.self {
            return mayRefreshObservation && (values.singleOption("to") != nil ||
                values.singleOption("on") != nil)
        }
        if commandType == SetValueCommand.self || commandType == ActionCommand.self {
            let hasElementReference = values.singleOption("on")?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let hasExplicitTarget = ["app", "pid", "windowId", "windowTitle", "windowIndex"]
                .contains { values.singleOption($0) != nil }
            return mayRefreshObservation && hasElementReference && hasExplicitTarget
        }
        return false
    }

    private static func requiresImplicitSnapshotInvalidation(
        _ commandType: (any ParsableCommand.Type)?,
        parsedValues: ParsedValues
    ) -> Bool {
        if self.clipboardMayMutate(commandType) {
            return true
        }
        if commandType == MenuBarCommand.ClickSubcommand.self {
            return true
        }
        if commandType == SeeCommand.self {
            let values = CommanderBindableValues(parsedValues: parsedValues)
            return values.flag("webFocus")
        }
        if self.isInteractivePermissionRequest(commandType) {
            return true
        }
        if commandType == MenuCommand.ListSubcommand.self {
            return self.menuListMayFocus(parsedValues)
        }
        if commandType == CaptureLiveCommand.self {
            return self.captureCommandMayFocus(commandType, parsedValues: parsedValues)
        }
        return commandType == AppCommand.LaunchSubcommand.self ||
            commandType == AppCommand.RelaunchSubcommand.self ||
            commandType == AppCommand.QuitSubcommand.self ||
            commandType == AppCommand.HideSubcommand.self ||
            commandType == AppCommand.UnhideSubcommand.self ||
            commandType == AppCommand.SwitchSubcommand.self ||
            commandType == AppCommand.FocusSubcommand.self ||
            commandType == ClickCommand.self ||
            commandType == MoveCommand.self ||
            commandType == TypeCommand.self ||
            commandType == PressCommand.self ||
            commandType == PasteCommand.self ||
            commandType == ScrollCommand.self ||
            commandType == DragCommand.self ||
            commandType == SetValueCommand.self ||
            commandType == ActionCommand.self ||
            commandType == CaptureActionCommand.self ||
            commandType == WindowCommand.FocusSubcommand.self ||
            commandType == WindowCommand.CloseSubcommand.self ||
            commandType == WindowCommand.MinimizeSubcommand.self ||
            commandType == WindowCommand.RestoreSubcommand.self ||
            commandType == WindowCommand.MaximizeSubcommand.self ||
            commandType == WindowCommand.MoveSubcommand.self ||
            commandType == WindowCommand.ResizeSubcommand.self ||
            commandType == WindowCommand.SetBoundsSubcommand.self ||
            commandType == DialogCommand.ClickSubcommand.self ||
            commandType == DialogCommand.DismissSubcommand.self ||
            commandType == DialogCommand.InputSubcommand.self ||
            commandType == DialogCommand.FileSubcommand.self ||
            commandType == MenuCommand.ClickSubcommand.self ||
            commandType == DockCommand.LaunchSubcommand.self ||
            commandType == DockCommand.RightClickSubcommand.self ||
            commandType == DockCommand.HideSubcommand.self ||
            commandType == DockCommand.ShowSubcommand.self ||
            commandType == SwitchSubcommand.self ||
            commandType == MoveWindowSubcommand.self
    }

    private static func isInteractivePermissionRequest(
        _ commandType: (any ParsableCommand.Type)?
    ) -> Bool {
        commandType == PermissionsCommand.RequestSubcommand.self
    }

    private static func clipboardMayMutate(_ commandType: (any ParsableCommand.Type)?) -> Bool {
        commandType == ClipboardCommand.SetSubcommand.self ||
            commandType == ClipboardCommand.ClearSubcommand.self ||
            commandType == ClipboardCommand.RestoreSubcommand.self
    }

    private static func isAgentExecutionCommand(_ commandType: (any ParsableCommand.Type)?) -> Bool {
        commandType == AgentRunSubcommand.self ||
            commandType == AgentResumeSubcommand.self ||
            commandType == AgentSessionsSubcommand.self ||
            commandType == AgentChatSubcommand.self
    }

    private static func menuListMayFocus(_ parsedValues: ParsedValues) -> Bool {
        let values = CommanderBindableValues(parsedValues: parsedValues)
        return values.flag("foreground") && !values.flag("noAutoFocus")
    }

    private static func captureCommandMayFocus(
        _ commandType: (any ParsableCommand.Type)?,
        parsedValues: ParsedValues
    ) -> Bool {
        let values = CommanderBindableValues(parsedValues: parsedValues)
        let focus = values.singleOption("captureFocus")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard focus == "auto" || focus == "foreground" else { return false }

        let app = values.singleOption("app")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasApplicationTarget = app?.isEmpty == false || values.singleOption("pid") != nil

        let mode = values.singleOption("mode")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? Self.inferredLiveCaptureMode(values)
        return mode == "window" && hasApplicationTarget
    }

    private static func inferredLiveCaptureMode(_ values: CommanderBindableValues) -> String {
        if values.singleOption("region") != nil {
            return "area"
        }
        if values.singleOption("app") != nil ||
            values.singleOption("pid") != nil ||
            values.singleOption("windowTitle") != nil ||
            values.singleOption("windowIndex") != nil {
            return "window"
        }
        return "frontmost"
    }

    private static func requiresExactWindowTargetedClicks(
        _ commandType: (any ParsableCommand.Type)?,
        parsedValues: ParsedValues
    ) -> Bool {
        guard commandType == ClickCommand.self else { return false }
        let values = CommanderBindableValues(parsedValues: parsedValues)
        guard self.usesBackgroundClickDelivery(values) else { return false }

        let hasWindowSelector = values.singleOption("windowId") != nil ||
            values.singleOption("windowTitle") != nil ||
            values.singleOption("windowIndex") != nil
        if hasWindowSelector {
            return true
        }

        let hasProcessTarget = values.singleOption("app") != nil || values.singleOption("pid") != nil
        return values.singleOption("at") != nil && hasProcessTarget && !values.flag("global")
    }

    private static func requiresPostEventPermission(
        _ commandType: (any ParsableCommand.Type)?,
        parsedValues: ParsedValues
    ) -> Bool {
        let values = CommanderBindableValues(parsedValues: parsedValues)
        if commandType == MoveCommand.self || commandType == DragCommand.self {
            return true
        }
        if commandType == ScrollCommand.self {
            return values.flag("foreground")
        }
        if commandType == ClickCommand.self {
            if !self.usesBackgroundClickDelivery(values) {
                return true
            }
            let isCoordinateClick = values.singleOption("at") != nil
            return values.flag("middle") || values.flag("triple") || values.flag("double") ||
                (values.flag("right") && isCoordinateClick)
        }
        return false
    }

    private static func requiresAccessibilityPermission(
        _ commandType: (any ParsableCommand.Type)?,
        parsedValues: ParsedValues
    ) -> Bool {
        let values = CommanderBindableValues(parsedValues: parsedValues)
        if commandType == ScrollCommand.self {
            return !values.flag("foreground")
        }
        if commandType == ClickCommand.self {
            return self.usesBackgroundClickDelivery(values)
        }
        return false
    }

    private static func usesBackgroundClickDelivery(_ values: CommanderBindableValues) -> Bool {
        if values.flag("focusBackground") {
            return true
        }
        return !values.flag("foreground")
    }

    private static func prefersLocalRuntime(_ commandType: (any ParsableCommand.Type)?) -> Bool {
        commandType == MCPCommand.Serve.self ||
            commandType == ToolsCommand.self ||
            commandType == ToolsListSubcommand.self ||
            commandType == ToolsCommand.DescribeSubcommand.self ||
            commandType == VerifyCommand.self ||
            commandType == LearnCommand.self ||
            commandType == CleanCommand.self ||
            commandType == ConfigCommand.InitCommand.self ||
            commandType == ConfigCommand.ShowCommand.self ||
            commandType == ConfigCommand.EditCommand.self ||
            commandType == ConfigCommand.ValidateCommand.self ||
            commandType == ConfigCommand.CredentialSetCommand.self ||
            commandType == ConfigCommand.LoginCommand.self ||
            commandType == ConfigCommand.AddProviderCommand.self ||
            commandType == ConfigCommand.ListProvidersCommand.self ||
            commandType == ConfigCommand.TestProviderCommand.self ||
            commandType == ConfigCommand.RemoveProviderCommand.self ||
            commandType == ConfigCommand.ModelsProviderCommand.self ||
            commandType == ScreenCommand.ListSubcommand.self
    }

    private static func requiresCallerLocalRuntime(
        _ commandType: (any ParsableCommand.Type)?,
        parsedValues: ParsedValues
    ) -> Bool {
        if commandType == CaptureVideoCommand.self {
            return true
        }
        guard commandType == PermissionsCommand.RequestSubcommand.self else { return false }
        return CommanderBindableValues(parsedValues: parsedValues).positionalValue(at: 0) != "event-synthesizing"
    }

    private static func isDaemonCommand(_ commandType: (any ParsableCommand.Type)?) -> Bool {
        commandType == DaemonCommand.self ||
            commandType == DaemonCommand.Start.self ||
            commandType == DaemonCommand.Stop.self ||
            commandType == DaemonCommand.Status.self ||
            commandType == DaemonCommand.Run.self
    }
}

// MARK: - Bindable Protocol

struct CommanderBindableValues {
    let positional: [String]
    let options: [String: [String]]
    let flags: Set<String>

    init(positional: [String], options: [String: [String]], flags: Set<String>) {
        self.positional = positional
        self.options = options
        self.flags = flags
    }

    init(parsedValues: ParsedValues) {
        self.init(positional: parsedValues.positional, options: parsedValues.options, flags: parsedValues.flags)
    }

    func positionalValue(at index: Int) -> String? {
        guard index >= 0, index < self.positional.count else { return nil }
        return self.positional[index]
    }

    func requiredPositional(_ index: Int, label: String) throws -> String {
        guard let value = positionalValue(at: index) else {
            throw CommanderBindingError.missingArgument(label: label)
        }
        return value
    }

    func singleOption(_ label: String) -> String? {
        self.options[label]?.last
    }

    func optionValues(_ label: String) -> [String] {
        self.options[label] ?? []
    }

    func flag(_ label: String) -> Bool {
        self.flags.contains(label)
    }

    func decodePositional<T: ExpressibleFromArgument>(
        _ index: Int,
        label: String,
        as type: T.Type = T.self
    ) throws -> T {
        let raw = try requiredPositional(index, label: label)
        guard let value = T(argument: raw) else {
            throw CommanderBindingError.invalidArgument(label: label, value: raw, reason: "Unable to parse \(T.self)")
        }
        return value
    }

    func decodeOptionalPositional<T: ExpressibleFromArgument>(
        _ index: Int,
        label: String,
        as type: T.Type = T.self
    ) throws -> T? {
        guard let raw = positionalValue(at: index) else {
            return nil
        }
        guard let value = T(argument: raw) else {
            throw CommanderBindingError.invalidArgument(label: label, value: raw, reason: "Unable to parse \(T.self)")
        }
        return value
    }

    func decodeOption<T: ExpressibleFromArgument>(_ label: String, as type: T.Type = T.self) throws -> T? {
        guard let raw = singleOption(label) else {
            return nil
        }
        guard let value = T(argument: raw) else {
            throw CommanderBindingError.invalidArgument(label: label, value: raw, reason: "Unable to parse \(T.self)")
        }
        return value
    }

    func requireOption<T: ExpressibleFromArgument>(_ label: String, as type: T.Type = T.self) throws -> T {
        guard let value: T = try decodeOption(label, as: type) else {
            throw CommanderBindingError.missingArgument(label: label)
        }
        return value
    }

    func decodeOptionEnum<T: RawRepresentable>(
        _ label: String,
        as type: T.Type = T.self,
        caseInsensitive: Bool = true
    ) throws -> T? where T.RawValue == String {
        guard let raw = singleOption(label) else {
            return nil
        }
        let candidate = caseInsensitive ? raw.lowercased() : raw
        guard let value = T(rawValue: candidate) else {
            throw CommanderBindingError.invalidArgument(label: label, value: raw, reason: "Unknown value for \(T.self)")
        }
        return value
    }
}

extension CommanderBindableValues {
    func makeWindowOptions() throws -> WindowIdentificationOptions {
        var options = WindowIdentificationOptions()
        try fillWindowOptions(into: &options)
        return options
    }

    func fillWindowOptions(into options: inout WindowIdentificationOptions) throws {
        options.app = self.singleOption("app")
        if let pid: Int32 = try decodeOption("pid", as: Int32.self) {
            options.pid = pid
        }
        if let windowId: Int = try decodeOption("windowId", as: Int.self) {
            options.windowId = windowId
        }
        options.windowTitle = self.singleOption("windowTitle")
        if let index: Int = try decodeOption("windowIndex", as: Int.self) {
            options.windowIndex = index
        }
    }

    func makeInteractionTargetOptions() throws -> InteractionTargetOptions {
        var options = InteractionTargetOptions()
        try fillInteractionTargetOptions(into: &options)
        return options
    }

    func fillInteractionTargetOptions(into options: inout InteractionTargetOptions) throws {
        options.app = self.singleOption("app")
        if let pid: Int32 = try decodeOption("pid", as: Int32.self) {
            options.pid = pid
        }
        if let windowId: Int = try decodeOption("windowId", as: Int.self) {
            options.windowId = windowId
        }
        options.windowTitle = self.singleOption("windowTitle")
        if let index: Int = try decodeOption("windowIndex", as: Int.self) {
            options.windowIndex = index
        }
        try options.validate()
    }

    func makeFocusOptions(includeBackgroundDelivery: Bool = false) throws -> FocusCommandOptions {
        var options = FocusCommandOptions()
        try fillFocusOptions(into: &options, includeBackgroundDelivery: includeBackgroundDelivery)
        return options
    }

    func fillFocusOptions(
        into options: inout FocusCommandOptions,
        includeBackgroundDelivery: Bool = false
    ) throws {
        options.noAutoFocus = self.flag("noAutoFocus")
        options.foreground = self.flag("foreground")
        options.spaceSwitch = self.flag("spaceSwitch")
        options.bringToCurrentSpace = self.flag("bringToCurrentSpace")
        if includeBackgroundDelivery, self.flag("focusBackground") {
            options.focusBackground = true
        }
        if let timeout: CLIDuration = try decodeOption("focusTimeout", as: CLIDuration.self) ??
            decodeOption("focusTimeoutDuration", as: CLIDuration.self) {
            options.focusTimeoutDuration = timeout
        }
        if let retries: Int = try decodeOption("focusRetryCount", as: Int.self) {
            options.focusRetryCount = retries
        }
    }
}

@MainActor
protocol CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws
}

enum CommanderBindingError: LocalizedError, Equatable {
    case missingArgument(label: String)
    case invalidArgument(label: String, value: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(label):
            "Missing argument: \(label)"
        case let .invalidArgument(label, value, reason):
            "Invalid value '\(value)' for \(label): \(reason)"
        }
    }
}
