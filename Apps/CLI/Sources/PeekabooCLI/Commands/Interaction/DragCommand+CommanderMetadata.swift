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
                    help: "Duration of drag in milliseconds",
                    long: "duration"
                ),
                .commandOption(
                    "steps",
                    help: "Number of intermediate steps",
                    long: "steps"
                ),
                .commandOption(
                    "modifiers",
                    help: "Modifier keys to hold during drag",
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
            flags: [
                .commandFlag(
                    "foreground",
                    help: "Confirm foreground pointer movement and focus the target when specified",
                    long: "foreground"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(includeAutoFocusControl: false),
            ]
        )
    }
}
