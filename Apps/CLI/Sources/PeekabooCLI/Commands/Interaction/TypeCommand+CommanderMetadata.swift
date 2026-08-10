import Commander

extension TypeCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "text",
                    help: "Text to type",
                    isOptional: true
                ),
            ],
            options: [
                .commandOption(
                    "textOption",
                    help: "Text to type (alternative to positional argument)",
                    long: "text"
                ),
                .commandOption(
                    "snapshot",
                    help: "Snapshot ID (or explicit 'latest'); no snapshot is inferred when omitted",
                    long: "snapshot"
                ),
                .commandOption(
                    "delay",
                    help: "Keystroke delay; bare values are milliseconds, or use ms/s suffixes",
                    long: "delay"
                ),
                .commandOption(
                    "profile",
                    help: "Typing profile: linear (default) or human",
                    long: "profile"
                ),
                .commandOption(
                    "wpm",
                    help: "Approximate human typing speed (words per minute)",
                    long: "wpm"
                ),
            ],
            flags: [
                .commandFlag(
                    "clear",
                    help: "Clear the field before typing (Cmd+A, Delete)",
                    long: "clear"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(includeBackgroundDelivery: true),
            ]
        )
    }
}
