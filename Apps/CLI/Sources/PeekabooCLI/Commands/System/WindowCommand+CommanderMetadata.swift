import Commander

private enum WindowCommandSignatures {
    static let windowOptions = WindowIdentificationOptions.commanderSignature()
    static let windowFocusOptions = FocusCommandOptions.commanderSignature(
        includeForeground: false,
        includeAutoFocusControl: false
    )
}

extension WindowCommand.CloseSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            flags: [
                .commandFlag(
                    "foreground",
                    help: "Allow focused/global fallback if AX close does not dismiss the window",
                    long: "foreground"
                ),
            ],
            optionGroups: [WindowCommandSignatures.windowOptions]
        )
    }
}

extension WindowCommand.MinimizeSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(optionGroups: [WindowCommandSignatures.windowOptions])
    }
}

extension WindowCommand.RestoreSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(optionGroups: [WindowCommandSignatures.windowOptions])
    }
}

extension WindowCommand.MaximizeSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(optionGroups: [WindowCommandSignatures.windowOptions])
    }
}

extension WindowCommand.MoveSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption("x", help: "New X coordinate", long: "x", short: "x"),
                .commandOption("y", help: "New Y coordinate", long: "y", short: "y"),
            ],
            optionGroups: [WindowCommandSignatures.windowOptions]
        )
    }
}

extension WindowCommand.ResizeSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption("width", help: "New width", long: "width", short: "w"),
                .commandOption("height", help: "New height", long: "height"),
            ],
            optionGroups: [WindowCommandSignatures.windowOptions]
        )
    }
}

extension WindowCommand.SetBoundsSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption("x", help: "New X coordinate", long: "x", short: "x"),
                .commandOption("y", help: "New Y coordinate", long: "y", short: "y"),
                .commandOption("width", help: "New width", long: "width", short: "w"),
                .commandOption("height", help: "New height", long: "height"),
            ],
            optionGroups: [WindowCommandSignatures.windowOptions]
        )
    }
}

extension WindowCommand.FocusSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption("snapshot", help: "Snapshot ID to focus the captured window context", long: "snapshot"),
            ],
            flags: [
                .commandFlag(
                    "verify",
                    help: "Verify the window is focused after the action",
                    long: "verify"
                ),
            ],
            optionGroups: [WindowCommandSignatures.windowOptions, WindowCommandSignatures.windowFocusOptions]
        )
    }
}

extension WindowCommand.WindowListSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption("app", help: "Target application", long: "app"),
                .commandOption("pid", help: "Target application by process ID", long: "pid"),
            ],
            flags: [
                .commandFlag(
                    "groupBySpace",
                    help: "Group windows by Space (virtual desktop)",
                    long: "group-by-space"
                ),
            ]
        )
    }
}
