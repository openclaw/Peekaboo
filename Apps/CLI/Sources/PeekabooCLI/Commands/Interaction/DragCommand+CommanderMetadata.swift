import Commander

extension DragCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "from",
                    help: "Starting element ID from snapshot",
                    long: "from"
                ),
                .commandOption(
                    "fromCoords",
                    help: "Starting coordinates as 'x,y'",
                    long: "from-coords"
                ),
                .commandOption(
                    "to",
                    help: "Target element ID from snapshot",
                    long: "to"
                ),
                .commandOption(
                    "toCoords",
                    help: "Target coordinates as 'x,y'",
                    long: "to-coords"
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
