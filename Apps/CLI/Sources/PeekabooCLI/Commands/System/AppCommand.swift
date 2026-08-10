import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Control macOS applications
@MainActor
struct AppCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "app",
        abstract: "Control applications - launch, quit, relaunch, hide/unhide, switch, focus, and list apps",
        discussion: """
        EXAMPLES:
          # Launch an application
          peekaboo app launch "Visual Studio Code"
          peekaboo app launch --bundle-id com.microsoft.VSCode --wait-ready
          peekaboo app launch "Safari" --open https://example.com --open ~/Desktop/notes.txt
          peekaboo app launch "Safari" --foreground

          # Quit applications
          peekaboo app quit --app Safari
          peekaboo app quit --all --except "Finder,Terminal"

          # Hide/show applications
          peekaboo app hide --app Slack
          peekaboo app unhide --app Slack

          # Switch between applications
          peekaboo app switch --to Terminal
          peekaboo app switch --cycle  # Cmd+Tab equivalent

          # Relaunch applications
          peekaboo app relaunch Safari --foreground
          peekaboo app relaunch "Visual Studio Code" --wait 3s --wait-until-ready
        """,
        subcommands: [
            LaunchSubcommand.self,
            QuitSubcommand.self,
            RelaunchSubcommand.self,
            HideSubcommand.self,
            UnhideSubcommand.self,
            SwitchSubcommand.self,
            FocusSubcommand.self,
            ListSubcommand.self,
        ],
        showHelpOnEmptyInvocation: true
    )

    // MARK: - Hide Application

    @MainActor

    struct HideSubcommand: InjectedRuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "hide",
            abstract: "Hide an application"
        )

        @Option(help: "Application to hide")
        var app: String?

        @Option(name: .long, help: "Target application by process ID")
        var pid: Int32?
        @RuntimeStorage var runtime: CommandRuntime?

        /// Hide the specified application and emit confirmation in either text or JSON form.
        @MainActor

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime

            do {
                let appIdentifier = try self.resolveApplicationIdentifier()
                let appInfo = try await resolveApplication(appIdentifier, services: self.services)

                self.resolvedRuntime.beginInteractionMutation()
                try await self.services.applications.hideApplication(identifier: appIdentifier)

                let data = [
                    "action": "hide",
                    "app_name": appInfo.name,
                    "bundle_id": appInfo.bundleIdentifier ?? "unknown"
                ]

                output(data) {
                    print("✓ Hidden \(appInfo.name)")
                }
                AutomationEventLogger.log(
                    .app,
                    "hide app=\(appInfo.name) bundle=\(appInfo.bundleIdentifier ?? "unknown")"
                )

            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }

    // MARK: - Unhide Application

    @MainActor

    struct UnhideSubcommand: InjectedRuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "unhide",
            abstract: "Show a hidden application"
        )

        @Option(help: "Application to unhide")
        var app: String?

        @Option(name: .long, help: "Target application by process ID")
        var pid: Int32?

        @Flag(help: "Bring to front after unhiding")
        var activate = false
        @RuntimeStorage var runtime: CommandRuntime?

        /// Unhide the target application and optionally re-activate its main window.
        @MainActor

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime

            do {
                let appIdentifier = try self.resolveApplicationIdentifier()
                let appInfo = try await resolveApplication(appIdentifier, services: self.services)

                self.resolvedRuntime.beginInteractionMutation()
                try await self.services.applications.unhideApplication(identifier: appIdentifier)

                // Activate if requested
                if self.activate {
                    try await self.services.applications.activateApplication(
                        identifier: appInfo.bundleIdentifier ?? appInfo.name
                    )
                }

                struct UnhideResult: Codable {
                    let action: String
                    let app_name: String
                    let bundle_id: String
                    let activated: Bool
                }

                let data = UnhideResult(
                    action: "unhide",
                    app_name: appInfo.name,
                    bundle_id: appInfo.bundleIdentifier ?? "unknown",
                    activated: self.activate
                )

                output(data) {
                    print("✓ Shown \(appInfo.name)")
                }
                AutomationEventLogger.log(
                    .app,
                    "unhide app=\(appInfo.name) bundle=\(appInfo.bundleIdentifier ?? "unknown") "
                        + "activated=\(self.activate)"
                )

            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }

    // MARK: - Switch Application

    @MainActor

    struct SwitchSubcommand: InjectedRuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "switch",
            abstract: "Switch to another application"
        )

        @Option(help: "Switch to this application")
        var to: String?

        @Flag(help: "Cycle to next app (Cmd+Tab)")
        var cycle = false

        @Flag(help: "Verify the target app becomes frontmost")
        var verify = false
        @RuntimeStorage var runtime: CommandRuntime?

        /// Switch focus either by cycling (Cmd+Tab) or by activating a specific application.
        @MainActor

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime

            do {
                if self.cycle {
                    if self.verify {
                        throw ValidationError("Verify is only supported with an app target (not --cycle)")
                    }
                    self.resolvedRuntime.beginInteractionMutation()
                    try await self.services.automation.hotkey(keys: "cmd,tab", holdDuration: 0)

                    struct CycleResult: Codable {
                        let action: String
                        let success: Bool
                    }

                    let data = CycleResult(action: "cycle", success: true)

                    await InteractionObservationInvalidator.invalidateAfterMutation(
                        targets: self.resolvedRuntime.interactionMutationTargets,
                        logger: self.logger,
                        reason: "app switch cycle"
                    )
                    output(data) {
                        print("✓ Cycled to next application")
                    }
                    AutomationEventLogger.log(.app, "switch action=cycle success=true")
                } else if let targetApp = to {
                    let appInfo = try await resolveApplication(targetApp, services: self.services)
                    self.resolvedRuntime.beginInteractionMutation()
                    try await self.services.applications.activateApplication(identifier: appInfo.name)
                    await InteractionObservationInvalidator.invalidateAfterMutation(
                        targets: self.resolvedRuntime.interactionMutationTargets,
                        logger: self.logger,
                        reason: "app switch"
                    )
                    if self.verify {
                        try await self.verifyFrontmostApp(expected: appInfo)
                    }

                    struct SwitchResult: Codable {
                        let action: String
                        let app_name: String
                        let bundle_id: String
                        let success: Bool
                    }

                    let data = SwitchResult(
                        action: "switch",
                        app_name: appInfo.name,
                        bundle_id: appInfo.bundleIdentifier ?? "unknown",
                        success: true
                    )

                    output(data, effect: self.verify ? .confirmed : .unverifiable) {
                        print("✓ Switched to \(appInfo.name)")
                    }
                    AutomationEventLogger.log(
                        .app,
                        "switch app=\(appInfo.name) bundle=\(appInfo.bundleIdentifier ?? "unknown") success=true"
                    )
                } else {
                    throw ValidationError("Either --to or --cycle must be specified")
                }

            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }

        private func verifyFrontmostApp(expected: ServiceApplicationInfo) async throws {
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                let frontmost = try await self.services.applications.getFrontmostApplication()
                if self.matches(frontmost: frontmost, expected: expected) {
                    return
                }
                try await Task.sleep(nanoseconds: 120_000_000)
            }

            let frontmost = try await self.services.applications.getFrontmostApplication()
            throw PeekabooError.operationError(
                message: "App switch verification failed: frontmost is \(frontmost.name)"
            )
        }

        private func matches(frontmost: ServiceApplicationInfo, expected: ServiceApplicationInfo) -> Bool {
            if let expectedBundle = expected.bundleIdentifier,
               let frontmostBundle = frontmost.bundleIdentifier,
               expectedBundle == frontmostBundle {
                return true
            }
            return frontmost.name.compare(expected.name, options: .caseInsensitive) == .orderedSame
        }
    }

    @MainActor
    struct FocusSubcommand: InjectedRuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "focus",
            abstract: "Activate and focus an application"
        )

        @Option(help: "Application to focus")
        var app: String?

        @Option(name: .long, help: "Target application by process ID")
        var pid: Int32?

        @RuntimeStorage var runtime: CommandRuntime?

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            do {
                let appIdentifier = try self.resolveApplicationIdentifier()
                let appInfo = try await resolveApplication(appIdentifier, services: self.services)
                self.resolvedRuntime.beginInteractionMutation()
                try await self.services.applications.activateApplication(
                    identifier: "PID:\(appInfo.processIdentifier)"
                )

                let result = [
                    "action": "focus",
                    "app_name": appInfo.name,
                    "bundle_id": appInfo.bundleIdentifier ?? "unknown",
                ]
                output(result) {
                    print("✓ Focused \(appInfo.name)")
                }
                AutomationEventLogger.log(
                    .app,
                    "focus app=\(appInfo.name) bundle=\(appInfo.bundleIdentifier ?? "unknown")"
                )
            } catch {
                handleError(error)
                throw ExitCode.failure
            }
        }
    }
}

