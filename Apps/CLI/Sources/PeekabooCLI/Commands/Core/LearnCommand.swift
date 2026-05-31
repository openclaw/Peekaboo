import Commander
import Foundation
import PeekabooCore
#if canImport(Swiftdansi)
import Swiftdansi
#endif

typealias PeekabooToolParameter = ParameterDefinition

@MainActor
struct LearnCommand {
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
        let tools = ToolRegistry.allTools()
        self.outputComprehensiveGuide(systemPrompt: systemPrompt, tools: tools)
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

        ## System Instructions

        \(systemPrompt)

        ## Available Tools

        Peekaboo provides 30+ tools for macOS automation.
        Each tool is designed for a specific purpose and can be combined
        to create powerful workflows.
        """, to: &output)
    }

    private func appendToolCatalog(tools: [PeekabooToolDefinition], to output: inout String) {
        let groupedTools = ToolRegistry.toolsByCategory()
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
        for param in parameters where param.cliOptions?.argumentType != .argument {
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
        2. Click in the center of elements for reliable interactions.
        3. Verify each action before proceeding; use `see` again if needed.
        4. Manage windows with `list_windows` and `focus_window` before automation.
        5. Recover from errors by trying alternative interactions (menus, hotkeys).
        6. Common workflows:
           - Screenshot: `image` with `--app` or `--mode screen`.
           - Typing: `click --foreground` the field, then `type` the text.
           - Menus: `menu click --path ...`.
           - Keyboard shortcuts: `hotkey`.
        """, to: &output)
    }

    private func appendQuickReference(to output: inout String) {
        print("""
        ## Quick Reference
        - **Vision**: see, screenshot, window_capture
        - **UI Automation**: click, type, scroll, hotkey, swipe, drag
        - **Window Management**: list_windows, focus_window, resize_window, list_spaces
        - **Applications**: list_apps, launch_app, quit_app
        - **Elements**: find_element, list_elements, focused
        - **Menu/Dialog**: menu_click, dialog_click, dialog_input
        - **System**: shell, done, need_info

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
