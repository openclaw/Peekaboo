import Commander

extension FocusCommandOptions {
    static func commanderSignature(
        includeAutoFocusControl: Bool = true,
        includeBackgroundDelivery: Bool = false
    ) -> CommandSignature {
        var flags: [FlagDefinition] = []
        if includeAutoFocusControl {
            flags.append(.commandFlag(
                "noAutoFocus",
                help: "Disable automatic focus before interaction",
                long: "no-auto-focus"
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
        if includeBackgroundDelivery {
            flags.append(.commandFlag(
                "focusBackground",
                help: "Send input to the target process without focusing it (default for click)",
                long: "focus-background"
            ))
        }

        return CommandSignature(
            options: [
                .commandOption(
                    "focusTimeoutSeconds",
                    help: "Timeout for focus operations in seconds",
                    long: "focus-timeout-seconds"
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
