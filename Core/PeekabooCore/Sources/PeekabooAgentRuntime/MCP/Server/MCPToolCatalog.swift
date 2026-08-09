import PeekabooAutomation
import TachikomaMCP

/// Canonical catalog of native MCP tools exposed by Peekaboo.
@MainActor
public enum MCPToolCatalog {
    public static func tools(
        context: MCPToolContext,
        inputPolicy: UIInputPolicy,
        filters: ToolFilters = ToolFiltering.currentFilters(),
        log: ((String) -> Void)? = nil) -> [any MCPTool]
    {
        let filteredTools = ToolFiltering.apply(
            self.unfilteredTools(context: context),
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
            ListTool(context: context),
            PermissionsTool(context: context),
            SleepTool(),

            // UI automation tools
            SeeTool(context: context),
            InspectUITool(context: context),
            VerifyStateTool(context: context),
            ClickTool(context: context),
            TypeTool(context: context),
            SetValueTool(context: context),
            PerformActionTool(context: context),
            ScrollTool(context: context),
            HotkeyTool(context: context),
            SwipeTool(context: context),
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
