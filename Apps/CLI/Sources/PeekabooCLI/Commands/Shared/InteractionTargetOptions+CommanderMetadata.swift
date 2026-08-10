import Commander

extension InteractionTargetOptions {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "app",
                    help: "Target application name, bundle ID, or 'PID:12345' (alternative to --pid)",
                    long: "app"
                ),
                .commandOption(
                    "pid",
                    help: "Target application by process ID (alternative to --app)",
                    long: "pid"
                ),
                .commandOption(
                    "windowId",
                    help: "Target by window id; cannot be combined with another window selector",
                    long: "window-id"
                ),
                .commandOption(
                    "windowTitle",
                    help: "Target by title; requires --app/--pid and excludes other window selectors",
                    long: "window-title"
                ),
                .commandOption(
                    "windowIndex",
                    help: "Target by index; requires --app/--pid and excludes other window selectors",
                    long: "window-index"
                ),
            ]
        )
    }
}
