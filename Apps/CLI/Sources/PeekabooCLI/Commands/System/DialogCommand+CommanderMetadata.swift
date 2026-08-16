import Commander

extension DialogCommand.ClickSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption("button", help: "Button text to click", long: "button"),
            ],
            flags: [
                .commandFlag(
                    "foreground",
                    help: "Focus the target before the exact AXPress action",
                    long: "foreground"
                ),
            ],

            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(includeForeground: false),
            ]
        )
    }
}

extension DialogCommand.InputSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption("text", help: "Text to enter", long: "text"),
                .commandOption("field", help: "Field label or placeholder", long: "field"),
                .commandOption("index", help: "Field index (0-based)", long: "index"),
            ],
            flags: [
                .commandFlag("clear", help: "Clear existing text first", long: "clear"),
                .commandFlag(
                    "foreground",
                    help: "Use foreground keyboard input; exact targeted input defaults to background AXValue",
                    long: "foreground"
                ),
            ],

            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(includeForeground: false),
            ]
        )
    }
}

extension DialogCommand.FileSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption("path", help: "Full file path to navigate to", long: "path"),
                .commandOption("name", help: "File name to enter", long: "name"),
                .commandOption(
                    "select",
                    help: "Button to click after entering path/name (omit or 'default' to click OKButton)",
                    long: "select"
                ),
                .commandOption(
                    "timeout",
                    help: "File-dialog timeout; bare values are milliseconds, or use ms/s suffixes",
                    long: "timeout"
                ),
            ],
            flags: [
                .commandFlag(
                    "ensureExpanded",
                    help: "Ensure file dialogs are expanded (Show Details)",
                    long: "ensure-expanded"
                ),
                .commandFlag(
                    "foreground",
                    help: "Focus the file dialog before keyboard or coordinate interaction",
                    long: "foreground"
                ),
            ],

            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(includeForeground: false),
            ]
        )
    }
}

extension DialogCommand.DismissSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            flags: [
                .commandFlag("force", help: "Force dismiss with Escape", long: "force"),
                .commandFlag(
                    "foreground",
                    help: "Focus the target before dismissal; required with --force",
                    long: "foreground"
                ),
            ],

            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(includeForeground: false),
            ]
        )
    }
}

extension DialogCommand.ListSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "timeout",
                    help: "Dialog-list timeout; bare values are milliseconds, or use ms/s suffixes",
                    long: "timeout"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
            ]
        )
    }
}
