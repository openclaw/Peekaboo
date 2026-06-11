import Commander

extension PermissionsCommand.StatusSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "bridge-socket",
                    help: "Override the Peekaboo Bridge socket path for permission checks",
                    long: "bridge-socket"
                ),
            ],
            flags: [
                .commandFlag(
                    "no-remote",
                    help: "Skip remote hosts and query permissions locally",
                    long: "no-remote"
                ),
                .commandFlag(
                    "all-sources",
                    help: "Show bridge and local permission status side by side",
                    long: "all-sources"
                ),
            ]
        )
    }
}

extension PermissionsCommand.GrantSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature()
    }
}

extension PermissionsCommand.RequestScreenRecordingSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature()
    }
}

extension PermissionsCommand.RequestEventSynthesizingSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature()
    }
}