extension AppCommand.HideSubcommand: AsyncRuntimeCommand, ConfirmedActionOutputFormattable, ErrorHandlingCommand,
    OutputFormattable,
    ApplicationResolvable, ApplicationResolver {}
@MainActor
extension AppCommand.HideSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.app = try Self.resolveAppArgument(values, label: "app")
        self.pid = try values.decodeOption("pid", as: Int32.self)
        guard self.app != nil || self.pid != nil else {
            throw CommanderBindingError.missingArgument(label: "app or --pid")
        }
    }
}

extension AppCommand.UnhideSubcommand: AsyncRuntimeCommand, ConfirmedActionOutputFormattable, ErrorHandlingCommand,
    OutputFormattable,
    ApplicationResolvable, ApplicationResolver {}
@MainActor
extension AppCommand.UnhideSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.app = try AppCommand.HideSubcommand.resolveAppArgument(values, label: "app")
        self.pid = try values.decodeOption("pid", as: Int32.self)
        guard self.app != nil || self.pid != nil else {
            throw CommanderBindingError.missingArgument(label: "app or --pid")
        }
        self.activate = values.flag("activate")
    }
}

extension AppCommand.HideSubcommand {
    fileprivate static func resolveAppArgument(_ values: CommanderBindableValues, label: String) throws -> String? {
        try AppCommand.resolveAppArgument(values, optionLabel: label)
    }
}

