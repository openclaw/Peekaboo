import Commander

extension SwipeCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "from",
                    help: "Source element ID",
                    long: "from"
                ),
                .commandOption(
                    "fromCoords",
                    help: "Source coordinates (x,y)",
                    long: "from-coords"
                ),
                .commandOption(
                    "to",
                    help: "Destination element ID",
                    long: "to"
                ),
                .commandOption(
                    "toCoords",
                    help: "Destination coordinates (x,y)",
                    long: "to-coords"
                ),
                .commandOption(
                    "snapshot",
                    help: "Snapshot ID, or 'latest' (uses latest if not specified)",
                    long: "snapshot"
                ),
                .commandOption(
                    "duration",
                    help: "Duration of the swipe in milliseconds",
                    long: "duration"
                ),
                .commandOption(
                    "steps",
                    help: "Number of intermediate points for smooth movement",
                    long: "steps"
                ),
                .commandOption(
                    "profile",
                    help: "Movement profile (linear or human)",
                    long: "profile"
                ),
            ],
            flags: [
                .commandFlag(
                    "rightButton",
                    help: "Use right mouse button for drag",
                    long: "right-button"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
            ]
        )
    }
}
