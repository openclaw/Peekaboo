import Commander

extension MCPCommand.Serve: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "transport",
                    help: "Transport type (stdio; HTTP/SSE are reserved but not implemented)",
                    long: "transport"
                ),
                .commandOption(
                    "port",
                    help: "Reserved port for future HTTP/SSE transport support",
                    long: "port"
                ),
                .commandOption(
                    "browserHandoff",
                    help: "Consume one signed browser handoff receipt into this server's scoped child",
                    long: "browser-handoff"
                ),
            ],
            flags: [
                .commandFlag(
                    "allowForeground",
                    help: "Authorize foreground/global UI and browser user activation for this MCP server",
                    long: "allow-foreground"
                ),
            ]
        )
    }
}