extension AppCommand {
    static func resolveAppArgument(
        _ values: CommanderBindableValues,
        optionLabel: String
    ) throws -> String? {
        let positional = values.positionalValue(at: 0)
        let option = values.singleOption(optionLabel)

        switch (positional, option) {
        case let (positional?, option?) where positional != option:
            throw CommanderBindingError.invalidArgument(
                label: optionLabel,
                value: "\(positional), \(option)",
                reason: "Provide the app either positionally or with --\(optionLabel), not both"
            )
        case let (positional?, _):
            return positional
        case let (_, option?):
            return option
        default:
            return nil
        }
    }
}

extension AppCommand.SwitchSubcommand: ActionOutputFormattable, AsyncRuntimeCommand, ErrorHandlingCommand,
    OutputFormattable,
    ApplicationResolver {}
@MainActor
extension AppCommand.SwitchSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.to = try AppCommand.resolveAppArgument(values, optionLabel: "to")
        self.cycle = values.flag("cycle")
        self.verify = values.flag("verify")
    }
}

extension AppCommand.FocusSubcommand: ConfirmedActionOutputFormattable, AsyncRuntimeCommand, ErrorHandlingCommand,
    OutputFormattable,
    ApplicationResolvable, ApplicationResolver {}
@MainActor
extension AppCommand.FocusSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.app = try AppCommand.resolveAppArgument(values, optionLabel: "app")
        self.pid = try values.decodeOption("pid", as: Int32.self)
        guard self.app != nil || self.pid != nil else {
            throw CommanderBindingError.missingArgument(label: "app or --pid")
        }
    }
}

extension AppCommand.ListSubcommand: AsyncRuntimeCommand, ErrorHandlingCommand, OutputFormattable {}
@MainActor
extension AppCommand.ListSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.includeHidden = values.flag("includeHidden")
        self.includeBackground = values.flag("includeBackground")
    }
}
