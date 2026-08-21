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
                    "at",
                    help: "Exact-window focus point in x,y form; requires a fresh screenshot snapshot",
                    long: "at"
                ),
                .commandOption(
                    "coordinateSpaceOption",
                    help: "Coordinate basis: global_display_points, image_pixels, or normalized",
                    long: "coordinate-space"
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
