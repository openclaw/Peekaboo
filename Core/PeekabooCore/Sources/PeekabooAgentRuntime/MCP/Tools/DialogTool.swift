import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for interacting with system dialogs and alerts.
public struct DialogTool: MCPTool {
    private struct ExecutionTarget {
        let selector: DialogTargetSelector
        let windowTitle: String?
        let appHint: String?
        let preparedReceipt: PreparedDialogActionReceipt?
    }

    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "DialogTool")
    private let context: MCPToolContext

    public let name = "dialog"

    public var description: String {
        """
        Interact with system dialogs and alerts (alerts, sheets, NSSavePanel/NSOpenPanel).

        Actions:
        - list: inspect dialog structure (buttons, text fields, static text)
        - click: press a dialog button
        - input: type into a dialog text field
        - file: drive NSOpenPanel/NSSavePanel dialogs (path/name/select/verify)
        - dismiss: close the active dialog

        Targeting:
        - click and non-forced dismiss require app/pid or an exact window_id target.
        - input and file may use the current dialog only with foreground=true; an explicit target is recommended.
        - list may be targetless; targeted list remains read-only and must resolve exactly one dialog.
        - app and pid are alternatives. Provide at most one window selector; title/index require app or pid.
        - Set foreground=true only for keyboard/file interaction or an explicit global fallback.

        Examples:
        - Click OK: { "action": "click", "button": "OK", "app": "TextEdit" }
        - Default action: { "action": "click", "button": "default", "app": "TextEdit" }
        - Input password: { "action": "input", "text": "hunter2", "field": "Password", "clear": true,
          "app": "Safari", "foreground": true }
        - Save file (OKButton): { "action": "file", "path": "/tmp", "name": "poem.rtf",
          "select": "default", "ensure_expanded": true, "app": "TextEdit", "foreground": true }
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "action": SchemaBuilder.string(
                    description: "Action to perform",
                    enum: DialogToolAction.allCases.map(\.rawValue)),

                // Targeting
                "app": SchemaBuilder.string(description: "Target app name/bundle ID, or 'PID:<n>'."),
                "pid": SchemaBuilder.integer(description: "Target process ID (alternative to app)."),
                "window_id": SchemaBuilder.integer(description: "Window ID (preferred stable selector)."),
                "window_title": SchemaBuilder.string(description: "Window title (substring match)."),
                "window_index": SchemaBuilder.integer(description: "Window index (0-based); requires app/pid."),
                "foreground": SchemaBuilder.boolean(
                    description: "Allow focus/global input. Required for input, file, and forced dismiss.",
                    default: false),

                // click
                "button": SchemaBuilder.string(description: "Button text to click. Use 'default' to click OKButton."),

                // input
                "text": SchemaBuilder.string(description: "Text to input (for input action)."),
                "field": SchemaBuilder.string(description: "Field label/placeholder to target (for input action)."),
                "field_index": SchemaBuilder.integer(
                    description: "Field index (0-based) to target (for input action)."),
                "clear": SchemaBuilder.boolean(description: "Clear existing text first.", default: false),

                // file
                "path": SchemaBuilder.string(description: "Directory (or full path) to navigate to (for file action)."),
                "name": SchemaBuilder.string(description: "Filename to enter (for save dialogs)."),
                "select": SchemaBuilder.string(
                    description: """
                    Button to click after setting path/name. Omit (or pass 'default') to click OKButton.
                    """),
                "ensure_expanded": SchemaBuilder.boolean(
                    description: "Ensure file dialogs are expanded (Show Details) before applying path navigation.",
                    default: false),

                // dismiss
                "force": SchemaBuilder.boolean(description: "Force dismiss (sends Escape).", default: false),
            ],
            required: ["action"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let startTime = Date()

        do {
            let action = try DialogToolAction(arguments: arguments)
            let inputs = try DialogToolInputs(arguments: arguments)

            if action == .list, inputs.foreground {
                throw DialogToolInputError.invalid("foreground", "dialog list is always read-only/background")
            }
            if action == .input || action == .file, !inputs.foreground {
                throw DialogToolInputError.foregroundRequired(action)
            }
            if action == .dismiss, inputs.force == true, !inputs.foreground {
                throw DialogToolInputError.foregroundRequired(action)
            }

            let target = try MCPInteractionTarget(
                app: inputs.app,
                pid: inputs.pid,
                windowTitle: inputs.windowTitle,
                windowIndex: inputs.windowIndex,
                windowId: inputs.windowId)
            let dialogTarget = try inputs.targetSelector()
            let requiresPreparedTarget = action == .click || (action == .dismiss && inputs.force != true)
            if requiresPreparedTarget, !dialogTarget.hasTarget {
                throw DialogToolInputError.missingForAction(action: action, field: "app, pid, or window_id target")
            }

            let preparationRequest: DialogActionPreparationRequest? = switch action {
            case .click:
                try DialogActionPreparationRequest(
                    target: dialogTarget,
                    kind: .clickButton,
                    buttonText: inputs.requireButton())
            case .dismiss where inputs.force != true:
                try DialogActionPreparationRequest(
                    target: dialogTarget,
                    kind: .dismiss)
            case .list, .input, .file, .dismiss:
                nil
            }
            var preparedReceipt: PreparedDialogActionReceipt?
            if !inputs.foreground, let preparationRequest {
                preparedReceipt = try await self.context.dialogs.prepareDialogAction(preparationRequest)
            }

            // Input focus is owned by DialogService after it has retained one exact
            // parent/dialog tuple. Generic window focus cannot safely recognize sheets.
            let hostOwnsForegroundDialogFocus = action == .input ||
                (action == .dismiss && inputs.force == true && dialogTarget.hasTarget)
            if inputs.foreground, inputs.hasAnyTargeting, !hostOwnsForegroundDialogFocus {
                _ = try await target.focusIfRequested(windows: self.context.windows)
            }
            if inputs.foreground, let preparationRequest {
                preparedReceipt = try await self.context.dialogs.prepareDialogAction(preparationRequest)
            }

            let usesLegacyDialogResolution = (action == .input && !dialogTarget.hasTarget) || action == .file ||
                (action == .dismiss && inputs.force == true && !dialogTarget.hasTarget)
            let resolvedWindowTitle: String? = if usesLegacyDialogResolution {
                try await target.resolveWindowTitleIfNeeded(windows: self.context.windows)
            } else {
                nil
            }
            let appHint: String? = if let identifier = target.appIdentifier {
                identifier
            } else {
                nil
            }

            return try await self.perform(
                action: action,
                inputs: inputs,
                target: ExecutionTarget(
                    selector: dialogTarget,
                    windowTitle: resolvedWindowTitle,
                    appHint: appHint,
                    preparedReceipt: preparedReceipt),
                startTime: startTime)
        } catch let error as MCPInteractionTargetError {
            return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: error.localizedDescription,
                reason: error.refusalReason)
        } catch let error as DialogToolInputError {
            return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: error.localizedDescription,
                reason: error.refusalReason)
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil)
        } catch {
            self.logger.error("Dialog execution failed: \(error.localizedDescription)")
            return ToolResponse.error("Dialog failed: \(error.localizedDescription)")
        }
    }

    private func perform(
        action: DialogToolAction,
        inputs: DialogToolInputs,
        target: ExecutionTarget,
        startTime: Date) async throws -> ToolResponse
    {
        let windowTitle = target.windowTitle
        let appHint = target.appHint
        switch action {
        case .list:
            let elements = if target.selector.hasTarget {
                try await self.context.dialogs.listDialogElements(target: target.selector)
            } else {
                try await self.context.dialogs.listDialogElements(windowTitle: nil, appName: nil)
            }
            let executionTime = Date().timeIntervalSince(startTime)
            return self.formatList(
                elements: elements,
                executionTime: executionTime,
                windowTitle: windowTitle,
                appHint: appHint)

        case .click:
            let button = try inputs.requireButton()
            guard let receipt = target.preparedReceipt else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "Dialog click lost its prepared action receipt before execution.",
                    hint: "Prepare the dialog action again before retrying.")
            }
            let result = try await self.context.dialogs.performPreparedDialogAction(receipt)
            let outcome = try result.requiredPreparedOutcome(kind: .clickButton)
            return self.formatActionResult(
                context: ActionResultContext(
                    verb: "Clicked",
                    notes: button,
                    windowTitle: windowTitle,
                    appHint: appHint),
                result: result,
                outcome: outcome,
                startTime: startTime)

        case .input:
            let request = try inputs.requireInputRequest()
            let result: DialogActionResult
            if target.selector.hasTarget {
                let exactRequest = try DialogInputExecutionRequest(
                    target: target.selector,
                    text: request.text,
                    fieldIdentifier: request.fieldIdentifier,
                    clearExisting: request.clearExisting,
                    focus: DialogForegroundFocusPolicy(
                        autoFocus: true,
                        timeout: 5,
                        retryCount: 3,
                        switchSpace: false,
                        bringToCurrentSpace: false))
                result = try await self.context.dialogs.enterText(exactRequest)
            } else {
                result = try await self.context.dialogs.enterText(
                    text: request.text,
                    fieldIdentifier: request.fieldIdentifier,
                    clearExisting: request.clearExisting,
                    windowTitle: nil,
                    appName: nil)
            }
            let outcome = await result.foregroundOutcomeOrUnverified(
                route: self.context.dialogs.foregroundOutcomeRoute)
            let notes = request.fieldIdentifier ?? "field"
            return self.formatActionResult(
                context: ActionResultContext(
                    verb: "Entered text",
                    notes: notes,
                    windowTitle: windowTitle,
                    appHint: appHint),
                result: result,
                outcome: outcome,
                startTime: startTime)

        case .file:
            let request = inputs.fileRequest()
            let actionButton: String?
            if let select = request.select {
                let normalized = select.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                actionButton = normalized == "default" ? nil : select
            } else {
                actionButton = nil
            }

            let result = try await self.context.dialogs.handleFileDialog(
                path: request.path,
                filename: request.name,
                actionButton: actionButton,
                ensureExpanded: request.ensureExpanded,
                appName: appHint)

            let executionTime = Date().timeIntervalSince(startTime)
            let clicked = result.details["button_clicked"] ?? (request.select ?? "default")
            let savedPath = result.details["saved_path"]
            let savedVerified = result.details["saved_path_verified"] == "true" ||
                result.details["saved_path_exists"] == "true"

            var message = "\(AgentDisplayTokens.Status.success) Handled file dialog"
            if let savedPath {
                let verifySuffix = savedVerified ? " (verified)" : ""
                message += ": \(clicked) → \(savedPath)\(verifySuffix)"
            } else {
                message += ": clicked \(clicked)"
            }
            message += " in \(Self.formattedDuration(executionTime))"

            let meta: Value = .object([
                "action": .string(result.action.rawValue),
                "success": .bool(result.success),
                "execution_time": .double(executionTime),
                "details": .object(result.details.mapValues { .string($0) }),
            ])

            let summary = ToolEventSummary(
                targetApp: appHint,
                windowTitle: windowTitle,
                actionDescription: "Dialog File",
                notes: savedPath ?? clicked)

            return ToolResponse(
                content: [.text(text: message, annotations: nil, _meta: nil)],
                meta: ToolEventSummary.merge(summary: summary, into: meta))

        case .dismiss:
            let force = inputs.force ?? false
            let result: DialogActionResult
            let outcome: DesktopActionOutcome
            if force {
                if target.selector.hasTarget {
                    result = try await self.context.dialogs.forceDismissDialog(
                        DialogForcedDismissExecutionRequest(target: target.selector))
                } else {
                    result = try await self.context.dialogs.dismissDialog(
                        force: true,
                        windowTitle: windowTitle,
                        appName: appHint)
                }
                outcome = await result.foregroundOutcomeOrUnverified(
                    route: self.context.dialogs.foregroundOutcomeRoute)
            } else {
                guard let receipt = target.preparedReceipt else {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .runtimeIncompatible,
                        message: "Dialog dismiss lost its prepared action receipt before execution.",
                        hint: "Prepare the dialog action again before retrying.")
                }
                result = try await self.context.dialogs.performPreparedDialogAction(receipt)
                outcome = try result.requiredPreparedOutcome(kind: .dismiss)
            }
            let verb = force ? "Dismissed (forced)" : "Dismissed"
            return self.formatActionResult(
                context: ActionResultContext(
                    verb: verb,
                    notes: nil,
                    windowTitle: windowTitle,
                    appHint: appHint),
                result: result,
                outcome: outcome,
                startTime: startTime)
        }
    }
}
