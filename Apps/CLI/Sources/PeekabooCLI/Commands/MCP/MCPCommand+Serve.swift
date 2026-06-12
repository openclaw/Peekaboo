//
//  MCPCommand+Serve.swift
//  PeekabooCLI
//

import Commander
import Darwin
import Logging
import PeekabooCore

extension MCPCommand {
    /// Start MCP server
    @MainActor
    struct Serve {
        static let commandDescription = CommandDescription(
            commandName: "serve",
            abstract: "Start Peekaboo as an MCP server",
            discussion: """
            Starts Peekaboo as an MCP server, exposing all its tools via the
            Model Context Protocol. This allows AI clients like Claude to use
            Peekaboo's automation capabilities.

            USAGE WITH CLAUDE CODE:
              claude mcp add peekaboo -- peekaboo mcp

            USAGE WITH MCP INSPECTOR:
              npx @modelcontextprotocol/inspector peekaboo mcp serve
            """
        )

        @Option(help: "Transport type (stdio, http, sse)")
        var transport: String = "stdio"

        @Option(help: "Port for HTTP/SSE transport")
        var port: Int = 8080

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            var localDaemon: PeekabooDaemon?
            do {
                guard let transportType = Self.transportType(named: self.transport) else {
                    runtime.logger.setJsonOutputMode(runtime.configuration.jsonOutput)
                    let message = "Invalid transport '\(self.transport)'. Use stdio, http, or sse."
                    if runtime.configuration.jsonOutput {
                        outputError(message: message, code: .INVALID_ARGUMENT, logger: runtime.logger)
                    } else {
                        fputs("Error: \(message)\n", stderr)
                    }
                    throw ExitCode.failure
                }

                if runtime.services is RemotePeekabooServices {
                    runtime.logger.debug("MCP: using remote Bridge host; skipping local daemon startup")
                } else {
                    let daemon = PeekabooDaemon(configuration: .embeddedMCP())
                    localDaemon = daemon
                    try await daemon.startChecked()
                }

                let server = try await PeekabooMCPServer()
                try await server.serve(transport: transportType, port: self.port)
                await Self.stopLocalDaemon(localDaemon)
            } catch let exitCode as ExitCode {
                await Self.stopLocalDaemon(localDaemon)
                throw exitCode
            } catch {
                await Self.stopLocalDaemon(localDaemon)
                runtime.logger.error("Failed to start MCP server: \(error)")
                throw ExitCode.failure
            }
        }

        private static func stopLocalDaemon(_ daemon: PeekabooDaemon?) async {
            guard let daemon, await daemon.requestStop() else { return }
            await daemon.waitUntilStopped()
        }

        static func transportType(named name: String) -> PeekabooCore.TransportType? {
            switch name.lowercased() {
            case "stdio": .stdio
            case "http": .http
            case "sse": .sse
            default: nil
            }
        }
    }
}

@MainActor
extension MCPCommand.Serve: ParsableCommand {}
extension MCPCommand.Serve: AsyncRuntimeCommand {}

extension MCPCommand.Serve: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        if let transportOption = values.singleOption("transport") {
            self.transport = transportOption
        }
        if let portOption = try values.decodeOption("port", as: Int.self) {
            self.port = portOption
        }
    }
}
