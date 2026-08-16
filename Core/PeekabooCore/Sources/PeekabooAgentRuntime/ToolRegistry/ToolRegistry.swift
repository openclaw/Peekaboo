import Foundation
import os.log
import PeekabooAutomation
import Tachikoma

/// Central registry for all Peekaboo tools
/// This registry collects tool definitions from various tool implementation files
@available(macOS 14.0, *)
public enum ToolRegistry {
    @MainActor
    private static var defaultServicesFactory: (() -> any PeekabooServiceProviding)?

    private struct ToolOverride {
        let category: ToolCategory?
        let abstract: String?
        let discussion: String?
        let examples: [String]?
        let agentGuidance: String?
    }

    /// Runtime tool names carrying curated copy. Exposed so a contract test can
    /// keep this table synchronized with the agent/MCP tool surface.
    static var overriddenToolNames: Set<String> {
        Set(self.toolOverrides.keys)
    }

    private static let toolOverrides: [String: ToolOverride] = [
        "see": ToolOverride(
            category: .vision,
            abstract: "Capture and analyze UI contexts, returning snapshot-aware element maps.",
            discussion: """
            Capture a screenshot, analyze every visible UI element, and write the results to the snapshot cache
            so later tools can reference the same IDs. The command automatically handles full screen,
            frontmost window, or app-specific captures.

            EXAMPLE
            peekaboo see --app Safari --path ~/Desktop/safari.png --annotate

            SNAPSHOT MANAGEMENT
            - Each capture stores a snapshot id (returned in CLI output)
            - Pass --snapshot <id> to reuse the same map in follow-up interaction commands

            TROUBLESHOOTING
            If a window is missing, try `--mode screen` so Peekaboo can discover all windows before filtering.
            """,
            examples: [
                "peekaboo see --app Safari --path ~/Shots/safari.png --annotate",
                "peekaboo see --mode screen --json",
            ],
            agentGuidance: "Run `inspect_ui` for AX-only element IDs, or `see` when a screenshot/visual " +
                "element map is needed; both responses contain snapshot ids."),
        "click": ToolOverride(
            category: .automation,
            abstract: "High-precision UI clicking with fuzzy matching and snapshot-aware targeting.",
            discussion: """
            Clicks on UI elements or coordinates. CLI interactions use IDs from `see`;
            agent/MCP interactions may also use IDs from `inspect_ui`,
            fuzzy text queries, or raw coordinates. Clicks use background delivery by default;
            pass `--foreground` only when the target must receive a foreground mouse event.

            ELEMENT MATCHING
            - Fuzzy matching on element titles and labels
            - Smart waiting keeps checking until the element is reachable
            - Snapshot-aware IDs avoid ambiguity when multiple matches exist

            CLICK KIND
            - `--double`, `--triple`, `--right`, or `--middle` select one alternate click kind
            - `--long-press` presses and holds, and requires `--foreground`

            EXAMPLE
            peekaboo see --app Safari --json
            peekaboo click \"Submit\" --app Safari --snapshot "$SNAPSHOT_ID" --wait-for 1500ms
            peekaboo click --on "$ELEMENT_ID" --snapshot "$SNAPSHOT_ID" --double

            TROUBLESHOOTING
            If the element isn't found, refresh the snapshot with a fresh observation (`peekaboo see`
            in CLI, or `see`/`inspect_ui` in MCP), or provide a more precise query.
            """,
            examples: [
                "peekaboo click \"Submit\" --app Safari --snapshot \"$SNAPSHOT_ID\" --wait-for 1500ms",
                "peekaboo click --on \"$ELEMENT_ID\" --snapshot \"$SNAPSHOT_ID\"",
                "peekaboo click --on \"$ELEMENT_ID\" --snapshot \"$SNAPSHOT_ID\" --double",
            ],
            agentGuidance: "Prefer ID-based clicks when possible. Use default background delivery, and add " +
                "`--foreground` only when the app requires focused input. If fuzzy text fails, capture again and " +
                "reference the new element id."),
        "type": ToolOverride(
            category: .automation,
            abstract: "Types text into a targeted app or element with configurable cadence.",
            discussion: """
            Types raw text into the targeted app or focused element. Escape sequences are supported:
            - Use "\\n" for newline
            - Use "\\t" for tab
            - Use "\\\\" or the word "escape" to send a literal backslash

            EXAMPLE
            peekaboo type \"Hello\\nWorld\" --app TextEdit
            peekaboo type --text \"Press\\tescape\" --app TextEdit --delay 50ms

            TROUBLESHOOTING
            If the text appears in the wrong place, pass `--app`, `--pid`, `--window-id`, or `--snapshot` so
            Peekaboo can resolve a background target process. Use `--foreground` for apps that require focused input.
            """,
            examples: [
                "peekaboo type \"Hello\\nWorld\" --app TextEdit",
                "peekaboo type --text \"Name:\\tJohn\" --app TextEdit --delay 25ms",
            ],
            agentGuidance: "Remember to escape newline/tab characters when providing prompts; " +
                "literal newlines may be interpreted by the shell."),
        "clipboard": ToolOverride(
            category: .system,
            abstract: "Read/write the macOS clipboard (text, images, files) with save/restore slots.",
            discussion: """
            Use `action: set` with text, file_path, or data_base64+uti to write the clipboard.
            Use `action: get` to read it (optionally prefer a UTI or write binary to a filesystem outputPath).
            MCP stdout carries JSON-RPC, so outputPath `-` is rejected; omit it to receive UTF-8 text.
            `save`/`restore` keep user content safe while automating; `clear` empties the pasteboard.
            """,
            examples: [
                "peekaboo clipboard set --text \"hello world\"",
                "peekaboo clipboard get --output /tmp/clip.bin",
                "peekaboo clipboard save --slot original && " +
                    "peekaboo clipboard clear && " +
                    "peekaboo clipboard restore --slot original",
            ],
            agentGuidance: "Use save/restore when a workflow might overwrite the user's clipboard."),
        "browser": ToolOverride(
            category: .browser,
            abstract: "Control and inspect Chrome page content through Chrome DevTools MCP.",
            discussion: """
            Brokers Chrome DevTools MCP for page-level browser automation: snapshots, clicks, fills,
            navigation, console, network, screenshots, and performance traces.

            PERMISSIONS
            - Requires Chrome 144+.
            - The user must enable remote debugging at chrome://inspect/#remote-debugging.
            - The user must accept Chrome's remote debugging prompt.
            - Peekaboo disables Chrome DevTools MCP usage statistics and CrUX lookups.
            """,
            examples: [
                "browser { \"action\": \"status\" }",
                "browser { \"action\": \"connect\" }",
                "browser { \"action\": \"snapshot\" }",
            ],
            agentGuidance: "Use for Chrome web page content. Use native Peekaboo tools for macOS UI and dialogs."),
    ]

