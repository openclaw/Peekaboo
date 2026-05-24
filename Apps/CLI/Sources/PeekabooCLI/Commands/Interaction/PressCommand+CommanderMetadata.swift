import Commander

extension PressCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "keys",
                    help: "Key(s) to press",
                    isOptional: true
                ),
            ],
            options: [
                .commandOption(
                    "key",
                    help: "Key to press (alternative to positional argument)",
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
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
            ]
        )
    }
}
