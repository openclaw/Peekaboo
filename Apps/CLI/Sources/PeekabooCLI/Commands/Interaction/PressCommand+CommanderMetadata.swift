import Commander

extension PressCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "chords",
                    help: "Chord(s) to press. Chord syntax matches xdotool key (cmd+shift+t).",
                    isOptional: true
                ),
            ],
            options: [
                .commandOption(
                    "key",
                    help: "Chord to press (alternative to positional argument)",
                    long: "key"
                ),
                .commandOption(
                    "count",
                    help: "Repeat count for all keys",
                    long: "count"
                ),
                .commandOption(
                    "delay",
                    help: "Delay between key presses in milliseconds",
                    long: "delay"
                ),
                .commandOption(
                    "hold",
                    help: "Hold duration for each key in milliseconds",
                    long: "hold"
                ),
                .commandOption(
                    "snapshot",
                    help: "Snapshot ID, or 'latest' (uses latest if not specified)",
                    long: "snapshot"
                ),
            ],
            flags: [
                .commandFlag(
                    "foreground",
                    help: "Focus target and send foreground/global key presses",
                    long: "foreground"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
            ]
        )
    }
}