    // MARK: - Registry Access

    /// All registered tools collected from various definition structs
    @MainActor
    public static func configureDefaultServices(using factory: @escaping () -> any PeekabooServiceProviding) {
        self.defaultServicesFactory = factory
    }

    @MainActor
    public static func allTools(using services: (any PeekabooServiceProviding)? = nil) -> [PeekabooToolDefinition] {
        // Tools have been refactored into PeekabooAgentService+Tools.swift
        // We now create PeekabooToolDefinitions from the agent service
        let resolvedServices = services ?? MainActor.assumeIsolated {
            guard let factory = self.defaultServicesFactory else {
                fatalError("ToolRegistry default services factory not configured.")
            }
            return factory()
        }

        guard let agentService = try? PeekabooAgentService(services: resolvedServices) else {
            return []
        }

        // Get all agent tools
        let agentTools = agentService.createAgentTools()
        let filters = ToolFiltering.currentFilters()
        let filteredTools = ToolFiltering.apply(
            agentTools,
            filters: filters,
            log: { message in
                Logger(subsystem: "boo.peekaboo.tools", category: "registry")
                    .notice("\(message, privacy: .public)")
            })

        // Convert AgentTools to PeekabooToolDefinitions
        return filteredTools.compactMap { agentTool in
            self.convertAgentToolToDefinition(agentTool)
        }
    }

