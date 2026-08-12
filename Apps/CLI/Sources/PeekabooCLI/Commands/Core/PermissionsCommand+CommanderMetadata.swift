import Commander

extension PermissionsCommand.StatusSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            flags: [
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
