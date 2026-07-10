import Commander

extension ListCommand.WindowsSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "app",
                    help: "Target application name, bundle ID, or 'PID:12345'",
                    long: "app"
                ),
                .commandOption(
                    "pid",
                    help: "Target application by process ID",
                    long: "pid"
                ),
                .commandOption(
                    "includeDetails",
                    help: "Additional details (comma-separated: off_screen,bounds,ids)",
                    long: "include-details"
                ),
            ]
        )
    }
}

extension ListCommand.AppsSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            flags: [
                .commandFlag(
                    "includeHidden",
                    help: "Accepted for parity with app list; list apps already includes hidden apps",
                    long: "include-hidden"
                ),
                .commandFlag(
                    "includeBackground",
                    help: "Accepted for parity with app list; list apps already includes background apps",
                    long: "include-background"
                ),
            ]
        )
    }
}

extension ListCommand.MenuBarSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature()
    }
}

extension ListCommand.ScreensSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature()
    }
}

extension ListCommand.PermissionsSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature()
    }
}