    /// Get tool by name
    @MainActor
    public static func tool(named name: String) -> PeekabooToolDefinition? {
        self.allTools().first { $0.name == name || $0.commandName == name }
    }

    /// Get tools grouped by category
    @MainActor
    public static func toolsByCategory() -> [ToolCategory: [PeekabooToolDefinition]] {
        Dictionary(grouping: self.allTools(), by: { $0.category })
    }

    /// Get parameter by name from a tool
    public static func parameter(named name: String, from tool: PeekabooToolDefinition) -> ParameterDefinition? {
        // Get parameter by name from a tool
        tool.parameters.first { $0.name == name }
    }

    // MARK: - Private Helpers

    /// Convert an AgentTool to PeekabooToolDefinition
    private static func convertAgentToolToDefinition(_ tool: AgentTool) -> PeekabooToolDefinition? {
        // Map common tool names to categories
        let category: ToolCategory = switch tool.name {
        case "see", "screenshot", "window_capture":
            .vision
        case "inspect_ui", "verify_state":
            .element
        case "click", "type", "press", "scroll", "drag", "move", "action":
            .automation
        case "app":
            .app
        case "menu_click", "list_menus":
            .menu
        case "dialog_click", "dialog_input":
            .dialog
        case "dock_launch", "list_dock":
            .dock
        case "browser":
            .browser
        case "shell", "clipboard", "copy_to_clipboard", "paste_from_clipboard":
            .system
        case "done", "need_info":
            .completion
        default:
            .system
        }

        // Convert parameters from agent tool schema
        let parameters = self.convertAgentParameters(tool.parameters)

        let baseDefinition = PeekabooToolDefinition(
            name: tool.name,
            commandName: tool.name.replacingOccurrences(of: "_", with: "-"),
            abstract: tool.description,
            discussion: tool.description,
            category: category,
            parameters: parameters,
            examples: [],
            agentGuidance: "")

        if let override = self.toolOverrides[tool.name] {
            return PeekabooToolDefinition(
                name: baseDefinition.name,
                commandName: baseDefinition.commandName,
                abstract: override.abstract ?? baseDefinition.abstract,
                discussion: override.discussion ?? baseDefinition.discussion,
                category: override.category ?? baseDefinition.category,
                parameters: baseDefinition.parameters,
                examples: override.examples ?? baseDefinition.examples,
                agentGuidance: override.agentGuidance ?? baseDefinition.agentGuidance)
        }

        return baseDefinition
    }

    /// Convert agent tool parameters to parameter definitions
    private static func convertAgentParameters(_ params: AgentToolParameters?) -> [ParameterDefinition] {
        // Convert agent tool parameters to parameter definitions
        guard let params else { return [] }

        var definitions: [ParameterDefinition] = []

        // Extract properties from the schema
        for (name, property) in params.properties {
            let type: UnifiedParameterType = switch property.type {
            case .string:
                .string
            case .number:
                .number
            case .integer:
                .integer
            case .boolean:
                .boolean
            case .array:
                .array
            case .object:
                .object
            case .null:
                .string
            }

            let isRequired = params.required.contains(name)

            definitions.append(ParameterDefinition(
                name: name,
                type: type,
                description: property.description,
                required: isRequired,
                defaultValue: nil,
                options: property.enumValues,
                cliOptions: CLIOptions(argumentType: isRequired ? .argument : .option)))
        }

        return definitions
    }
}
