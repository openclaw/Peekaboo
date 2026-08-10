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
                    help: "Key delay; bare values are milliseconds, or use ms/s suffixes",
                    long: "delay"
                ),
                .commandOption(
                    "hold",
                    help: "Key hold; bare values are milliseconds, or use ms/s suffixes",
                    long: "hold"
                ),
                .commandOption(
                    "snapshot",
                    help: "Snapshot ID, or 'latest' (uses latest if not specified)",
                    long: "snapshot"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(includeBackgroundDelivery: true),
            ]
        )
    }
}
