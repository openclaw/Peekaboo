import Foundation
import PeekabooAgentRuntime
import PeekabooCore
import Testing
@testable import PeekabooCLI

/// Tests for ToolsCommand functionality
@Suite(.tags(.safe))
struct ToolsCommandTests {
    @Test
    func `ToolsCommand configuration`() {
        let config = ToolsCommand.commandDescription

        #expect(config.commandName == "tools")
        #expect(config.abstract == "List the MCP tool catalog")
        #expect(config.discussion != nil)
        let discussion = config.discussion ?? ""
        #expect(discussion.contains("built-in Peekaboo Agent adds agent-only capabilities"))
        #expect(discussion.contains("including `shell`"))
        #expect(discussion.contains("Examples:"))
        #expect(discussion.contains("peekaboo tools"))
        #expect(discussion.contains("--verbose"))
        #expect(discussion.contains("--json"))
    }

    @Test
    func `ToolsCommand default values`() throws {
        let command = try ToolsListSubcommand.parse([])

        #expect(command.verbose == false)
        #expect(command.jsonOutput == false)
        #expect(command.noSort == false)
    }

    @Test
    func `ToolsCommand argument parsing - verbose`() throws {
        let args = ["--verbose"]
        let command = try ToolsListSubcommand.parse(args)

        #expect(command.verbose == true)
    }

    @Test
    func `ToolsCommand argument parsing - json output`() throws {
        let args = ["--json"]
        let command = try ToolsListSubcommand.parse(args)

        #expect(command.jsonOutput == true)
    }

    @Test
    func `ToolsCommand argument parsing - no sort`() throws {
        let args = ["--no-sort"]
        let command = try ToolsListSubcommand.parse(args)

        #expect(command.noSort == true)
    }

    @Test
    @MainActor
    func `describe subcommand exposes a catalog schema`() throws {
        let command = try ToolsCommand.DescribeSubcommand.parse(["click"])
        #expect(command.toolName == "click")

        var foundDescribe = false
        for subcommand in ToolsCommand.commandDescription.subcommands
            where subcommand.commandDescription.commandName == "describe" {
            foundDescribe = true
        }
        #expect(foundDescribe)

        let services = PeekabooServices()
        let tools = MCPToolCatalog.unfilteredTools(context: MCPToolContext(services: services))
        let payload = try #require(ToolsCommand.DescribeSubcommand.payload(named: "click", tools: tools))
        #expect(payload.name == "click")
        #expect(!payload.description.isEmpty)
        let json = try #require(String(data: JSONEncoder().encode(payload), encoding: .utf8))
        #expect(json.contains("\"input_schema\""))
        #expect(json.contains("\"properties\""))
        #expect(ToolsCommand.DescribeSubcommand.payload(named: "nonexistent", tools: tools) == nil)
    }
}

/// Mock tests to verify command structure without execution
@Suite(.tags(.safe))
struct ToolsCommandStructureTests {
    @Test
    func `Command has required AsyncParsableCommand conformance`() throws {
        let command = try ToolsListSubcommand.parse([])

        #expect(type(of: command) == ToolsListSubcommand.self)
    }

    @Test
    func `Command configuration is properly set`() {
        let config = ToolsCommand.commandDescription

        #expect(config.commandName == "tools")
        #expect(!config.abstract.isEmpty)
        #expect(config.discussion != nil)

        let discussion = config.discussion ?? ""
        #expect(discussion.contains("peekaboo tools"))
        #expect(discussion.contains("Examples:"))
        #expect(discussion.contains("--verbose"))
        #expect(discussion.contains("--json"))
    }

    @Test
    func `Command properties have correct types and attributes`() throws {
        let command = try ToolsListSubcommand.parse([])

        #expect(type(of: command.verbose) == Bool.self)
        #expect(type(of: command.jsonOutput) == Bool.self)
        #expect(type(of: command.noSort) == Bool.self)
    }
}
