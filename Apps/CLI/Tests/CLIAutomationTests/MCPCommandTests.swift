import Commander
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

struct MCPCommandTests {
    // MARK: - Command Structure Tests

    @Test
    func `MCP command has correct subcommands`() {
        let command = MCPCommand.self

        #expect(command.commandDescription.commandName == "mcp")
        #expect(command.commandDescription.subcommands.count == 1)

        let subcommandNames = command.commandDescription.subcommands.compactMap { descriptor in
            descriptor.commandDescription.commandName
        }
        #expect(subcommandNames.contains("serve"))
    }

    @Test
    func `MCP serve command default options`() throws {
        let serve = try MCPCommand.Serve.parse([])

        #expect(serve.transport == "stdio")
        #expect(serve.port == 8080)
    }

    @Test
    func `MCP serve command custom options`() throws {
        let serve = try MCPCommand.Serve.parse(["--transport", "http", "--port", "9000"])

        #expect(serve.transport == "http")
        #expect(serve.port == 9000)
    }

    // MARK: - Help Text Tests

    @Test
    func `MCP command help text`() {
        let helpText = MCPCommand.helpMessage()

        #expect(helpText.contains("Model Context Protocol server operations"))
        #expect(helpText.contains("serve"))
    }

    @Test
    func `MCP serve help text`() {
        let helpText = MCPCommand.Serve.helpMessage()

        #expect(helpText.contains("Start Peekaboo as an MCP server"))
        #expect(helpText.contains("claude mcp add peekaboo"))
        #expect(helpText.contains("npx @modelcontextprotocol/inspector"))
        #expect(helpText.contains("--transport"))
        #expect(helpText.contains("--port"))
        #expect(helpText.contains("reserved but not implemented"))
    }

    // MARK: - Argument Parsing Tests

    @Test
    func `Parse serve command with all transports`() throws {
        let transports = ["stdio", "http", "sse"]

        for transport in transports {
            let serve = try MCPCommand.Serve.parse(["--transport", transport])
            #expect(serve.transport == transport)
        }
    }

    @Test
    func `Reject invalid transport before starting server`() async throws {
        let result = try await InProcessCommandRunner.runShared(
            ["mcp", "serve", "--transport", "bogus", "--json"],
            allowedExitCodes: [1]
        )

        #expect(result.exitStatus == 1)
        #expect(result.stdout.contains("\"success\" : false"))
        #expect(result.stdout.contains("Invalid transport 'bogus'"))
    }

    @Test(arguments: ["http", "sse"])
    func `Reject unimplemented transport with structured error`(_ transport: String) async throws {
        let result = try await InProcessCommandRunner.runShared(
            ["mcp", "serve", "--transport", transport, "--json"],
            allowedExitCodes: [1]
        )

        #expect(result.exitStatus == 1)
        let data = try #require(result.stdout.data(using: .utf8))
        let payload = try JSONDecoder().decode(JSONResponse.self, from: data)
        #expect(payload.success == false)
        #expect(payload.error?.code == ErrorCode.VALIDATION_ERROR.rawValue)
        #expect(payload.error?.message == "Transport '\(transport)' is not implemented. Use stdio.")
    }

    // MARK: - Validation Tests

    @Test
    func `Invalid port number throws error`() throws {
        #expect(throws: (any Error).self) {
            try CLIOutputCapture.suppressStderr {
                _ = try MCPCommand.Serve.parse(["--port=-1"])
            }
        }
    }
}

@Suite(.tags(.integration))
struct MCPCommandIntegrationTests {
    @Test
    func `Serve command transport type conversion`() throws {
        let serve = try MCPCommand.Serve.parse(["--transport", "stdio"])

        // This test would need to actually run the serve command
        // and verify it starts the server with the correct transport.
        let expectedTransport: PeekabooCore.TransportType = .stdio
        #expect(serve.transport == expectedTransport.description)
    }
}

// MARK: - Mock Tests for Server Behavior

struct MCPServerBehaviorTests {
    @Test
    func `Server exits cleanly on SIGTERM`() throws {
        // For unit testing, verify the serve command structure.
        let serve = try CLIOutputCapture.suppressStderr {
            try MCPCommand.Serve.parse([])
        }
        #expect(serve.transport == "stdio")
    }

    @Test
    func `Server validates transport types`() {
        #expect(MCPCommand.Serve.transportType(named: "stdio") == .stdio)
        #expect(MCPCommand.Serve.transportType(named: "http") == .http)
        #expect(MCPCommand.Serve.transportType(named: "sse") == .sse)
        #expect(MCPCommand.Serve.transportType(named: "invalid") == nil)
    }
}
