import Commander

extension DragCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "from",
                    help: "Starting element ID or coordinates as 'x,y'",
                    long: "from"
                ),
                .commandOption(
                    "to",
                    help: "Target element ID or coordinates as 'x,y'",
                    long: "to"
                ),
                .commandOption(
                    "toApp",
                    help: "Target application (e.g., 'Trash', 'Finder')",
                    long: "to-app"
                ),
                .commandOption(
                    "snapshot",
                    help: "Snapshot ID for element resolution, or 'latest'",
                    long: "snapshot"
                ),
                .commandOption(
                    "duration",
                    help: "Drag duration; bare values are milliseconds, or use ms/s suffixes",
                    long: "duration"
                ),
                .commandOption(
                    "steps",
                    help: "Number of intermediate steps",
                    long: "steps"
                ),
                .commandOption(
                    "modifiers",
                    help: "Comma-separated modifiers: cmd,shift,option,ctrl,fn",
                    long: "modifiers"
                ),
                .commandOption(
                    "button",
                    help: "Mouse button to hold during drag (left or right)",
                    long: "button"
                ),
                .commandOption(
                    "profile",
                    help: "Movement profile (linear or human)",
                    long: "profile"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
            ]
        )
    }
}
