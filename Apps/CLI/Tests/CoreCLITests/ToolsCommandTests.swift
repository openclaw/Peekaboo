import Foundation
import Testing
@testable import PeekabooCLI

/// Tests for ToolsCommand functionality
@Suite(.tags(.safe))
struct ToolsCommandTests {
    @Test
    func `ToolsCommand configuration`() {
        let config = ToolsCommand.commandDescription

        #expect(config.commandName == "tools")
        #expect(config.abstract == "List the MCP/agent tool catalog (not CLI commands)")
        #expect(config.discussion != nil)
        let discussion = config.discussion ?? ""
        #expect(discussion.contains("Examples:"))
        #expect(discussion.contains("peekaboo tools"))
        #expect(discussion.contains("--verbose"))
        #expect(discussion.contains("--json"))
    }

    @Test
    func `ToolsCommand default values`() throws {
        let command = try ToolsCommand.parse([])

        #expect(command.verbose == false)
        #expect(command.jsonOutput == false)
        #expect(command.noSort == false)
    }

    @Test
    func `ToolsCommand argument parsing - verbose`() throws {
        let args = ["--verbose"]
        let command = try ToolsCommand.parse(args)

        #expect(command.verbose == true)
    }

    @Test
    func `ToolsCommand argument parsing - json output`() throws {
        let args = ["--json"]
        let command = try ToolsCommand.parse(args)

        #expect(command.jsonOutput == true)
    }

    @Test
    func `ToolsCommand argument parsing - no sort`() throws {
        let args = ["--no-sort"]
        let command = try ToolsCommand.parse(args)

        #expect(command.noSort == true)
    }

    @Test
    func `ToolsCommand description property`() throws {
        let command = try ToolsCommand.parse([])
        #expect(command.description == "Tools command for listing the MCP/agent tool catalog")
    }
}

/// Mock tests to verify command structure without execution
@Suite(.tags(.safe))
struct ToolsCommandStructureTests {
    @Test
    func `Command has required AsyncParsableCommand conformance`() throws {
        let command = try ToolsCommand.parse([])

        #expect(type(of: command) == ToolsCommand.self)
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
        let command = try ToolsCommand.parse([])

        #expect(type(of: command.verbose) == Bool.self)
        #expect(type(of: command.jsonOutput) == Bool.self)
        #expect(type(of: command.noSort) == Bool.self)
    }
}
