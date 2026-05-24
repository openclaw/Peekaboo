import Commander

extension HotkeyCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "keys",
                    help: "Keys to press (comma-, plus-, or space-separated)",
                    isOptional: true
                ),
            ],
            options: [
                .commandOption(
                    "keys",
                    help: "Keys to press (comma-separated or space-separated)",
                    long: "keys"
                ),
                .commandOption(
                    "holdDuration",
                    help: "Delay between key press and release in milliseconds",
                    long: "hold-duration"
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
