import Commander
import PeekabooFoundation

extension PressCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "chord...",
                    help: KeyboardChord.syntaxHelp,
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
                    help: "Fresh exact snapshot receipt for background press; Agent/MCP background-only policy " +
                        "requires an explicit non-dialog snapshot and never infers latest",
                    long: "snapshot"
                ),
            ],
            flags: [
                .commandFlag(
                    "focusBackground",
                    help: "Deprecated compatibility flag; use an exact receipt or explicit --foreground consent",
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
