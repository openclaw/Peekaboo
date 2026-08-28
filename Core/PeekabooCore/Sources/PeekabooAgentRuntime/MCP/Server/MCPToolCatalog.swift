import PeekabooAutomation
import TachikomaMCP

/// Canonical catalog of native MCP tools exposed by Peekaboo.
@MainActor
public enum MCPToolCatalog {
    struct Selection: Sendable {
        fileprivate let toolNames: [String]

        func contains(_ toolName: String) -> Bool {
            self.toolNames.contains(toolName)
        }
    }

    /// An explicit environment allow-list is immutable for the server process and replaces the
    /// configured allow-list. It can therefore prove that no registered tool can reach SCK.
    /// Missing allow-lists, nested Agent execution, and unknown future tools stay fail-closed.
    public nonisolated static func explicitEnvironmentAllowListProvesNoScreenCaptureKitUse(
        environment: [String: String]) -> Bool
    {
        let filters = ToolFiltering.filters(config: nil, environment: environment)
        guard case .env = filters.allowSource, !filters.allow.isEmpty else { return false }

        return filters.allow.subtracting(filters.deny).allSatisfy { toolName in
            if toolName == "agent" {
                return false
            }
            guard let profile = MCPToolCaptureRequirement.profile(toolName: toolName) else { return false }
            return profile == .never
        }
    }

    public static func tools(
        context: MCPToolContext,
        inputPolicy: UIInputPolicy,
        filters: ToolFilters = ToolFiltering.currentFilters(),
        log: ((String) -> Void)? = nil) -> [any MCPTool]
    {
        self.filteredTools(
            self.unfilteredTools(context: context),
            context: context,
            inputPolicy: inputPolicy,
            filters: filters,
            log: log)
    }

    static func selection(
        context: MCPToolContext,
        inputPolicy: UIInputPolicy,
        filters: ToolFilters,
        log: ((String) -> Void)? = nil) -> Selection
    {
        let tools = self.filteredTools(
            self.unfilteredTools(context: context),
            context: context,
            inputPolicy: inputPolicy,
            filters: filters,
            log: log)
        return Selection(toolNames: tools.map(\.name))
    }

    static func tools(context: MCPToolContext, selection: Selection) -> [any MCPTool] {
        let selectedNames = Set(selection.toolNames)
        return self.unfilteredTools(context: context).filter { selectedNames.contains($0.name) }
    }

    private static func filteredTools(
        _ tools: [any MCPTool],
        context: MCPToolContext,
        inputPolicy: UIInputPolicy,
        filters: ToolFilters,
        log: ((String) -> Void)?) -> [any MCPTool]
    {
        let authorityFilteredTools = tools.filter { tool in
            let isExposed = context.executionPolicy.exposesToolInCatalog(named: tool.name)
            if !isExposed {
                log?("Tool '\(tool.name)' not exposed under \(context.executionPolicy.rawValue) authority.")
            }
            return isExposed
        }
        let filteredTools = ToolFiltering.apply(
            authorityFilteredTools,
            filters: filters,
            log: log)

        return ToolFiltering.applyInputStrategyAvailability(
            filteredTools,
            policy: inputPolicy,
            log: log)
    }

    public static func unfilteredTools(context: MCPToolContext) -> [any MCPTool] {
        [
            // Core tools
            ImageTool(context: context),
            CaptureTool(context: context),
            AnalyzeTool(),
            BrowserTool(context: context),
            PermissionsTool(context: context),
            SleepTool(),

            // UI automation tools
            SeeTool(context: context),
            InspectUITool(context: context),
            VerifyStateTool(context: context),
            ClickTool(context: context),
            TypeTool(context: context),
            SetValueTool(context: context),
            ActionTool(context: context),
            ScrollTool(context: context),
            PressTool(context: context),
            DragTool(context: context),
            MoveTool(context: context),

            // App management tools
            AppTool(context: context),
            WindowTool(context: context),
            MenuTool(context: context),

            // System tools
            ClipboardTool(context: context),
            PasteTool(context: context),

            // Advanced tools
            MCPAgentTool(context: context),
            DockTool(context: context),
            DialogTool(context: context),
            SpaceTool(context: context),
        ]
    }
}
