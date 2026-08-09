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

extension PermissionsCommand.RequestSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(arguments: [
            .make(
                label: "kind",
                help: "Permission kind: accessibility, screen-recording, or event-synthesizing"
            ),
        ])
    }
}
