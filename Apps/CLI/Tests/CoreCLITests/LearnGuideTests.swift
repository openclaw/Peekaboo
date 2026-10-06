import Foundation
import PeekabooAgentRuntime
import Testing
@testable import PeekabooCLI

@MainActor
struct LearnGuideTests {
    @Test(arguments: [0, 1, 3])
    func `learn count and quick reference match the provided catalog`(count: Int) throws {
        let tools = Array(Self.tools.prefix(count))
        let guide = LearnCommand.guide(tools: tools, commandSummaries: [])
        let quickReference = try Self.section(
            in: guide,
            after: "## MCP / Agent Tool Quick Reference\n",
            before: "## CLI Command Reference\n"
        )
        let noun = count == 1 ? "tool" : "tools"
        #expect(guide.contains("This Agent catalog exposes \(count) \(noun) for this configuration."))
        #expect(!guide.contains("30+ tools"))
        #expect(quickReference.contains("No MCP/Agent tools are available") == tools.isEmpty)
        let lines = quickReference.split(separator: "\n").filter { $0.hasPrefix("- **") }.map(String.init)
        let expected = ToolCategory.allCases.compactMap { category -> String? in
            let names = tools.filter { $0.category == category }.map(\.name).sorted()
            guard !names.isEmpty else { return nil }
            return "- **\(category.rawValue)**: " + names.map { "`\($0)`" }.joined(separator: ", ")
        }
        #expect(lines == expected)
        for tool in tools {
            #expect(guide.contains("#### `\(tool.name)`"))
        }
        for unavailable in ["done", "need_info", "see", "image", "inspect_ui", "click", "drag", "move", "browser"] {
            #expect(!quickReference.contains("`\(unavailable)`"))
        }
    }

    @Test(arguments: [false, true])
    func `learn system instructions contain only recipes from the same sparse catalog`(empty: Bool) throws {
        let tools = empty ? [] : [Self.tools[0]]
        let guide = LearnCommand.guide(tools: tools, commandSummaries: [])
        let instructions = try Self.section(
            in: guide,
            after: "## System Instructions\n",
            before: "## Available Tools\n"
        )
        #expect(instructions == AgentSystemPrompt.generate(availableToolNames: Set(tools.map(\.name))))
        #expect(instructions.contains("immutable background-only authority"))
        #expect(instructions.contains("No tools are available in this invocation") == empty)
        for unavailableRecipe in [
            "**Calculations**", "**Browser Automation**", "**Window Management Strategy**", "**Dialog Interaction**",
            "Use `see`", "Use `inspect_ui`", "Use `browser`", "Use `click`", "Background `drag`",
        ] {
            #expect(!instructions.contains(unavailableRecipe))
        }
    }

    @Test
    func `learn CLI reference stays complete and identical when Agent tools are filtered`() throws {
        let summaries = CommanderRegistryBuilder.buildCommandSummaries()
        #expect(!summaries.isEmpty)
        let empty = LearnCommand.guide(tools: [], commandSummaries: summaries)
        let sparse = LearnCommand.guide(tools: [Self.tools[0]], commandSummaries: summaries)
        let emptyCLI = try Self.section(in: empty, after: "## CLI Command Reference\n")
        let sparseCLI = try Self.section(in: sparse, after: "## CLI Command Reference\n")
        #expect(emptyCLI == sparseCLI)
        #expect(emptyCLI.contains("Agent tool filters do not hide CLI commands"))
        #expect(emptyCLI.contains("## Commander Command Signatures"))
        let actualHeadings = emptyCLI.split(separator: "\n")
            .filter { $0.hasPrefix("### `peekaboo ") }
            .map(String.init)
        #expect(actualHeadings == summaries.map(\.name).sorted().map { "### `peekaboo \($0)`" })
        for name in ["agent", "config", "drag", "move", "see"] {
            #expect(actualHeadings.contains("### `peekaboo \(name)`"))
        }
        for summary in summaries {
            for option in summary.options {
                for name in option.names {
                    #expect(emptyCLI.contains("`\(name)`"))
                }
            }
            for flag in summary.flags {
                for name in flag.names {
                    #expect(emptyCLI.contains("`\(name)`"))
                }
            }
        }
    }

    @Test
    func `learn distinguishes same-window background drag from foreground pointer workflows`() throws {
        let guide = LearnCommand.guide(tools: [], commandSummaries: [])
        let cli = try Self.section(in: guide, after: "## CLI Command Reference\n")
        #expect(cli.contains("Background drag uses an explicit fresh `--snapshot`"))
        #expect(cli.contains("bounded linear path wholly inside that exact window"))
        #expect(cli.contains("without moving the shared physical cursor"))
        #expect(cli.contains("Cross-window/application drops, modifiers, human movement"))
        #expect(cli.contains(LearnCommand.foregroundDragExample))
        #expect(cli.contains("unverified and retry-unsafe, not proof of the drop"))
        #expect(cli.contains("never blindly replay it"))
        #expect(cli.contains("Shared-pointer `move` requires explicit `--foreground` consent"))
        #expect(!guide.contains("Drag changes the shared physical cursor and requires explicit"))
    }

    @Test
    func `learn uses tool names rather than CLI aliases and sorts the catalog deterministically`() {
        let first = LearnCommand.guide(tools: Self.tools, commandSummaries: [])
        let second = LearnCommand.guide(tools: Array(Self.tools.reversed()), commandSummaries: [])
        #expect(first == second)
        #expect(first.contains("- **Completion**: `ask_fixture`, `finish_fixture`"))
        #expect(!first.contains("- **Completion**: done, need_info"))
    }

    private static let tools: [PeekabooToolDefinition] = [
        PeekabooToolDefinition(
            name: "permissions", abstract: "Synthetic permission inventory", discussion: "", category: .system
        ),
        PeekabooToolDefinition(
            name: "finish_fixture", commandName: "done", abstract: "Synthetic completion", discussion: "",
            category: .completion
        ),
        PeekabooToolDefinition(
            name: "ask_fixture", commandName: "need_info", abstract: "Synthetic question", discussion: "",
            category: .completion
        ),
    ]

    private static func section(
        in guide: String,
        after heading: String,
        before nextHeading: String? = nil
    ) throws -> String {
        let start = try #require(guide.range(of: heading)).upperBound
        let remaining = guide[start...]
        let section: Substring
        if let nextHeading {
            let end = try #require(remaining.range(of: nextHeading)).lowerBound
            section = remaining[..<end]
        } else {
            section = remaining
        }
        return section.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
