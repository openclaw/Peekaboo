import Commander
import Foundation
import PeekabooAutomationKit

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
        commandType: (any ParsableCommand.Type)? = nil
    ) throws -> CommandRuntimeOptions {
        var options = CommandRuntimeOptions()
        options.requiresApplicationLaunchOptions = Self.requiresApplicationLaunchOptions(commandType)
        options.requiresApplicationRelaunch = commandType == AppCommand.RelaunchSubcommand.self
        options.requiresSurvivingApplicationHost = commandType == AppCommand.QuitSubcommand.self
        options.requiresHostApplicationInventory = Self.requiresHostApplicationInventory(commandType)
        options.requiresImplicitSnapshotInvalidation = Self.requiresImplicitSnapshotInvalidation(
            commandType,
            parsedValues: parsedValues
        )
        let clipboardMayMutate = commandType == ClipboardCommand.self &&
            Self.clipboardMayMutate(parsedValues)
        options.requiresCallerDesktopMutationBarrier = commandType == SwitchSubcommand.self ||
            commandType == MoveWindowSubcommand.self ||
            commandType == CaptureActionCommand.self ||
            clipboardMayMutate
        options.requiresExactWindowTargetedClicks = Self.requiresExactWindowTargetedClicks(
            commandType,
            parsedValues: parsedValues
        )
        options.requiresPostEventClickPermission = Self.requiresPostEventClickPermission(
            commandType,
            parsedValues: parsedValues
        )
        options.requiresLongPressClick = commandType == ClickCommand.self &&
            CommanderBindableValues(parsedValues: parsedValues).flag("longPress")
        options.requiresScreenCapturePermission = Self.requiresScreenCapturePermission(commandType)
        options.requestsHostPermissionGrant = Self.isInteractivePermissionRequest(commandType)
        options.usesPerToolSnapshotInvalidation = commandType == AgentCommand.self ||
            commandType == MCPCommand.Serve.self ||
            commandType == InspectUICommand.self
        options.verbose = parsedValues.flags.contains("verbose")
        options.jsonOutput = parsedValues.flags.contains("jsonOutput")
        let values = CommanderBindableValues(parsedValues: parsedValues)
        if let level: LogLevel = try values.decodeOption("logLevel", as: LogLevel.self) {
            options.logLevel = level
        }
        if let captureEngine = values.singleOption("captureEngine")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !captureEngine.isEmpty {
            options.captureEnginePreference = captureEngine
            if !options.requiresApplicationLaunchOptions && !options.requiresHostApplicationInventory {
                options.preferRemote = false
            }
        }
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
        if commandType == AgentCommand.self && !values.flag("no-remote") {
            // Agent execution should stay local by default unless explicitly overridden.
            options.preferRemote = false
        }
        if Self.isDaemonCommand(commandType) {
            options.preferRemote = false
            options.autoStartDaemon = false
        }
        if Self.requiresCallerLocalRuntime(commandType) {
            options.preferRemote = false
        } else if Self.prefersLocalRuntime(commandType), !values.flag("no-remote"),
                  explicitBridgeSocket?.isEmpty ?? true {
            options.preferRemote = false
        }
        if let socketPath = explicitBridgeSocket, !socketPath.isEmpty {
            options.bridgeSocketPath = socketPath
        }
        if commandType == SetValueCommand.self || commandType == PerformActionCommand.self {
            options.requiresElementActions = true
        }
        if commandType == InspectUICommand.self {
            options.requiresInspectAccessibilityTree = true
        }
        if commandType == BrowserCommand.self {
            options.requiresBrowserMCP = true
        }
        return options
    }

    private static func requiresApplicationLaunchOptions(_ commandType: (any ParsableCommand.Type)?) -> Bool {
        commandType == OpenCommand.self ||
            commandType == AppCommand.LaunchSubcommand.self ||
            commandType == AppCommand.RelaunchSubcommand.self
    }

    private static func requiresHostApplicationInventory(_ commandType: (any ParsableCommand.Type)?) -> Bool {
        commandType == ListCommand.AppsSubcommand.self ||
            commandType == AppCommand.ListSubcommand.self
    }

    /// Commands that unconditionally acquire screen pixels (capture, element detection, desktop
    /// observation) and therefore need a remote host that holds the Screen Recording permission.
    /// Interaction commands (`click`/`scroll`/`type`) are excluded: they target cached snapshots and
    /// their optional observation barrier degrades gracefully without Screen Recording. `run` is
    /// also excluded: whether a script captures depends on its steps, which are not known at
    /// host-resolution time, so gating every `run` would push non-capture scripts off otherwise
    /// valid hosts. Any capture step inside a script still surfaces a permission error at execution.
    private static func requiresScreenCapturePermission(_ commandType: (any ParsableCommand.Type)?) -> Bool {
        commandType == ImageCommand.self ||
            commandType == SeeCommand.self ||
            commandType == CaptureLiveCommand.self ||
            commandType == CaptureWatchAlias.self ||
            commandType == CaptureVideoCommand.self ||
            commandType == CaptureActionCommand.self
    }

    private static func requiresImplicitSnapshotInvalidation(
        _ commandType: (any ParsableCommand.Type)?,
        parsedValues: ParsedValues
    ) -> Bool {
        if commandType == ClipboardCommand.self {
            return self.clipboardMayMutate(parsedValues)
        }
        if commandType == MenuBarCommand.self {
            return parsedValues.positional.first?.lowercased() == "click"
        }
        if commandType == BrowserCommand.self {
            return BrowserCommand.actionMayMutate(parsedValues.positional.first ?? "status")
        }
        if commandType == SeeCommand.self {
            return true
        }
        if self.isInteractivePermissionRequest(commandType) {
            return true
        }
        if commandType == DialogCommand.ListSubcommand.self {
            return self.dialogListMayFocus(parsedValues)
        }
        if commandType == MenuCommand.ListSubcommand.self {
            return self.menuListMayFocus(parsedValues)
        }
        if commandType == ImageCommand.self ||
            commandType == CaptureLiveCommand.self ||
            commandType == CaptureWatchAlias.self {
            return self.captureCommandMayFocus(commandType, parsedValues: parsedValues)
        }
        return commandType == OpenCommand.self ||
            commandType == AppCommand.LaunchSubcommand.self ||
            commandType == AppCommand.RelaunchSubcommand.self ||
            commandType == AppCommand.QuitSubcommand.self ||
            commandType == AppCommand.HideSubcommand.self ||
            commandType == AppCommand.UnhideSubcommand.self ||
            commandType == AppCommand.SwitchSubcommand.self ||
            commandType == ClickCommand.self ||
            commandType == MoveCommand.self ||
            commandType == TypeCommand.self ||
            commandType == PressCommand.self ||
            commandType == HotkeyCommand.self ||
            commandType == PasteCommand.self ||
            commandType == ScrollCommand.self ||
            commandType == SwipeCommand.self ||
            commandType == DragCommand.self ||
            commandType == SetValueCommand.self ||
            commandType == PerformActionCommand.self ||
            commandType == CaptureActionCommand.self ||
            commandType == WindowCommand.FocusSubcommand.self ||
            commandType == WindowCommand.CloseSubcommand.self ||
            commandType == WindowCommand.MinimizeSubcommand.self ||
            commandType == WindowCommand.MaximizeSubcommand.self ||
            commandType == WindowCommand.MoveSubcommand.self ||
            commandType == WindowCommand.ResizeSubcommand.self ||
            commandType == WindowCommand.SetBoundsSubcommand.self ||
            commandType == DialogCommand.ClickSubcommand.self ||
            commandType == DialogCommand.DismissSubcommand.self ||
            commandType == DialogCommand.InputSubcommand.self ||
            commandType == DialogCommand.FileSubcommand.self ||
            commandType == MenuCommand.ClickSubcommand.self ||
            commandType == MenuCommand.ClickExtraSubcommand.self ||
            commandType == DockCommand.LaunchSubcommand.self ||
            commandType == DockCommand.RightClickSubcommand.self ||
            commandType == DockCommand.HideSubcommand.self ||
            commandType == DockCommand.ShowSubcommand.self ||
            commandType == SwitchSubcommand.self ||
            commandType == MoveWindowSubcommand.self ||
            commandType == RunCommand.self
    }

    private static func isInteractivePermissionRequest(
        _ commandType: (any ParsableCommand.Type)?
    ) -> Bool {
        commandType == PermissionsCommand.RequestScreenRecordingSubcommand.self ||
            commandType == PermissionsCommand.RequestEventSynthesizingSubcommand.self ||
            commandType == PermissionCommand.RequestScreenRecordingSubcommand.self ||
            commandType == PermissionCommand.RequestAccessibilitySubcommand.self ||
            commandType == PermissionCommand.RequestEventSynthesizingSubcommand.self
    }

    private static func clipboardMayMutate(_ parsedValues: ParsedValues) -> Bool {
        let values = CommanderBindableValues(parsedValues: parsedValues)
        let positionalAction = values.positionalValue(at: 0)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let action = (positionalAction?.isEmpty == false ? positionalAction : nil) ??
            values.singleOption("actionOption") ??
            values.singleOption("action")
        return ClipboardCommand.actionMayMutate(action)
    }

    private static func menuListMayFocus(_ parsedValues: ParsedValues) -> Bool {
        let values = CommanderBindableValues(parsedValues: parsedValues)
        return !values.flag("noAutoFocus")
    }

    private static func dialogListMayFocus(_ parsedValues: ParsedValues) -> Bool {
        let values = CommanderBindableValues(parsedValues: parsedValues)
        let hasWindowTarget = values.singleOption("windowId") != nil ||
            values.singleOption("windowTitle") != nil ||
            values.singleOption("windowIndex") != nil
        if hasWindowTarget {
            return true
        }
        guard !values.flag("noAutoFocus") else { return false }

        let app = values.singleOption("app")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return app?.isEmpty == false ||
            values.singleOption("pid") != nil
    }

    private static func captureCommandMayFocus(
        _ commandType: (any ParsableCommand.Type)?,
        parsedValues: ParsedValues
    ) -> Bool {
        let values = CommanderBindableValues(parsedValues: parsedValues)
        let focus = values.singleOption("captureFocus")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard focus != "background" else { return false }

        let app = values.singleOption("app")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasApplicationTarget = app?.isEmpty == false || values.singleOption("pid") != nil

        if commandType == ImageCommand.self {
            let normalizedApp = app?.lowercased()
            guard normalizedApp != "menubar", normalizedApp != "frontmost" else { return false }

            let mode = values.singleOption("mode")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? Self.inferredImageCaptureMode(values)
            switch mode {
            case "window":
                return values.singleOption("windowId") == nil && hasApplicationTarget
            case "multi":
                return hasApplicationTarget
            default:
                return false
            }
        }

        let mode = values.singleOption("mode")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? Self.inferredLiveCaptureMode(values)
        return mode == "window" && hasApplicationTarget
    }

    private static func inferredImageCaptureMode(_ values: CommanderBindableValues) -> String {
        if values.singleOption("region") != nil {
            return "area"
        }
        if values.singleOption("app") != nil ||
            values.singleOption("pid") != nil ||
            values.singleOption("windowTitle") != nil ||
            values.singleOption("windowIndex") != nil ||
            values.singleOption("windowId") != nil {
            return "window"
        }
        return "frontmost"
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
        return values.singleOption("coords") != nil && hasProcessTarget && !values.flag("globalCoords")
    }

    private static func requiresPostEventClickPermission(
        _ commandType: (any ParsableCommand.Type)?,
        parsedValues: ParsedValues
    ) -> Bool {
        guard commandType == ClickCommand.self else { return false }
        let values = CommanderBindableValues(parsedValues: parsedValues)
        if values.flag("longPress") {
            return true
        }
        guard self.usesBackgroundClickDelivery(values) else { return false }
        if values.singleOption("coords") != nil {
            return true
        }
        // ClickCommand resolves conflicting flags as right-click first, then double-click.
        return values.flag("double") && !values.flag("right")
    }

    private static func usesBackgroundClickDelivery(_ values: CommanderBindableValues) -> Bool {
        if values.flag("focusBackground") {
            return true
        }
        if values.flag("longPress") {
            return false
        }
        return !values.flag("foreground") &&
            !values.flag("noAutoFocus") &&
            !values.flag("spaceSwitch") &&
            !values.flag("bringToCurrentSpace") &&
            values.singleOption("focusTimeoutSeconds") == nil &&
            values.singleOption("focusRetryCount") == nil
    }

    private static func prefersLocalRuntime(_ commandType: (any ParsableCommand.Type)?) -> Bool {
        commandType == MCPCommand.Serve.self ||
            commandType == ToolsCommand.self ||
            commandType == SleepCommand.self ||
            commandType == LearnCommand.self ||
            commandType == CleanCommand.self ||
            commandType == ConfigCommand.InitCommand.self ||
            commandType == ConfigCommand.ShowCommand.self ||
            commandType == ConfigCommand.EditCommand.self ||
            commandType == ConfigCommand.ValidateCommand.self ||
            commandType == ConfigCommand.AddCommand.self ||
            commandType == ConfigCommand.LoginCommand.self ||
            commandType == ConfigCommand.SetCredentialCommand.self ||
            commandType == ConfigCommand.AddProviderCommand.self ||
            commandType == ConfigCommand.ListProvidersCommand.self ||
            commandType == ConfigCommand.TestProviderCommand.self ||
            commandType == ConfigCommand.RemoveProviderCommand.self ||
            commandType == ConfigCommand.ModelsProviderCommand.self ||
            commandType == ListCommand.ScreensSubcommand.self ||
            commandType == PermissionsCommand.RequestScreenRecordingSubcommand.self ||
            commandType == PermissionCommand.RequestScreenRecordingSubcommand.self ||
            commandType == PermissionCommand.RequestAccessibilitySubcommand.self
    }

    private static func requiresCallerLocalRuntime(_ commandType: (any ParsableCommand.Type)?) -> Bool {
        commandType == PermissionsCommand.RequestScreenRecordingSubcommand.self ||
            commandType == PermissionCommand.RequestScreenRecordingSubcommand.self ||
            commandType == PermissionCommand.RequestAccessibilitySubcommand.self
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
        options.spaceSwitch = self.flag("spaceSwitch")
        options.bringToCurrentSpace = self.flag("bringToCurrentSpace")
        if includeBackgroundDelivery && self.flag("focusBackground") {
            options.focusBackground = true
        }
        if let timeout: TimeInterval = try decodeOption("focusTimeoutSeconds", as: TimeInterval.self) {
            options.focusTimeoutSeconds = timeout
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
