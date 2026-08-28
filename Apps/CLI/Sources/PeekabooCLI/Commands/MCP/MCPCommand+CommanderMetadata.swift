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
                    help: "Adopt one authenticated browser target from an owner-private handoff receipt",
                    long: "browser-handoff"
                ),
            ],
            flags: [
                .commandFlag(
                    "allowForeground",
                    help: "Authorize foreground/global UI for this MCP server",
                    long: "allow-foreground"
                ),
            ]
        )
    }
}
