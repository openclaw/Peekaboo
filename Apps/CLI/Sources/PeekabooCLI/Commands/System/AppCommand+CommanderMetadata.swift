import Commander

extension AppCommand.LaunchSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "app",
                    help: "Application name or path",
                    isOptional: true
                ),
            ],
            options: [
                .commandOption(
                    "bundleId",
                    help: "Launch by bundle identifier instead of name",
                    long: "bundle-id"
                ),
                .commandOption(
                    "open",
                    help: "Document or URL to open immediately after launch",
                    long: "open",
                    parsing: .upToNextOption
                ),
            ],
            flags: [
                .commandFlag(
                    "waitUntilReady",
                    help: "Wait for the application to be ready",
                    long: "wait-ready"
                ),
                .commandFlag(
                    "newInstance",
                    help: "Launch a distinct process even if the app is already running",
                    long: "new-instance"
                ),
                .commandFlag(
                    "waitForWindow",
                    help: "Wait for the application to expose an exact WindowServer window",
                    long: "wait-for-window"
                ),
                .commandFlag(
                    "foreground",
                    help: "Required for cold launch, open targets, or a new instance",
                    long: "foreground"
                ),
                .commandFlag(
                    "noFocus",
                    help: "Deprecated compatibility flag; background launch is now the default",
                    long: "no-focus"
                ),
            ]
        )
    }
}

extension AppCommand.QuitSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(label: "app", help: "Application to quit", isOptional: true),
            ],
            options: [
                .commandOption(
                    "app",
                    help: "Application to quit",
                    long: "app"
                ),
                .commandOption(
                    "pid",
                    help: "Target application by process ID",
                    long: "pid"
                ),
                .commandOption(
                    "expectedProcessStartIdentity",
                    help: "Require this process-start identity (cleanup safety; requires --pid)",
                    long: "expected-process-start-identity"
                ),
                .commandOption(
                    "except",
                    help: "Comma-separated list of apps to exclude when using --all",
                    long: "except"
                ),
            ],
            flags: [
                .commandFlag(
                    "all",
                    help: "Quit all applications",
                    long: "all"
                ),
                .commandFlag(
                    "force",
                    help: "Force quit (doesn't save changes)",
                    long: "force"
                ),
            ]
        )
    }
}

extension AppCommand.HideSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "app",
                    help: "Application to hide",
                    isOptional: true
                ),
            ],
            options: [
                .commandOption(
                    "app",
                    help: "Application to hide",
                    long: "app"
                ),
                .commandOption(
                    "pid",
                    help: "Target application by process ID",
                    long: "pid"
                ),
            ]
        )
    }
}

extension AppCommand.UnhideSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "app",
                    help: "Application to unhide",
                    isOptional: true
                ),
            ],
            options: [
                .commandOption(
                    "app",
                    help: "Application to unhide",
                    long: "app"
                ),
                .commandOption(
                    "pid",
                    help: "Target application by process ID",
                    long: "pid"
                ),
            ],
            flags: [
                .commandFlag(
                    "activate",
                    help: "Required explicit foreground consent for unhide",
                    long: "activate"
                ),
            ]
        )
    }
}

extension AppCommand.SwitchSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(label: "app", help: "Application to switch to", isOptional: true),
            ],
            options: [
                .commandOption(
                    "to",
                    help: "Switch to this application",
                    long: "to"
                ),
            ],
            flags: [
                .commandFlag(
                    "cycle",
                    help: "Cycle to next app (Cmd+Tab)",
                    long: "cycle"
                ),
                .commandFlag(
                    "verify",
                    help: "Verify the target app becomes frontmost",
                    long: "verify"
                ),
                .commandFlag(
                    "foreground",
                    help: "Required explicit foreground consent for switching applications",
                    long: "foreground"
                ),
            ]
        )
    }
}

extension AppCommand.ListSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            flags: [
                .commandFlag(
                    "includeHidden",
                    help: "Include hidden apps",
                    long: "include-hidden"
                ),
                .commandFlag(
                    "includeBackground",
                    help: "Include background apps",
                    long: "include-background"
                ),
            ]
        )
    }
}

extension AppCommand.RelaunchSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "app",
                    help: "Application name, bundle ID, or 'PID:12345'",
                    isOptional: true
                ),
            ],
            options: [
                .commandOption(
                    "app",
                    help: "Application name, bundle ID, or 'PID:12345'",
                    long: "app"
                ),
                .commandOption(
                    "pid",
                    help: "Target application by process ID",
                    long: "pid"
                ),
                .commandOption(
                    "wait",
                    help: "Wait between quit and launch (default 2s; bare values are milliseconds)",
                    long: "wait"
                ),
            ],
            flags: [
                .commandFlag(
                    "force",
                    help: "Force quit (doesn't save changes)",
                    long: "force"
                ),
                .commandFlag(
                    "waitUntilReady",
                    help: "Wait until the app is ready after launch",
                    long: "wait-until-ready"
                ),
                .commandFlag(
                    "foreground",
                    help: "Required explicit foreground consent for relaunch",
                    long: "foreground"
                ),
            ]
        )
    }
}

extension AppCommand.FocusSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(label: "app", help: "Application to focus", isOptional: true),
            ],
            options: [
                .commandOption("app", help: "Application to focus", long: "app"),
                .commandOption("pid", help: "Target application by process ID", long: "pid"),
            ],
            flags: [
                .commandFlag(
                    "foreground",
                    help: "Required explicit foreground consent for focusing an application",
                    long: "foreground"
                ),
            ]
        )
    }
}
