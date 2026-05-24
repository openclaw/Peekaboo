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
                    help: "Typing profile: human (default) or linear",
                    long: "profile"
                ),
                .commandOption(
                    "wpm",
                    help: "Approximate human typing speed (words per minute)",
                    long: "wpm"
                ),
                .commandOption(
                    "tab",
                    help: "Press tab N times",
                    long: "tab"
                ),
            ],
            flags: [
                .commandFlag(
                    "pressReturn",
                    help: "Press return/enter after typing",
                    long: "return"
                ),
                .commandFlag(
                    "escape",
                    help: "Press escape",
                    long: "escape"
                ),
                .commandFlag(
                    "delete",
                    help: "Press delete/backspace",
                    long: "delete"
                ),
                .commandFlag(
                    "clear",
                    help: "Clear the field before typing (Cmd+A, Delete)",
                    long: "clear"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
            ]
        )
    }
}
