import Foundation
import MCP
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for interacting with application menu bars
public struct MenuTool: MCPTool {
    private struct PreparedApplicationTarget {
        let application: ServiceApplicationInfo
        let identity: ApplicationProcessIdentity
        let window: DesktopTargetPlanning.WindowMutationPlan?

        var identifier: String {
            "PID:\(self.identity.processIdentifier)"
        }
    }

    private struct ClickResponsePolicy {
        let requiredDeliveryMode: DesktopActionOutcome.Delivery.Mode
        let requiresTarget: Bool
    }

    public let name = "menu"
    private let context: MCPToolContext

    public var description: String {
        if self.context.executionPolicy == .backgroundOnly {
            return """
            Inspect or click application menu items under immutable background-only authority. Available actions are
            `list` and `click`; neither activates the application. Click requires an exact app name, bundle ID, or PID,
            while read-only list retains fuzzy name matching. Foreground menu expansion is unavailable in this session.

            Examples:
            - List Chrome menus: { "action": "list", "app": "Google Chrome" }
            - Save document: { "action": "click", "app": "TextEdit", "path": "File > Save" }
            \(PeekabooMCPVersion.banner)
            """
        }

        return """
        Interact with application menu bars - list available menus and menu items
        for an application, or click on a specific menu item using path notation.

        Actions:
        - list: Discover all available menus and menu items for an application
        - click: Click on a specific menu item using path notation

        Target applications by name (e.g., "Safari"), bundle ID (e.g., "com.apple.Safari"),
        or process ID (e.g., "PID:663"). Click and foreground-list actions require an exact
        name, bundle ID, or PID; background read-only listing retains fuzzy name matching.

        Examples:
        - List Chrome menus: { "action": "list", "app": "Google Chrome" }
        - Save document: { "action": "click", "app": "TextEdit", "path": "File > Save" }
        - Copy selection: { "action": "click", "app": "Safari", "path": "Edit > Copy" }
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6
        and anthropic/claude-opus-5
        """
    }

    public var inputSchema: Value {
        let foregroundCapable = self.context.executionPolicy != .backgroundOnly
        var properties: [String: Value] = [
            "action": SchemaBuilder.string(
                description: "Use 'list' to discover menus or 'click' to interact with menu items.",
                enum: ["list", "click"]),
            "app": SchemaBuilder.string(
                description: "Target application name, bundle ID, or process ID. Click and foreground list " +
                    "require an exact selector; background list permits fuzzy names."),
            "path": SchemaBuilder.string(
                description: "Menu path for nested items (e.g., 'File > Save As...' or 'Edit > Copy')"),
            "item": SchemaBuilder.string(description: "Simple menu item to click (for non-nested items)"),
        ]
        if foregroundCapable {
            properties["foreground"] = SchemaBuilder.boolean(
                description: "Focus the target before list/click. Defaults to background AX access.",
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

        let foreground = arguments.getBool("foreground") == true
        let target: PreparedApplicationTarget?
        do {
            target = foreground
                ? try await self.prepareApplicationTarget(
                    app: app,
                    operation: "Foreground menu list",
                    requiresWindow: true)
                : nil
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil)
        }

        let focusResult: UIAutomationActionResult<Void>?
        do {
            focusResult = try await self.foregroundFocusResult(
                target: target,
                requested: foreground)
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil)
        }

        do {
            let menuStructure = if let target {
                try await self.context.menu.listMenus(request: MenuListRequest(
                    appIdentifier: target.identifier,
                    expectedIdentity: target.identity))
            } else {
                try await self.context.menu.listMenus(for: app)
            }
            let formattedOutput = self.formatMenuStructure(menuStructure)

            var baseMeta: [String: Value] = [
                "app": .string(menuStructure.application.name),
                "total_menus": .int(menuStructure.menus.count),
                "total_items": .int(menuStructure.totalItems),
            ]
            if let focusResult {
                baseMeta = try MCPDesktopTargetMetadataProjector.fields(
                    focusResult.targetIdentity,
                    merging: baseMeta)
                if let invalidated = await MCPDesktopActionSnapshotInvalidator.invalidate(
                    uiSnapshots: self.context.uiSnapshots,
                    snapshotID: nil,
                    outcome: focusResult.outcome)
                {
                    baseMeta["invalidated_snapshot"] = .string(invalidated)
                }
            }
            let summary = ToolEventSummary(
                targetApp: menuStructure.application.name,
                actionDescription: "List Menus",
                notes: "\(menuStructure.menus.count) menus / \(menuStructure.totalItems) items")
            return try ToolResponse.text(
                formattedOutput,
                meta: ToolEventSummary.merge(
                    summary: summary,
                    into: MCPToolResponseMetadataProjector.metadata(
                        merging: baseMeta,
                        outcome: focusResult?.outcome)))
        } catch {
            if let failure = ObservationActionResultSupport.preservingFailure(
                error,
                after: focusResult,
                operation: "listing foreground menus") as? DesktopActionFailure
            {
                return try await MCPDesktopActionFailureHandler.response(
                    for: failure,
                    uiSnapshots: self.context.uiSnapshots,
                    snapshotID: nil)
            }
            return ToolResponse.error("Failed to list menus for app '\(app)': \(error.localizedDescription)")
        }
    }

