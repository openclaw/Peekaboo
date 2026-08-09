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
            ]
        )
    }
}
