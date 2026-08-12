import Commander

extension PressCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "chord...",
                    help: "One or more chords. Chord syntax matches xdotool key (cmd+shift+t).",
                    isOptional: true,
                    parsing: .remaining
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
                    help: "Snapshot ID (or explicit 'latest'); no snapshot is inferred when omitted",
                    long: "snapshot"
                ),
            ],
            flags: [
                .commandFlag(
                    "focusBackground",
                    help: "Deprecated compatibility flag; raw press still requires --foreground",
                    long: "focus-background"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
            ]
        )
    }
}
