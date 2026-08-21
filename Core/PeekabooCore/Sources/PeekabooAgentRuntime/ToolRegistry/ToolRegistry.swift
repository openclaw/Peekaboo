import Foundation
import PeekabooAutomation
import Tachikoma

/// Central registry for all Peekaboo tools
/// This registry collects tool definitions from various tool implementation files
@available(macOS 14.0, *)
public enum ToolRegistry {
    @MainActor
    private static var defaultServicesFactory: (() -> any PeekabooServiceProviding)?

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

        // Use the same background-only, Shell-free catalog that a public Agent session receives.
        let agentTools = agentService.publicAgentTools()

        // Convert AgentTools to PeekabooToolDefinitions
        return agentTools.map { agentTool in
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
    private static func convertAgentToolToDefinition(_ tool: AgentTool) -> PeekabooToolDefinition {
        // Map common tool names to categories
        let category: ToolCategory = switch tool.name {
        case "see", "image", "capture", "analyze":
            .vision
        case "inspect_ui", "verify_state":
            .element
        case "click", "type", "press", "scroll", "drag", "move", "action", "set_value", "paste":
            .automation
        case "window", "space":
            .window
        case "app":
            .app
        case "menu":
            .menu
        case "dialog":
            .dialog
        case "dock":
            .dock
        case "browser":
            .browser
        case "shell", "clipboard", "permissions", "sleep":
            .system
        case "done", "need_info":
            .completion
        default:
            .system
        }

        // Convert parameters from agent tool schema
        let parameters = self.convertAgentParameters(tool.parameters)

        return PeekabooToolDefinition(
            name: tool.name,
            commandName: tool.name.replacingOccurrences(of: "_", with: "-"),
            abstract: tool.description,
            discussion: tool.description,
            category: category,
            parameters: parameters,
            examples: [])
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