    private func handleClickAction(arguments: ToolArguments) async throws -> ToolResponse {
        guard let app = arguments.getString("app") else {
            return ToolResponse.error("Missing required parameter: app (required for click action)")
        }
        let path = arguments.getString("path")
        let item = arguments.getString("item")
        guard (path != nil) != (item != nil) else {
            return ToolResponse.error("Menu click requires exactly one of 'path' or 'item'")
        }

        let foreground = arguments.getBool("foreground") == true
        let target: PreparedApplicationTarget
        let service: any MenuServiceGenerationPinnedActionResultProviding
        do {
            target = try await self.prepareApplicationTarget(
                app: app,
                operation: "Menu click",
                requiresWindow: foreground)
            service = try self.generationPinnedMenuService()
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil)
        }

        let focusResult: UIAutomationActionResult<Void>?
        do {
            focusResult = try await self.foregroundFocusResult(
                target: target,
                requested: foreground)
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil)
        }

        // Try path first, then item
        if let path {
            do {
                let request = try MenuItemActionRequest(
                    appIdentifier: target.identifier,
                    itemPath: path,
                    expectedIdentity: target.identity,
                    deliveryMode: foreground ? .foreground : .background)
                let rawResult = try await service.clickMenuItemActionResult(request: request)
                let result = try service.validatedGenerationPinnedMenuResult(
                    rawResult,
                    expectedIdentity: target.identity,
                    operation: foreground ? "Foreground menu click" : "Background menu click")
                return try await self.clickResponse(
                    app: target.application.name,
                    item: path,
                    result: result,
                    focusResult: focusResult,
                    policy: .init(
                        requiredDeliveryMode: foreground ? .foreground : .background,
                        requiresTarget: true))
            } catch let failure as DesktopActionFailure {
                return try await self.failureResponse(
                    failure,
                    after: focusResult,
                    operation: "menu click")
            } catch {
                return try await self.failureResponse(
                    error,
                    after: focusResult,
                    operation: "menu click")
            }
        } else if let item {
            do {
                let request = try MenuItemByNameActionRequest(
                    appIdentifier: target.identifier,
                    itemName: item,
                    expectedIdentity: target.identity,
                    deliveryMode: foreground ? .foreground : .background)
                let rawResult = try await service.clickMenuItemByNameActionResult(request: request)
                let result = try service.validatedGenerationPinnedMenuResult(
                    rawResult,
                    expectedIdentity: target.identity,
                    operation: foreground ? "Foreground named menu click" : "Background named menu click")
                return try await self.clickResponse(
                    app: target.application.name,
                    item: item,
                    result: result,
                    focusResult: focusResult,
                    policy: .init(
                        requiredDeliveryMode: foreground ? .foreground : .background,
                        requiresTarget: true))
            } catch let failure as DesktopActionFailure {
                return try await self.failureResponse(
                    failure,
                    after: focusResult,
                    operation: "menu click")
            } catch {
                return try await self.failureResponse(
                    error,
                    after: focusResult,
                    operation: "menu click")
            }
        } else {
            return ToolResponse
                .error("Missing required parameter: either 'path' or 'item' must be provided for click action")
        }
    }

    private func foregroundFocusResult(
        target: PreparedApplicationTarget?,
        requested: Bool) async throws -> UIAutomationActionResult<Void>?
    {
        guard requested else { return nil }
        guard let target else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "Foreground menu access reached focus without exact application authority.",
                hint: "Retry through the current Peekaboo runtime.")
        }
        guard self.context.windows is any WindowManagementPinnedFocusActionResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "Foreground menu access requires result-aware exact-window focus.",
                hint: "Update the runtime host before retrying with foreground=true.")
        }

        guard let window = target.window else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "Foreground menu access reached focus without exact window authority.",
                hint: "Retry through the current Peekaboo runtime.")
        }

        do {
            let result = try await self.context.windows.focusWindowResult(
                target: window.target,
                expectedIdentity: window.identity)
            return try self.context.windows.validatedWindowMutationResult(
                result,
                expectedIdentity: window.identity,
                operation: "Foreground menu focus")
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            throw DesktopActionFailure.indeterminate(
                delivery: nil,
                evidence: .completionUnknown,
                message: "Foreground menu focus may have changed desktop state before failing.",
                hint: "Observe the exact window before retrying foreground menu access.",
                causeDescription: error.localizedDescription)
                .attributed(to: window.identity.actionTargetReceipt)
        }
    }

    private func failureResponse(
        _ error: any Error,
        after focusResult: UIAutomationActionResult<Void>?,
        operation: String,
        additionalFields: [String: Value] = [:]) async throws -> ToolResponse
    {
        let preserved = ObservationActionResultSupport.preservingFailure(
            error,
            after: focusResult,
            operation: operation)
        guard let failure = preserved as? DesktopActionFailure else {
            return ToolResponse.error(preserved.localizedDescription)
        }
        return try await MCPDesktopActionFailureHandler.response(
            for: failure,
            uiSnapshots: self.context.uiSnapshots,
            snapshotID: nil,
            additionalFields: additionalFields)
    }

    private static func aggregateSuccessfulResults(
        focusResult: UIAutomationActionResult<Void>?,
        menuResult: UIAutomationActionResult<Void>) throws -> UIAutomationActionResult<Void>
    {
        guard let focusResult else { return menuResult }
        guard let focusOutcome = focusResult.outcome,
              let menuOutcome = menuResult.outcome
        else {
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "Foreground focus or menu click omitted its canonical outcome.",
                hint: "Observe the target before retrying and update the runtime host.")
        }

        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.reportedOutcome(focusOutcome, defaultDispatchedUnitCount: .one))
        sequence.record(.reportedOutcome(menuOutcome, defaultDispatchedUnitCount: .one))
        let targetIdentity: DesktopTargetIdentity?
        do {
            targetIdentity = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.coalesce([
                focusResult.targetIdentity,
                menuResult.targetIdentity,
            ])
        } catch {
            let failure = DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Foreground focus and menu click reported incompatible targets.",
                hint: "Observe both targets before retrying.",
                causeDescription: error.localizedDescription)
            throw sequence.failure(
                combining: failure,
                message: failure.message,
                hint: failure.hint,
                causeDescription: failure.causeDescription)
        }
        let resolution = sequence.successResolution()
        guard let outcome = resolution.outcome else {
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                unitCount: resolution.mutationDisposition.unitCount,
                message: "Foreground focus and menu click returned incompatible result routes.",
                hint: "Observe the target before retrying the menu action.")
        }
        return UIAutomationActionResult(
            payload: (),
            outcome: outcome,
            targetIdentity: targetIdentity)
    }

    @MainActor
    private func prepareApplicationTarget(
        app: String,
        operation: String,
        requiresWindow: Bool = false) async throws -> PreparedApplicationTarget
    {
        let authorizedTarget = try self.context.authorizedDesktopTargetPlan(operation: operation)

        do {
            if requiresWindow {
                guard self.context.windows is any WindowManagementPinnedFocusActionResultProviding else {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .runtimeIncompatible,
                        message: "Foreground menu access requires result-aware exact-window focus.",
                        hint: "Update the runtime host before retrying with foreground=true.")
                }
                let planner = DesktopTargetPlanning.MutationAuthorityPlanner(
                    applications: self.context.applications,
                    windows: self.context.windows)
                let authority = try await planner.plan(
                    selector: InteractionTargetSelector(
                        applicationIdentifier: app,
                        windowID: authorizedTarget?.targetIdentity.exactWindow?.identity.windowID),
                    requirement: .exactWindow(
                        automaticSelection: .preferredMutationWindow(.general)),
                    expectedProcessIdentity: authorizedTarget?.processIdentity)
                if let authorizedTarget {
                    _ = try authorizedTarget.coalescing(
                        authority.targetIdentity,
                        operation: operation)
                }
                let plan = authority.application
                return PreparedApplicationTarget(
                    application: plan.application,
                    identity: plan.processIdentity,
                    window: authority.window)
            }

            let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
                applications: self.context.applications)
            let plan = try await planner.plan(
                identifier: app,
                expectedIdentity: authorizedTarget?.processIdentity)
            return PreparedApplicationTarget(
                application: plan.application,
                identity: plan.processIdentity,
                window: nil)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch let error as DesktopTargetPlanningError {
            throw error.desktopActionFailure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The menu application could not be authorized before dispatch.",
                hint: "Refresh the application inventory before retrying.",
                causeDescription: error.localizedDescription)
        }
    }

    private func generationPinnedMenuService() throws -> any MenuServiceGenerationPinnedActionResultProviding {
        guard let service = self.context.menu as? any MenuServiceGenerationPinnedActionResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "The selected menu service cannot preserve the authorized process generation.",
                hint: "Update the runtime host before retrying this menu mutation.")
        }
        return service
    }

    private func clickResponse(
        app: String,
        item: String,
        result: UIAutomationActionResult<Void>,
        focusResult: UIAutomationActionResult<Void>?,
        policy: ClickResponsePolicy) async throws -> ToolResponse
    {
        let menuOutcome: DesktopActionOutcome
        do {
            menuOutcome = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
                result,
                policy: .confirmedOrDispatched(requiring: policy.requiredDeliveryMode),
                targetRequirement: policy.requiresTarget ? .required : .optional,
                operation: "Menu click",
                missingTargetMessage: "Menu click returned without its resolved target identity.",
                rejectedOutcomeMessage: "Menu click did not return a successful outcome.")
        } catch let failure as DesktopActionFailure {
            return try await self.failureResponse(
                failure,
                after: focusResult,
                operation: "menu click",
                additionalFields: MCPDesktopTargetMetadataProjector.fields(result.targetIdentity))
        }
        let aggregate: UIAutomationActionResult<Void>
        do {
            aggregate = try Self.aggregateSuccessfulResults(
                focusResult: focusResult,
                menuResult: UIAutomationActionResult(
                    payload: (),
                    outcome: menuOutcome,
                    targetIdentity: result.targetIdentity))
        } catch {
            return try await self.failureResponse(
                error,
                after: nil,
                operation: "menu click")
        }
        guard let outcome = aggregate.outcome else { preconditionFailure("Validated aggregate lost its outcome") }
        var metadata = try MCPDesktopTargetMetadataProjector.fields(aggregate.targetIdentity)
        if focusResult != nil,
           let invalidated = await MCPDesktopActionSnapshotInvalidator.invalidate(
               uiSnapshots: self.context.uiSnapshots,
               snapshotID: nil,
               outcome: outcome)
        {
            metadata["invalidated_snapshot"] = .string(invalidated)
        }
        let message = if outcome.state == .confirmedNoChange {
            "\(AgentDisplayTokens.Status.success) Menu item already matched the requested state: \(item)"
        } else {
            "\(AgentDisplayTokens.Status.success) Clicked menu item: \(item)"
        }
        let summary = ToolEventSummary(
            targetApp: app,
            actionDescription: "Menu Click",
            notes: item)
        let meta = try MCPToolResponseMetadataProjector.metadata(
            merging: metadata,
            outcome: outcome)
        return ToolResponse.text(
            message,
            meta: ToolEventSummary.merge(summary: summary, into: meta))
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
