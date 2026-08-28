import Commander
import Foundation
import PeekabooCore
#if canImport(Swiftdansi)
import Swiftdansi
#endif

typealias PeekabooToolParameter = ParameterDefinition

@MainActor
struct LearnCommand {
    static let foregroundDragExample =
        "peekaboo drag --from <id|x,y> --to <id|x,y> --foreground"

    @RuntimeStorage private var runtime: CommandRuntime?

    private var resolvedRuntime: CommandRuntime {
        guard let runtime else {
            preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
        }
        return runtime
    }

    private var logger: Logger {
        self.resolvedRuntime.logger
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        let systemPrompt = AgentSystemPrompt.generate()
        let tools = Self.toolDefinitions(using: runtime.services)
        self.outputComprehensiveGuide(systemPrompt: systemPrompt, tools: tools)
    }

    static func toolDefinitions(using services: any PeekabooServiceProviding) -> [PeekabooToolDefinition] {
        ToolRegistry.allTools(using: services)
    }

    private func outputComprehensiveGuide(systemPrompt: String, tools: [PeekabooToolDefinition]) {
        var guide = ""
        self.appendGuideHeader(systemPrompt: systemPrompt, to: &guide)
        self.appendToolCatalog(tools: tools, to: &guide)
        self.appendBestPractices(to: &guide)
        self.appendQuickReference(to: &guide)
        self.appendCommanderSummary(to: &guide)
        self.renderGuide(guide)
    }

    private func appendGuideHeader(systemPrompt: String, to output: inout String) {
        print("""
        # Peekaboo Comprehensive Guide

        This guide contains everything you need to know about using Peekaboo for macOS automation.

        ## Peekaboo 4 CLI Surface

        - Observe with `see`: add `--tree` for an AX text tree, `--no-screenshot` for AX-only output,
          or `--no-elements` for a fast screenshot-only capture.
        - Send standalone keys and xdotool-style chords with `press`: use
          `peekaboo press cmd+shift+t --snapshot <fresh-exact-snapshot>` in background, or
          `peekaboo press cmd+shift+t --app Safari --foreground` with explicit foreground consent.
          Background-only Agent/MCP policy accepts only the fresh exact non-dialog snapshot form.
        - Exact targeted `dialog input` defaults to background AXValue; targetless/global input, file actions, and
          forced dismiss require explicit foreground consent.
        - Use `verify` instead of fixed sleeps to wait for stable window and element predicates.
        - Invoke accessibility actions with `action`. Drag changes the shared physical cursor and requires explicit
          foreground consent: `\(Self.foregroundDragExample)`.
        - Management commands are subcommand trees: `clipboard get|set|clear|save|restore`,
          `menubar list|click`, `agent run|resume|sessions|chat`, `config provider ...`, and
          `permissions request <kind>`.
        - Coordinates use `--at x,y`; add `--global` to force screen coordinates. Durations accept
          bare milliseconds, `ms`, or `s` (`500`, `500ms`, `2s`).
        - JSON responses use one envelope. Mutating commands add `effect` as `confirmed`, `partial`,
          `unverifiable`, `suspected_noop`, or `refused`; read-only commands omit it.

        ## System Instructions

        \(systemPrompt)

        ## Available Tools

        Peekaboo provides 30+ tools for macOS automation.
        Each tool is designed for a specific purpose and can be combined
        to create powerful workflows.
        """, to: &output)
    }

    private func appendToolCatalog(tools: [PeekabooToolDefinition], to output: inout String) {
        let groupedTools = Dictionary(grouping: tools, by: \.category)
        for category in ToolCategory.allCases {
            guard let categoryTools = groupedTools[category], !categoryTools.isEmpty else { continue }
            self.appendToolCategory(category, tools: categoryTools, to: &output)
        }
    }

    private func appendToolCategory(
        _ category: ToolCategory,
        tools: [PeekabooToolDefinition],
        to output: inout String
    ) {
        print("\n### \(category.icon) \(category.rawValue) Tools\n", to: &output)
        tools.sorted(by: { $0.name < $1.name }).forEach { self.appendToolDetails($0, to: &output) }
    }

    private func appendToolDetails(_ tool: PeekabooToolDefinition, to output: inout String) {
        print("#### `\(tool.name)`\n", to: &output)
        print("\(tool.abstract)\n", to: &output)

        if let guidance = tool.agentGuidance {
            print("**\(guidance)**\n", to: &output)
        }

        if !tool.parameters.isEmpty {
            self.appendParameters(tool.parameters, to: &output)
        }

        if !tool.examples.isEmpty {
            print("**Examples:**", to: &output)
            print("```json", to: &output)
            tool.examples.forEach { print($0, to: &output) }
            print("```", to: &output)
        }
        print("", to: &output)
    }

    private func appendParameters(_ parameters: [PeekabooToolParameter], to output: inout String) {
        print("**Parameters:**", to: &output)
        for param in parameters {
            var line = "- `\(param.name)` (\(param.type)"
            if param.required {
                line += ", **required**"
            }
            line += "): \(param.description)"
            if let defaultValue = param.defaultValue {
                line += " Default: `\(defaultValue)`"
            }
            if let options = param.options {
                line += " Options: `\(options.joined(separator: "`, `"))`"
            }
            print(line, to: &output)
        }
        print("", to: &output)
    }

