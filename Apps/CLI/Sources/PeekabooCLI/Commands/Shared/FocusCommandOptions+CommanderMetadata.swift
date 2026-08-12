import Commander

extension FocusCommandOptions {
    static func commanderSignature(
        includeForeground: Bool = true,
        includeAutoFocusControl: Bool = true,
        includeBackgroundDelivery: Bool = false
    ) -> CommandSignature {
        var flags: [FlagDefinition] = []
        if includeForeground {
            flags.append(.commandFlag(
                "foreground",
                help: "Focus the target and use foreground delivery where supported",
                long: "foreground"
            ))
        }
        flags.append(contentsOf: [
            .commandFlag(
                "spaceSwitch",
                help: "Switch to the window's Space if on a different Space",
                long: "space-switch"
            ),
            .commandFlag(
                "bringToCurrentSpace",
                help: "Bring window to current Space instead of switching",
                long: "bring-to-current-space"
            ),
        ])
        if includeAutoFocusControl {
            flags.append(.commandFlag(
                "noAutoFocus",
                help: "Disable automatic focus before interaction",
                long: "no-auto-focus"
            ))
        }
        if includeBackgroundDelivery {
            flags.append(.commandFlag(
                "focusBackground",
                help: "Deprecated compatibility alias; targeted background delivery is already the default",
                long: "focus-background"
            ))
        }

        return CommandSignature(
            options: [
                .commandOption(
                    "focusTimeout",
                    help: "Focus timeout; bare values are milliseconds, or use ms/s suffixes",
                    long: "focus-timeout"
                ),
                .commandOption(
                    "focusRetryCount",
                    help: "Number of retries for focus operations",
                    long: "focus-retry-count"
                ),
            ],
            flags: flags
        )
    }
}
