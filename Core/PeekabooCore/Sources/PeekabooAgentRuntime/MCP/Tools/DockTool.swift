import Algorithms
import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for interacting with the macOS Dock
public struct DockTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "DockTool")
    private let context: MCPToolContext

    public let name = "dock"

    public var description: String {
        if self.context.executionPolicy == .backgroundOnly {
            return """
            Inspect the macOS Dock under immutable background-only authority. The available action is `list`.
            Dock launch, context menus, hide, and show mutate shared desktop UI and require a human-authorized
            foreground-capable Agent session or the standalone CLI.
            \(PeekabooMCPVersion.banner)
            """
        }

        return """
        Interact with the macOS Dock - launch apps, show context menus, hide/show dock.
        Actions: launch, right-click (with menu selection), hide, show, list
        launch and right-click activate global Dock UI and require foreground=true.
        Can list all dock items including persistent and running applications.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6
        and anthropic/claude-opus-5
        """
    }

    public var inputSchema: Value {
        let foregroundCapable = self.context.executionPolicy != .backgroundOnly
        let actions = foregroundCapable ? ["launch", "right-click", "hide", "show", "list"] : ["list"]
        var properties: [String: Value] = [
            "action": SchemaBuilder.string(
                description: foregroundCapable
                    ? "Action to perform on the Dock"
                    : "Background-safe Dock action; mutations are unavailable",
                enum: actions),
            "include_all": SchemaBuilder.boolean(
                description: "Include all items when listing (default: false)",
                default: false),
        ]
        if foregroundCapable {
            properties["app"] = SchemaBuilder.string(
                description: "Application name for launch/right-click actions")
            properties["select"] = SchemaBuilder.string(
                description: "Menu item to select after right-clicking")
            properties["foreground"] = SchemaBuilder.boolean(
                description: "Confirm foreground/global Dock UI for launch and right-click actions.",
                default: false)
        }
        return SchemaBuilder.object(
            properties: properties,
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

        let app = arguments.getString("app")
        let select = arguments.getString("select")
        let includeAll = arguments.getBool("include_all") ?? false
        let foreground = arguments.getBool("foreground") ?? false

        if action == "launch" || action == "right-click", !foreground {
            return ToolResponse.error(
                "Dock \(action) activates global Dock UI and requires foreground=true.")
        }

        let dockService = self.context.dock

        do {
            let startTime = Date()

            switch action {
            case "launch":
                return try await self.handleLaunch(
                    service: dockService,
                    app: app,
                    startTime: startTime)

            case "right-click":
                return try await self.handleRightClick(
                    service: dockService,
                    app: app,
                    menuItem: select,
                    startTime: startTime)

            case "hide":
                return try await self.handleHide(
                    service: dockService,
                    startTime: startTime)

            case "show":
                return try await self.handleShow(
                    service: dockService,
                    startTime: startTime)

            case "list":
                return try await self.handleList(
                    service: dockService,
                    includeAll: includeAll,
                    startTime: startTime)

            default:
                return ToolResponse
                    .error("Unknown action: \(action). Supported actions: launch, right-click, hide, show, list")
            }

        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil)
        } catch {
            self.logger.error("Dock operation execution failed: \(error)")
            return ToolResponse.error("Failed to \(action) dock: \(error.localizedDescription)")
        }
    }

    // MARK: - Action Handlers

    private func handleLaunch(
        service: any DockServiceProtocol,
        app: String?,
        startTime: Date) async throws -> ToolResponse
    {
        guard let app else {
            return ToolResponse.error("Must specify 'app' for launch action")
        }

        let result = try await service.launchFromDockResult(appName: app)
        let outcome: DesktopActionOutcome
        do {
            outcome = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
                result,
                policy: .confirmedOrDispatched(requiring: .foreground),
                targetRequirement: service is any DockServiceActionResultProviding ? .required : .optional,
                operation: "Dock launch",
                missingTargetMessage: "Dock launch returned without its resolved target identity.",
                rejectedOutcomeMessage: "Dock launch did not return a successful outcome.")
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil,
                additionalFields: MCPDesktopTargetMetadataProjector.fields(result.targetIdentity))
        }

        let executionTime = Date().timeIntervalSince(startTime)

        let duration = self.formatDuration(executionTime)
        let message = if outcome.state == .confirmedNoChange {
            "\(AgentDisplayTokens.Status.success) \(app) was already running; no Dock launch was needed in \(duration)"
        } else {
            "\(AgentDisplayTokens.Status.success) Launched \(app) from dock in \(duration)"
        }

        let baseMeta: [String: Value] = [
            "app_name": .string(app),
            "execution_time": .double(executionTime),
        ]
        let summary = ToolEventSummary(
            targetApp: app,
            actionDescription: "Dock Launch",
            notes: nil)
        let metadata = try MCPDesktopTargetMetadataProjector.fields(result.targetIdentity, merging: baseMeta)
        return try ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: ToolEventSummary.merge(
                summary: summary,
                into: MCPToolResponseMetadataProjector.metadata(
                    merging: metadata,
                    outcome: outcome)))
    }

    private func handleRightClick(
        service: any DockServiceProtocol,
        app: String?,
        menuItem: String?,
        startTime: Date) async throws -> ToolResponse
    {
        guard let app else {
            return ToolResponse.error("Must specify 'app' for right-click action")
        }

        let result = try await service.rightClickDockItemResult(appName: app, menuItem: menuItem)
        let outcome: DesktopActionOutcome
        do {
            outcome = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
                result,
                policy: .confirmedOrDispatched(requiring: .foreground),
                targetRequirement: service is any DockServiceActionResultProviding ? .required : .optional,
                operation: "Dock context-menu action",
                missingTargetMessage: "Dock context-menu action returned without its resolved target identity.",
                rejectedOutcomeMessage: "Dock context-menu action did not return a successful outcome.")
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil,
                additionalFields: MCPDesktopTargetMetadataProjector.fields(result.targetIdentity))
        }

        let executionTime = Date().timeIntervalSince(startTime)

        var message: String
        if outcome.state == .confirmedNoChange {
            message = "\(AgentDisplayTokens.Status.success) The Dock context already matched " +
                "the requested state for \(app)"
        } else {
            message = "\(AgentDisplayTokens.Status.success) Right-clicked \(app) in dock"
            if let menuItem {
                message += " and selected '\(menuItem)'"
            }
        }
        message += " in \(self.formatDuration(executionTime))"

        let baseMeta: [String: Value] = [
            "app_name": .string(app),
            "menu_item": menuItem != nil ? .string(menuItem!) : .null,
            "execution_time": .double(executionTime),
        ]
        let summary = ToolEventSummary(
            targetApp: app,
            actionDescription: "Dock Menu",
            notes: menuItem ?? "Context menu")
        let metadata = try MCPDesktopTargetMetadataProjector.fields(result.targetIdentity, merging: baseMeta)
        return try ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: ToolEventSummary.merge(
                summary: summary,
                into: MCPToolResponseMetadataProjector.metadata(
                    merging: metadata,
                    outcome: outcome)))
    }

    private func handleHide(
        service: any DockServiceProtocol,
        startTime: Date) async throws -> ToolResponse
    {
        let result = try await service.hideDockResult()
        let outcome = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
            result.outcome,
            policy: .confirmedOrDispatched(requiring: .background),
            operation: "Dock hide",
            rejectedOutcomeMessage: "Dock hide did not return a successful outcome.")

        let executionTime = Date().timeIntervalSince(startTime)

        let duration = self.formatDuration(executionTime)
        let message = if outcome.state == .confirmedNoChange {
            "\(AgentDisplayTokens.Status.success) Dock was already hidden (auto-hide enabled) in \(duration)"
        } else {
            "\(AgentDisplayTokens.Status.success) Hidden dock (enabled auto-hide) in \(duration)"
        }

        let baseMeta: [String: Value] = [
            "auto_hide_enabled": .bool(true),
            "execution_time": .double(executionTime),
        ]
        let summary = ToolEventSummary(actionDescription: "Dock Hide", notes: nil)
        return try ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: ToolEventSummary.merge(
                summary: summary,
                into: MCPToolResponseMetadataProjector.metadata(merging: baseMeta, outcome: outcome)))
    }

    private func handleShow(
        service: any DockServiceProtocol,
        startTime: Date) async throws -> ToolResponse
    {
        let result = try await service.showDockResult()
        let outcome = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
            result.outcome,
            policy: .confirmedOrDispatched(requiring: .background),
            operation: "Dock show",
            rejectedOutcomeMessage: "Dock show did not return a successful outcome.")

        let executionTime = Date().timeIntervalSince(startTime)

        let duration = self.formatDuration(executionTime)
        let message = if outcome.state == .confirmedNoChange {
            "\(AgentDisplayTokens.Status.success) Dock was already shown (auto-hide disabled) in \(duration)"
        } else {
            "\(AgentDisplayTokens.Status.success) Shown dock (disabled auto-hide) in \(duration)"
        }

        let baseMeta: [String: Value] = [
            "auto_hide_enabled": .bool(false),
            "execution_time": .double(executionTime),
        ]
        let summary = ToolEventSummary(actionDescription: "Dock Show", notes: nil)
        return try ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: ToolEventSummary.merge(
                summary: summary,
                into: MCPToolResponseMetadataProjector.metadata(merging: baseMeta, outcome: outcome)))
    }

    private func handleList(
        service: any DockServiceProtocol,
        includeAll: Bool,
        startTime: Date) async throws -> ToolResponse
    {
        let dockItems = try await service.listDockItems(includeAll: includeAll)
        let executionTime = Date().timeIntervalSince(startTime)

        let itemList = dockItems.indexed().map { index, item in
            var info = "[\(index)] \(item.title) (\(item.itemType.rawValue))"
            if let isRunning = item.isRunning {
                info += isRunning ? " [RUNNING]" : " [NOT RUNNING]"
            }
            if let bundleId = item.bundleIdentifier {
                info += " [\(bundleId)]"
            }
            return info
        }.joined(separator: "\n")

        let filterText = includeAll ? "(including separators/spacers)" : "(applications and folders only)"
        let duration = self.formatDuration(executionTime)
        let message = """
        🚢 Dock Items \(filterText) (\(dockItems.count) total):
        \(itemList)

        Completed in \(duration)
        """
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let baseMeta: [String: Value] = [
            "dock_item_count": .double(Double(dockItems.count)),
            "include_all": .bool(includeAll),
            "dock_items": .array(dockItems.map { item in
                .object([
                    "index": .double(Double(item.index)),
                    "title": .string(item.title),
                    "item_type": .string(item.itemType.rawValue),
                    "is_running": item.isRunning != nil ? .bool(item.isRunning!) : .null,
                    "bundle_identifier": item.bundleIdentifier != nil ? .string(item.bundleIdentifier!) : .null,
                    "position": item.position != nil ? .object([
                        "x": .double(Double(item.position!.x)),
                        "y": .double(Double(item.position!.y)),
                    ]) : .null,
                    "size": item.size != nil ? .object([
                        "width": .double(Double(item.size!.width)),
                        "height": .double(Double(item.size!.height)),
                    ]) : .null,
                ])
            }),
            "execution_time": .double(executionTime),
        ]
        let summary = ToolEventSummary(
            actionDescription: "Dock List",
            notes: "\(dockItems.count) items")
        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: ToolEventSummary.merge(summary: summary, into: .object(baseMeta)))
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%.2f", duration) + "s"
    }
}
