import Commander

extension ListSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            flags: [
                .commandFlag(
                    "detailed",
                    help: "Include detailed window information",
                    long: "detailed"
                ),
            ]
        )
    }
}

extension SwitchSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "to",
                    help: "Space number to switch to (1-based)",
                    long: "to"
                ),
            ],
            flags: [
                .commandFlag(
                    "foreground",
                    help: "Required explicit consent to switch the visible Space",
                    long: "foreground"
                ),
            ]
        )
    }
}

extension MoveWindowSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "app",
                    help: "Target application name, bundle ID, or 'PID:12345'",
                    long: "app"
                ),
                .commandOption(
                    "pid",
                    help: "Target application by process ID",
                    long: "pid"
                ),
                .commandOption(
                    "windowId",
                    help: "Target window by CoreGraphics window ID",
                    long: "window-id"
                ),
                .commandOption(
                    "windowTitle",
                    help: "Target window by title",
                    long: "window-title"
                ),
                .commandOption(
                    "windowIndex",
                    help: "Target window by index",
                    long: "window-index"
                ),
                .commandOption(
                    "to",
                    help: "Space number to move window to (1-based)",
                    long: "to"
                ),
            ],
            flags: [
                .commandFlag(
                    "toCurrent",
                    help: "Move window to current Space",
                    long: "to-current"
                ),
                .commandFlag(
                    "follow",
                    help: "Switch to the target Space after moving",
                    long: "follow"
                ),
                .commandFlag(
                    "foreground",
                    help: "Required explicit consent when --follow switches the visible Space",
                    long: "foreground"
                ),
            ]
        )
    }
}
