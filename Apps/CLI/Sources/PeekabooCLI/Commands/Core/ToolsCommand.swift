import Commander
import Foundation
import MCP
import PeekabooAutomation
import PeekabooCore
import TachikomaMCP

@MainActor
struct ToolsCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "tools",
        abstract: "List the MCP tool catalog",
        discussion: """
        Display the native tools exposed to `peekaboo mcp` clients (e.g. Codex,
        Claude Code, Cursor). The built-in Peekaboo Agent adds agent-only capabilities,
        including `shell`; run `peekaboo learn` for the combined guidance. Some MCP
        tools also have dedicated CLI wrappers, such as `peekaboo browser`.
        Run `peekaboo --help` for the CLI command list.

        Examples:
          peekaboo tools                    # Show all tools
          peekaboo tools --verbose          # Show detailed information
          peekaboo tools --json             # Output in JSON format
          peekaboo tools describe click     # Show one tool's full input schema
        """,
        subcommands: [ToolsListSubcommand.self, DescribeSubcommand.self],
        defaultSubcommand: ToolsListSubcommand.self
    )

    func run() async throws {}
}

@MainActor
struct ToolsListSubcommand: OutputFormattable, RuntimeBackedCommand {
    static let commandDescription = CommandDescription(
        commandName: "list",
        abstract: "List the MCP tool catalog"
    )

    @Flag(name: .customLong("no-sort"), help: "Disable alphabetical sorting")
    var noSort = false

    var runtimeOptions = CommandRuntimeOptions()
    @RuntimeStorage var runtime: CommandRuntime?

    var verbose: Bool {
        self.runtime?.configuration.verbose ?? self.runtimeOptions.verbose
    }

    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime

        let filteredTools = MCPToolCatalog.tools(
            context: MCPToolContext(services: self.services),
            inputPolicy: self.services.configuration.getUIInputPolicy(
                cliStrategy: runtime.configuration.inputStrategy
            ),
            filters: ToolFiltering.currentFilters(),
            log: { [logger] message in logger.debug(message) }
        )
        let sortedTools = self.noSort
            ? filteredTools
            : filteredTools.sorted { $0.name < $1.name }

        if self.jsonOutput {
            try self.outputJSON(tools: sortedTools)
        } else {
            self.outputFormatted(tools: sortedTools, showDescription: self.verbose)
        }
    }

    // MARK: - JSON Output

    @MainActor
    private func outputJSON(tools: [any MCPTool]) throws {
        let items = tools.map { tool in
            Value.object(["name": .string(tool.name), "description": .string(tool.description)])
        }
        outputSuccessCodable(
            data: Value.object(["tools": .array(items), "count": .int(tools.count)]),
            logger: self.outputLogger
        )
    }

    // MARK: - Formatted Output

    private func outputFormatted(tools: [any MCPTool], showDescription: Bool) {
        guard !tools.isEmpty else { return }
        print("Available Tools")
        print("===============")
        print()

        for tool in tools {
            print("• \(tool.name)")
            if showDescription {
                print("  \(tool.description)")
            }
        }

        print()
        print("Total tools: \(tools.count)")
    }
}

extension ToolsCommand {
    struct ToolDescription: Codable {
        let name: String
        let description: String
        let inputSchema: Value

        enum CodingKeys: String, CodingKey {
            case name, description
            case inputSchema = "input_schema"
        }
    }

    @MainActor
    struct DescribeSubcommand: OutputFormattable, RuntimeBackedCommand {
        @Argument(help: "MCP tool name")
        var toolName: String = ""

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            let tools = MCPToolCatalog.tools(
                context: MCPToolContext(services: self.services),
                inputPolicy: self.services.configuration.getUIInputPolicy(
                    cliStrategy: runtime.configuration.inputStrategy
                ),
                filters: ToolFiltering.currentFilters()
            )
            guard let payload = Self.payload(named: self.toolName, tools: tools) else {
                let names = tools.map(\.name).sorted().joined(separator: ", ")
                throw ValidationError("Unknown tool '\(self.toolName)'. Valid names: \(names)")
            }

            if self.jsonOutput {
                outputSuccessCodable(data: payload, logger: self.outputLogger)
                return
            }

            print("Name: \(payload.name)")
            print("Abstract: \(payload.description)")
            print("Input schema:")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload.inputSchema)
            guard let schema = String(data: data, encoding: .utf8) else {
                throw ValidationError("Could not render input schema for '\(payload.name)'")
            }
            print(schema)
        }

        static func payload(named name: String, tools: [any MCPTool]) -> ToolDescription? {
            guard let tool = tools.first(where: { $0.name == name }) else { return nil }
            return ToolDescription(name: tool.name, description: tool.description, inputSchema: tool.inputSchema)
        }
    }
}

extension ToolsListSubcommand: ParsableCommand {}
extension ToolsListSubcommand: AsyncRuntimeCommand {}

@MainActor
extension ToolsCommand.DescribeSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "describe",
                abstract: "Describe one MCP tool and print its full input schema"
            )
        }
    }
}

extension ToolsCommand.DescribeSubcommand: AsyncRuntimeCommand {}

@MainActor
extension ToolsCommand.DescribeSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.toolName = try values.requiredPositional(0, label: "tool-name")
    }
}

@MainActor
extension ToolsListSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.noSort = values.flag("noSort")
    }
}
