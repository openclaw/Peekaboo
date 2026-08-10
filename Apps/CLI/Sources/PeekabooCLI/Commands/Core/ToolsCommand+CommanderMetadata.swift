import Commander

extension ToolsListSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            flags: [
                .commandFlag(
                    "noSort",
                    help: "Disable alphabetical sorting",
                    long: "no-sort"
                ),
            ]
        )
    }
}

extension ToolsCommand.DescribeSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(arguments: [
            .make(label: "tool-name", help: "MCP tool name"),
        ])
    }
}
