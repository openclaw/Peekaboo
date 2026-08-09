import Foundation
import MCP
import PeekabooAutomation
import TachikomaMCP

/// MCP tool for interacting with application menu bars
public struct MenuTool: MCPTool {
    public let name = "menu"
    private let context: MCPToolContext

    public var description: String {
        """
        Interact with application menu bars - list available menus and menu items
        for an application, or click on a specific menu item using path notation.

        Actions:
        - list: Discover all available menus and menu items for an application
        - click: Click on a specific menu item using path notation

        Target applications by name (e.g., "Safari"), bundle ID (e.g., "com.apple.Safari"),
        or process ID (e.g., "PID:663"). Fuzzy matching is supported for names.

        Examples:
        - List Chrome menus: { "action": "list", "app": "Google Chrome" }
        - Save document: { "action": "click", "app": "TextEdit", "path": "File > Save" }
        - Copy selection: { "action": "click", "app": "Safari", "path": "Edit > Copy" }
        \(PeekabooMCPVersion.banner) using openai/gpt-5.5
        and anthropic/claude-opus-4-8
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "action": SchemaBuilder.string(
                    description: """
                    Action to perform. Use 'list' to discover menus or 'click' to
                    interact with menu items.
                    """.trimmingCharacters(in: .whitespacesAndNewlines),
                    enum: ["list", "click"]),
                "app": SchemaBuilder.string(
                    description: "Target application name, bundle ID, or process ID " +
                        "(required for list and click actions)"),
                "path": SchemaBuilder.string(
                    description: "Menu path for nested items (e.g., 'File > Save As...' or 'Edit > Copy')"),
                "item": SchemaBuilder.string(
                    description: "Simple menu item to click (for non-nested items)"),
                "foreground": SchemaBuilder.boolean(
                    description: "Focus the target before list/click. Defaults to background AX access.",
                    default: false),
            ],
            required: ["action"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        guard let action = arguments.getString("action") else {
            return ToolResponse.error("Missing required parameter: action")
        }

        switch action {
        case "list":
            return try await self.handleListAction(arguments: arguments)
        case "click":
            return try await self.handleClickAction(arguments: arguments)
        default:
            let errorMessage = "Invalid action: \(action). Must be one of: list, click"
            return ToolResponse.error(errorMessage)
        }
    }

    // MARK: - Action Handlers

    private func handleListAction(arguments: ToolArguments) async throws -> ToolResponse {
        guard let app = arguments.getString("app") else {
            return ToolResponse.error("Missing required parameter: app (required for list action)")
        }

        if arguments.getBool("foreground") == true {
            try await self.context.windows.focusWindow(target: .application(app))
        }

        do {
            let menuStructure = try await self.context.menu.listMenus(for: app)
            let formattedOutput = self.formatMenuStructure(menuStructure)

            let baseMeta: Value = .object([
                "app": .string(menuStructure.application.name),
                "total_menus": .int(menuStructure.menus.count),
                "total_items": .int(menuStructure.totalItems),
            ])
            let summary = ToolEventSummary(
                targetApp: menuStructure.application.name,
                actionDescription: "List Menus",
                notes: "\(menuStructure.menus.count) menus / \(menuStructure.totalItems) items")
            return ToolResponse.text(
                formattedOutput,
                meta: ToolEventSummary.merge(summary: summary, into: baseMeta))
        } catch {
            return ToolResponse.error("Failed to list menus for app '\(app)': \(error.localizedDescription)")
        }
    }

    private func handleClickAction(arguments: ToolArguments) async throws -> ToolResponse {
        guard let app = arguments.getString("app") else {
            return ToolResponse.error("Missing required parameter: app (required for click action)")
        }

        if arguments.getBool("foreground") == true {
            try await self.context.windows.focusWindow(target: .application(app))
        }

        // Try path first, then item
        if let path = arguments.getString("path") {
            do {
                try await self.context.menu.clickMenuItem(app: app, itemPath: path)
                let summary = ToolEventSummary(
                    targetApp: app,
                    actionDescription: "Menu Click",
                    notes: path)
                return ToolResponse.text(
                    "\(AgentDisplayTokens.Status.success) Successfully clicked menu item: \(path)",
                    meta: ToolEventSummary.merge(summary: summary, into: nil))
            } catch {
                return ToolResponse
                    .error("Failed to click menu item '\(path)' in app '\(app)': \(error.localizedDescription)")
            }
        } else if let item = arguments.getString("item") {
            do {
                try await self.context.menu.clickMenuItemByName(app: app, itemName: item)
                let summary = ToolEventSummary(
                    targetApp: app,
                    actionDescription: "Menu Click",
                    notes: item)
                return ToolResponse.text(
                    "\(AgentDisplayTokens.Status.success) Successfully clicked menu item: \(item)",
                    meta: ToolEventSummary.merge(summary: summary, into: nil))
            } catch {
                return ToolResponse
                    .error("Failed to click menu item '\(item)' in app '\(app)': \(error.localizedDescription)")
            }
        } else {
            return ToolResponse
                .error("Missing required parameter: either 'path' or 'item' must be provided for click action")
        }
    }

    // MARK: - Formatting Helpers

    private func formatMenuStructure(_ structure: MenuStructure) -> String {
        var output = "[menu] Menu Structure for \(structure.application.name)\n\n"

        for menu in structure.menus {
            output += self.formatMenu(menu, indent: 0)
        }

        output += "\n📊 Summary: \(structure.menus.count) menus, \(structure.totalItems) total items"

        return output
    }

    private func formatMenu(_ menu: Menu, indent: Int) -> String {
        let indentStr = String(repeating: "  ", count: indent)
        var output = "\(indentStr)📁 \(menu.title)"

        if !menu.isEnabled {
            output += " (disabled)"
        }

        output += "\n"

        for item in menu.items {
            output += self.formatMenuItem(item, indent: indent + 1)
        }

        return output
    }

    private func formatMenuItem(_ item: MenuItem, indent: Int) -> String {
        let indentStr = String(repeating: "  ", count: indent)
        var output = ""

        if item.isSeparator {
            output += "\(indentStr)┈┈┈┈┈┈┈┈┈┈\n"
            return output
        }

        let icon = item.submenu.isEmpty ? "•" : "📂"
        output += "\(indentStr)\(icon) \(item.title)"

        // Add keyboard shortcut if available
        if let shortcut = item.keyboardShortcut {
            output += " (\(shortcut.displayString))"
        }

        // Add state indicators
        var indicators: [String] = []
        if !item.isEnabled {
            indicators.append("disabled")
        }
        if item.isChecked {
            indicators.append("checked")
        }

        if !indicators.isEmpty {
            output += " [\(indicators.joined(separator: ", "))]"
        }

        output += "\n"

        // Add submenu items
        for subitem in item.submenu {
            output += self.formatMenuItem(subitem, indent: indent + 1)
        }

        return output
    }
}
