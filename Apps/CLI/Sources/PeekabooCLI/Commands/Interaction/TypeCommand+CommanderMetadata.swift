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
                    help: "Snapshot ID, or 'latest' (uses latest if not specified)",
                    long: "snapshot"
                ),
                .commandOption(
                    "delay",
                    help: "Delay between keystrokes in milliseconds",
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
                .commandFlag(
                    "foreground",
                    help: "Focus target and send foreground keyboard input",
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
