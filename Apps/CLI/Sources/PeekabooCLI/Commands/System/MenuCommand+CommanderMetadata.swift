import Commander

extension MenuCommand.ClickSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "item",
                    help: "Menu item to click",
                    long: "item"
                ),
                .commandOption(
                    "path",
                    help: "Menu path for nested items",
                    long: "path"
                ),
            ],
            flags: [
                .commandFlag(
                    "foreground",
                    help: "Focus the target before using its menu",
                    long: "foreground"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
            ]
        )
    }
}

extension MenuCommand.ClickExtraSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "title",
                    help: "Title of the menu extra",
                    long: "title"
                ),
                .commandOption(
                    "item",
                    help: "Reserved for future nested menu support; currently rejected",
                    long: "item"
                ),
            ],
            flags: [
                .commandFlag(
                    "verify",
                    help: "Verify the menu extra popover opens after clicking",
                    long: "verify"
                ),
            ]
        )
    }
}

extension MenuCommand.ListSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            flags: [
                .commandFlag(
                    "includeDisabled",
                    help: "Include disabled menu items",
                    long: "include-disabled"
                ),
                .commandFlag(
                    "foreground",
                    help: "Focus the target before listing its menu",
                    long: "foreground"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
            ]
        )
    }
}

extension MenuCommand.ListAllSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            flags: [
                .commandFlag(
                    "includeDisabled",
                    help: "Include disabled menu items",
                    long: "include-disabled"
                ),
                .commandFlag(
                    "includeFrames",
                    help: "Include frame data for each item",
                    long: "include-frames"
                ),
            ]
        )
    }
}
