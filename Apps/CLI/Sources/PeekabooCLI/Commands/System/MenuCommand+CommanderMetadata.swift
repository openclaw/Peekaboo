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
                    help: "Allow frontmost-menu targeting or focus a target; background clicks require --app/--pid",
                    long: "foreground"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(includeForeground: false),
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
                FocusCommandOptions.commanderSignature(includeForeground: false),
            ]
        )
    }
}
