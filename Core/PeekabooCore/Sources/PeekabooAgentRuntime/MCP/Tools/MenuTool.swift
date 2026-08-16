import Foundation
import MCP
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for interacting with application menu bars
public struct MenuTool: MCPTool {
    private struct ClickResponsePolicy {
        let requiredDeliveryMode: DesktopActionOutcome.Delivery.Mode
        let requiresTarget: Bool
    }

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
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6
        and anthropic/claude-opus-5
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

        let focusResult: UIAutomationActionResult<Void>?
        do {
            focusResult = try await self.foregroundFocusResult(
                app: app,
                requested: arguments.getBool("foreground") == true)
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil)
        }

        do {
            let menuStructure = try await self.context.menu.listMenus(for: app)
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

        let focusResult: UIAutomationActionResult<Void>?
        do {
            focusResult = try await self.foregroundFocusResult(
                app: app,
                requested: arguments.getBool("foreground") == true)
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil)
        }

        // Try path first, then item
        if let path = arguments.getString("path") {
            do {
                let result: UIAutomationActionResult<Void>
                if arguments.getBool("foreground") != true {
                    let identity = try await self.backgroundMenuProcessIdentity(app: app)
                    let service = try self.generationPinnedMenuService()
                    let request = try MenuItemActionRequest(
                        appIdentifier: "PID:\(identity.processIdentifier)",
                        itemPath: path,
                        expectedIdentity: identity,
                        deliveryMode: .background)
                    let rawResult = try await service.clickMenuItemActionResult(request: request)
                    result = try service.validatedGenerationPinnedMenuResult(
                        rawResult,
                        expectedIdentity: identity,
                        operation: "Background menu click")
                } else {
                    result = try await self.context.menu.clickMenuItemResult(app: app, itemPath: path)
                }
                return try await self.clickResponse(
                    app: app,
                    item: path,
                    result: result,
                    focusResult: focusResult,
                    policy: .init(
                        requiredDeliveryMode: arguments.getBool("foreground") == true ? .foreground : .background,
                        requiresTarget: self.context.menu is any MenuServiceActionResultProviding))
            } catch let failure as DesktopActionFailure {
                return try await self.failureResponse(
                    failure,
                    after: focusResult,
                    operation: "menu click")
            } catch {
                if focusResult != nil {
                    return try await self.failureResponse(
                        error,
                        after: focusResult,
                        operation: "menu click")
                }
                return ToolResponse
                    .error("Failed to click menu item '\(path)' in app '\(app)': \(error.localizedDescription)")
            }
        } else if let item = arguments.getString("item") {
            do {
                let result: UIAutomationActionResult<Void>
                if arguments.getBool("foreground") != true {
                    let identity = try await self.backgroundMenuProcessIdentity(app: app)
                    let service = try self.generationPinnedMenuService()
                    let request = try MenuItemByNameActionRequest(
                        appIdentifier: "PID:\(identity.processIdentifier)",
                        itemName: item,
                        expectedIdentity: identity,
                        deliveryMode: .background)
                    let rawResult = try await service.clickMenuItemByNameActionResult(request: request)
                    result = try service.validatedGenerationPinnedMenuResult(
                        rawResult,
                        expectedIdentity: identity,
                        operation: "Background named menu click")
                } else {
                    result = try await self.context.menu.clickMenuItemByNameResult(app: app, itemName: item)
                }
                return try await self.clickResponse(
                    app: app,
                    item: item,
                    result: result,
                    focusResult: focusResult,
                    policy: .init(
                        requiredDeliveryMode: arguments.getBool("foreground") == true ? .foreground : .background,
                        requiresTarget: self.context.menu is any MenuServiceActionResultProviding))
            } catch let failure as DesktopActionFailure {
                return try await self.failureResponse(
                    failure,
                    after: focusResult,
                    operation: "menu click")
            } catch {
                if focusResult != nil {
                    return try await self.failureResponse(
                        error,
                        after: focusResult,
                        operation: "menu click")
                }
                return ToolResponse
                    .error("Failed to click menu item '\(item)' in app '\(app)': \(error.localizedDescription)")
            }
        } else {
            return ToolResponse
                .error("Missing required parameter: either 'path' or 'item' must be provided for click action")
        }
    }

    private func foregroundFocusResult(
        app: String,
        requested: Bool) async throws -> UIAutomationActionResult<Void>?
    {
        guard requested else { return nil }
        guard self.context.windows is any WindowManagementPinnedFocusActionResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "Foreground menu access requires result-aware exact-window focus.",
                hint: "Update the runtime host before retrying with foreground=true.")
        }

        let windows: [ServiceWindowInfo]
        do {
            windows = try await self.context.windows.listWindows(target: .application(app))
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The foreground menu window could not be resolved before focus.",
                hint: "Refresh the application window inventory before retrying.",
                causeDescription: error.localizedDescription)
        }
        guard let window = ObservationTargetResolver.captureCandidates(from: windows).first,
              let identity = window.mutationIdentity,
              let bounds = identity.capturedBounds,
              bounds == window.bounds
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Foreground menu access requires one window with a stable exact receipt.",
                hint: "Refresh the application windows before retrying.")
        }

        do {
            let result = try await self.context.windows.focusWindowResult(
                target: .windowId(window.windowID),
                expectedIdentity: identity)
            return try self.context.windows.validatedWindowMutationResult(
                result,
                expectedIdentity: identity,
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
                .attributed(to: DesktopActionTargetReceipt(
                    processIdentifier: identity.ownerProcessIdentifier,
                    processStartIdentity: identity.ownerProcessStartIdentity,
                    windowID: identity.windowID))
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

    private func backgroundMenuProcessIdentity(app: String) async throws -> ApplicationProcessIdentity {
        let application: ServiceApplicationInfo
        do {
            application = try await self.context.applications.findApplication(identifier: app)
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The authorized menu application disappeared before dispatch.",
                hint: "Refresh the application inventory before retrying.",
                causeDescription: error.localizedDescription)
        }
        guard let processIdentity = application.processIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The authorized menu application has no stable process-generation identity.",
                hint: "Refresh the application inventory before retrying.")
        }
        let candidate = try DesktopTargetIdentity(processIdentity: processIdentity)
        return try self.context.coalesceAuthorizedDesktopTarget(
            candidate,
            operation: "Menu click").processIdentity
    }

    private func generationPinnedMenuService() throws -> any MenuServiceGenerationPinnedActionResultProviding {
        guard let service = self.context.menu as? any MenuServiceGenerationPinnedActionResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "The selected menu service cannot preserve the authorized process generation.",
                hint: "Update the runtime host before retrying this background menu mutation.")
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
