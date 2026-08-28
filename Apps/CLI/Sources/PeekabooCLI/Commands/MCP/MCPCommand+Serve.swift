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
            Peekaboo's automation capabilities. The server is background-only by default;
            pass --allow-foreground to authorize foreground actions and browser user activation for this server process.

            USAGE WITH CLAUDE CODE:
              claude mcp add peekaboo -- peekaboo mcp

            USAGE WITH MCP INSPECTOR:
              npx @modelcontextprotocol/inspector peekaboo mcp serve
            """
        )

        @Option(help: "Transport type (stdio; HTTP/SSE are reserved but not implemented)")
        var transport: String = "stdio"

        @Option(help: "Reserved port for future HTTP/SSE transport support")
        var port: Int = 8080

        @Flag(
            name: .customLong("allow-foreground"),
            help: "Authorize foreground/global UI and browser user activation for this MCP server"
        )
        var allowForeground = false

        var browserHandoff: String?
        var runtimeOptions = CommandRuntimeOptions()

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

                guard transportType == .stdio else {
                    runtime.logger.setJsonOutputMode(runtime.configuration.jsonOutput)
                    let message = "Transport '\(self.transport)' is not implemented. Use stdio."
                    if runtime.configuration.jsonOutput {
                        outputError(message: message, code: .VALIDATION_ERROR, logger: runtime.logger)
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

                let mutationCoordinator = runtime.toolSnapshotMutationCoordinator
                let toolContext = Self.makeToolContext(
                    services: runtime.services,
                    snapshotMutationCoordinator: mutationCoordinator,
                    executionPolicy: self.allowForeground ? .foregroundAllowed : .backgroundOnly,
                    capturePreflightRefusal: runtime.toolCapturePreflightRefusal
                )
                let browserHandoff = runtime.browserHandoffReceiptBundleData.map {
                    BrowserMCPHandoffGrant(payload: $0)
                }
                // Server initialization opens the authenticated remote scope before tools are registered or served.
                let server = try await PeekabooMCPServer(
                    toolContext: toolContext,
                    browserHandoff: browserHandoff
                )
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

        func validateBeforeRuntime() throws {
            if self.browserHandoff != nil {
                guard self.runtimeOptions.browserHandoffReceiptBundleData != nil else {
                    throw BrowserHandoffCLIInputError.invalidReceipt("receipt was not loaded before runtime creation")
                }
                guard self.runtimeOptions.preferRemote,
                      !self.runtimeOptions.remoteIsolationRequested,
                      self.runtimeOptions.bridgeSocketPath != nil
                else {
                    throw BrowserHandoffCLIInputError.localExecutionRefused
                }
            }
        }

        private static func stopLocalDaemon(_ daemon: PeekabooDaemon?) async {
            guard let daemon, await daemon.requestStop() else { return }
            await daemon.waitUntilStopped()
        }

        static func makeToolContext(
            services: any PeekabooServiceProviding,
            snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)?,
            executionPolicy: MCPToolExecutionPolicy = .backgroundOnly,
            capturePreflightRefusal: MCPToolCapturePreflightRefusal? = nil
        ) -> MCPToolContext {
            let snapshotExecutionGate: MCPToolSnapshotExecutionGate
            if let agent = services.agent as? PeekabooAgentService {
                agent.configureSnapshotMutationCoordinator(snapshotMutationCoordinator)
                agent.configureCapturePreflightRefusal(capturePreflightRefusal)
                snapshotExecutionGate = agent.snapshotExecutionGate
            } else {
                snapshotExecutionGate = MCPToolSnapshotExecutionGate()
            }

            return MCPToolContext(
                services: services,
                snapshotMutationCoordinator: snapshotMutationCoordinator,
                snapshotExecutionGate: snapshotExecutionGate,
                executionPolicy: executionPolicy,
                capturePreflightRefusal: capturePreflightRefusal
            )
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
extension MCPCommand.Serve: PreRuntimeValidatingCommand {}
extension MCPCommand.Serve: RuntimeOptionsConfigurable {}

extension MCPCommand.Serve: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        if let transportOption = values.singleOption("transport") {
            self.transport = transportOption
        }
        if let portOption = try values.decodeOption("port", as: Int.self) {
            self.port = portOption
        }
        self.allowForeground = values.flag("allowForeground")
        self.browserHandoff = values.singleOption("browserHandoff")
    }
}