    private func appendBestPractices(to output: inout String) {
        print("""
        ## Usage Best Practices

        1. Always start with `see` to understand the UI before interacting.
        2. Prefer opaque element IDs from the current snapshot over guessed coordinates.
        3. Verify each action before proceeding; use `verify` for exact predicates or `see` for fresh state.
        4. Inventory targets with `app list`, `window list`, and `screen list`;
           focus only when foreground delivery is required.
        5. Recover from errors with alternate semantic actions. Raw keyboard chords can stay background only with a
           fresh exact non-dialog snapshot receipt; otherwise use explicit foreground consent.
        6. Common workflows:
           - Screenshot: `see --no-elements` with `--app`, `--window-id`, or `--mode screen`.
           - AX tree: `see --tree --no-screenshot` with an exact app/window target.
           - Typing: background-click the field, observe again, then call `type` with that fresh exact non-dialog
             snapshot. App/PID/window-selector-only Agent typing is refused.
           - Menus: `menu click --path ...`.
           - Keyboard shortcuts: `press --snapshot <fresh-exact-snapshot> cmd+shift+t` in background, or
             `press cmd+shift+t --foreground` with explicit foreground consent.
        """, to: &output)
    }

    private func appendQuickReference(to output: inout String) {
        print("""
        ## MCP / Agent Tool Quick Reference
        - **Vision**: see, image
        - **UI Automation**: click, type, press, scroll
        - **Foreground-only CLI pointer**: move and drag require explicit `--foreground` consent
        - **Window Management**: window, space
        - **Applications**: app
        - **Elements**: inspect_ui, verify_state, set_value, action
        - **Menu/Dialog**: menu, dialog
        - **System**: permissions, sleep, clipboard, paste
        - **Completion**: done, need_info

        The MCP-only `image` and `inspect_ui` tools remain separate; their CLI equivalents are
        `see --no-elements` and `see --tree --no-screenshot`.

        Remember: You are Peekaboo, an AI-powered screen automation assistant.
        Be confident, be helpful, and get things done!
        """, to: &output)
    }

    @MainActor
    private func appendCommanderSummary(to output: inout String) {
        print("\n## Commander Command Signatures\n", to: &output)
        let summaries = CommanderRegistryBuilder.buildCommandSummaries()
            .sorted { $0.name < $1.name }

        for summary in summaries {
            print("### `peekaboo \(summary.name)`\n", to: &output)
            if !summary.arguments.isEmpty {
                print("**Positional Arguments:**", to: &output)
                for argument in summary.arguments {
                    let optionality = argument.isOptional ? "(optional)" : "(required)"
                    let description = argument.help ?? ""
                    print("- `\(argument.label)` \(optionality) \(description)", to: &output)
                }
                print("", to: &output)
            }
            if !summary.options.isEmpty {
                print("**Options:**", to: &output)
                for option in summary.options {
                    let names = option.names.map { "`\($0)`" }.joined(separator: ", ")
                    let description = option.help ?? "No description"
                    print("- \(names) – \(description)", to: &output)
                }
                print("", to: &output)
            }
            if !summary.flags.isEmpty {
                print("**Flags:**", to: &output)
                for flag in summary.flags {
                    let names = flag.names.map { "`\($0)`" }.joined(separator: ", ")
                    let description = flag.help ?? "No description"
                    print("- \(names) – \(description)", to: &output)
                }
            }
        }
    }

    private func renderGuide(_ markdown: String) {
        let capabilities = TerminalDetector.detectCapabilities()
        let outputMode = TerminalDetector.shouldForceOutputMode() ?? capabilities.recommendedOutputMode
        let env = ProcessInfo.processInfo.environment
        let forceColor = env["FORCE_COLOR"] != nil || env["CLICOLOR_FORCE"] != nil
        let prefersRich = outputMode != .minimal && outputMode != .quiet
        let shouldRenderANSI = prefersRich && (capabilities.supportsColors || forceColor)

        guard shouldRenderANSI else {
            Swift.print(markdown, terminator: markdown.hasSuffix("\n") ? "" : "\n")
            return
        }

        let width = capabilities.width > 0 ? capabilities.width : nil
        #if canImport(Swiftdansi)
        let rendered = Swiftdansi.render(
            markdown,
            options: RenderOptions(
                wrap: true,
                width: width,
                hyperlinks: true,
                color: true,
                theme: .contrast,
                listIndent: 4,
                listMarker: "•"
            )
        )
        Swift.print(rendered, terminator: rendered.hasSuffix("\n") ? "" : "\n")
        #else
        Swift.print(markdown, terminator: markdown.hasSuffix("\n") ? "" : "\n")
        #endif
    }
}

@MainActor
extension LearnCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "learn",
                abstract: "Display comprehensive usage guide for AI agents",
                discussion: """
                Outputs a complete guide to Peekaboo's automation capabilities in one go.
                Includes system instructions, tool definitions,
                and best practices so AI agents can load everything at once.
                """
            )
        }
    }
}

extension LearnCommand: AsyncRuntimeCommand {}
