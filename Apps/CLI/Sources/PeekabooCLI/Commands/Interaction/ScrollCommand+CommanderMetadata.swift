import Commander

extension ScrollCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "direction",
                    help: "Scroll direction: up, down, left, or right",
                    long: "direction"
                ),
                .commandOption(
                    "amount",
                    help: "Number of scroll ticks",
                    long: "amount"
                ),
                .commandOption(
                    "on",
                    help: "Element ID to scroll on (from 'see' command)",
                    long: "on"
                ),
                .commandOption(
                    "snapshot",
                    help: "Snapshot ID, or 'latest' (uses latest if not specified)",
                    long: "snapshot"
                ),
                .commandOption(
                    "delay",
                    help: "Delay between scroll ticks in milliseconds",
                    long: "delay"
                ),
            ],
            flags: [
                .commandFlag(
                    "smooth",
                    help: "Use smooth scrolling with smaller increments",
                    long: "smooth"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
            ]
        )
    }
}
