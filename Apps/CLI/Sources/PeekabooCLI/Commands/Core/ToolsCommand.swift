import Commander
import Foundation
import PeekabooAutomation
import PeekabooCore
import TachikomaMCP

@MainActor
struct ToolsCommand: OutputFormattable, RuntimeBackedCommand {
    private static let abstractText = "List the MCP/agent tool catalog"
    private static let descriptionText = "Tools command for listing the MCP/agent tool catalog"

    static let commandDescription = CommandDescription(
        commandName: "tools",
        abstract: Self.abstractText,
        discussion: """
        Display the Peekaboo MCP/agent tool catalog. These tools are exposed to agents
        and `peekaboo mcp` clients (e.g. Codex, Claude Code, Cursor). Some tools also
        have dedicated CLI wrappers, such as `peekaboo browser` and `peekaboo inspect-ui`.
        Run `peekaboo --help` for the CLI command list.

        Examples:
          peekaboo tools                    # Show all tools
          peekaboo tools --verbose          # Show detailed information
          peekaboo tools --json             # Output in JSON format
        """
    )

    @Flag(name: .customLong("no-sort"), help: "Disable alphabetical sorting")
    var noSort = false

    var runtimeOptions = CommandRuntimeOptions()
    @RuntimeStorage var runtime: CommandRuntime?

    var description: String {
        Self.descriptionText
    }

    var verbose: Bool {
        self.runtime?.configuration.verbose ?? self.runtimeOptions.verbose
    }

    private var showDetailedInfo: Bool {
        self.verbose
    }

    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime

        let toolContext = MCPToolContext(services: self.services)

        let filters = ToolFiltering.currentFilters()
        let filteredTools = MCPToolCatalog.tools(
            context: toolContext,
            inputPolicy: self.inputPolicy(),
            filters: filters,
            log: { [logger] message in
                logger.debug(message)
            }
        )
        let sortedTools = self.noSort
            ? filteredTools
            : filteredTools.sorted { $0.name < $1.name }

        if self.jsonOutput {
            try self.outputJSON(tools: sortedTools)
        } else {
            self.outputFormatted(tools: sortedTools, showDescription: self.showDetailedInfo)
        }
    }

    private func inputPolicy() -> UIInputPolicy {
        self.services.configuration.getUIInputPolicy(
            cliStrategy: self.resolvedRuntime.configuration.inputStrategy
        )
    }

    // MARK: - JSON Output

    @MainActor
    private func outputJSON(tools: [any MCPTool]) throws {
        struct ToolInfo: Codable {
            let name: String
            let description: String
        }

        struct Payload: Codable {
            let tools: [ToolInfo]
            let count: Int
        }

        let payload = Payload(
            tools: tools.map { ToolInfo(name: $0.name, description: $0.description) },
            count: tools.count
        )

        outputSuccessCodable(data: payload, logger: self.outputLogger)
    }

    // MARK: - Formatted Output

    private func outputFormatted(tools: [any MCPTool], showDescription: Bool) {
        if !tools.isEmpty {
            print("Available Tools")
            print("===============")
            print()
        }

        for tool in tools {
            print("• \(tool.name)")
            if showDescription {
                print("  \(tool.description)")
            }
        }

        if !tools.isEmpty {
            print()
            print("Total tools: \(tools.count)")
        }
    }
}

@MainActor
extension ToolsCommand: ParsableCommand {}
extension ToolsCommand: AsyncRuntimeCommand {}

@MainActor
extension ToolsCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.noSort = values.flag("noSort")
    }
}
