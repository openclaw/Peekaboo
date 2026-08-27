//
//  MCPCommand.swift
//  PeekabooCLI
//

import Commander
import Foundation
import PeekabooCore

/// Entry point for Model Context Protocol related subcommands.
@MainActor
struct MCPCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "mcp",
        abstract: "Model Context Protocol server operations",
        discussion: """
        The MCP command runs Peekaboo as an MCP server, exposing its tools to AI clients
        like Codex, Claude Code, and Cursor.

        EXAMPLES:
          peekaboo mcp                          # Start MCP server on stdio
          peekaboo mcp serve                     # Explicitly start MCP server
          peekaboo mcp serve --transport stdio   # Explicitly select stdio transport
        """,
        subcommands: [
            Serve.self,
        ],
        defaultSubcommand: Serve.self,
        showHelpOnEmptyInvocation: false
    )
}
