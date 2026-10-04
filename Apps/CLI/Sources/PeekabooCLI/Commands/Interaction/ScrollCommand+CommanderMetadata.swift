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
                    help: "Number of native scroll units or wheel ticks",
                    long: "amount"
                ),
                .commandOption(
                    "on",
                    help: "Element ID to scroll on (from 'see' command)",
                    long: "on"
                ),
                .commandOption(
                    "snapshot",
                    help: "Explicit fresh screenshot snapshot required with --at; --on may use 'latest' or omit it",
                    long: "snapshot"
                ),
                .commandOption(
                    "at",
                    help: "Background x,y coordinates relative to the captured window; mutually exclusive with --on",
                    long: "at"
                ),
                .commandOption(
                    "delay",
                    help: "Scroll delay; bare values are milliseconds, or use ms/s suffixes",
                    long: "delay"
                ),
            ],
            flags: [
                .commandFlag(
                    "global",
                    help: "Interpret --at as global display points (still exact-window background delivery)",
                    long: "global"
                ),
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
