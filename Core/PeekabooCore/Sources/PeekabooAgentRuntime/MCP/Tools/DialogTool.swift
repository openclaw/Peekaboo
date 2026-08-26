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
        let focusResult: MCPInteractionFocusResult?
    }

    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "DialogTool")
    private let context: MCPToolContext

    public let name = "dialog"

    public var description: String {
        if self.context.executionPolicy == .backgroundOnly {
            return """
            Inspect and interact with system dialogs under immutable background-only authority. Available actions are
            `list`, targeted `click`, targeted `input`, and targeted non-forced `dismiss`. Every mutation requires an
            explicit app, PID, or exact window target. File-dialog keyboard navigation, forced dismissal, targetless
            input, and foreground fallback are unavailable; use a human-authorized foreground-capable session or CLI.

            Examples:
            - Click OK: { "action": "click", "button": "OK", "app": "TextEdit" }
            - Background input: { "action": "input", "text": "hello", "field": "Name", "app": "TextEdit" }
            - Dismiss: { "action": "dismiss", "app": "TextEdit" }
            """
        }

        return """
        Interact with system dialogs and alerts (alerts, sheets, NSSavePanel/NSOpenPanel).

        Actions:
        - list: inspect dialog structure (buttons, text fields, static text)
        - click: press a dialog button
        - input: type into a dialog text field
        - file: drive NSOpenPanel/NSSavePanel dialogs (path/name/select/verify)
        - dismiss: close the active dialog

        Targeting:
        - click and non-forced dismiss require app/pid or an exact window_id target.
        - targeted input defaults to background AXValue delivery; targetless input requires foreground=true.
        - file interaction always requires foreground=true.
        - list may be targetless; targeted list remains read-only and must resolve exactly one dialog.
        - app and pid are alternatives. Provide at most one window selector; title/index require app or pid.
        - Set foreground=true only for explicit keyboard/file interaction or a global fallback.

        Examples:
        - Click OK: { "action": "click", "button": "OK", "app": "TextEdit" }
        - Default action: { "action": "click", "button": "default", "app": "TextEdit" }
        - Background input: { "action": "input", "text": "hello", "field": "Name", "app": "TextEdit" }
        - Save file (OKButton): { "action": "file", "path": "/tmp", "name": "poem.rtf",
          "select": "default", "ensure_expanded": true, "app": "TextEdit", "foreground": true }
        """
    }

    public var inputSchema: Value {
        let foregroundCapable = self.context.executionPolicy != .backgroundOnly
        let actions = foregroundCapable
            ? DialogToolAction.allCases.map(\.rawValue)
            : [DialogToolAction.list, .click, .input, .dismiss].map(\.rawValue)
        var properties: [String: Value] = [
            "action": SchemaBuilder.string(
                description: foregroundCapable
                    ? "Action to perform"
                    : "Background-safe dialog action; file and global input are unavailable",
                enum: actions),
            "app": SchemaBuilder.string(description: "Target app name/bundle ID, or 'PID:<n>'."),
            "pid": SchemaBuilder.integer(description: "Target process ID (alternative to app)."),
            "window_id": SchemaBuilder.integer(description: "Window ID (preferred stable selector)."),
            "window_title": SchemaBuilder.string(description: "Window title (substring match)."),
            "window_index": SchemaBuilder.integer(description: "Window index (0-based); requires app/pid."),
            "button": SchemaBuilder.string(description: "Button text to click. Use 'default' to click OKButton."),
            "text": SchemaBuilder.string(description: "Text to input (for input action)."),
            "field": SchemaBuilder.string(description: "Field label/placeholder to target (for input action)."),
            "field_index": SchemaBuilder.integer(description: "Field index (0-based) to target (for input action)."),
            "clear": SchemaBuilder.boolean(description: "Clear existing text first.", default: false),
        ]
        if foregroundCapable {
            properties["foreground"] = SchemaBuilder.boolean(
                description: "Allow focus/global input. Required for targetless input, file, and forced dismiss.",
                default: false)
            properties["path"] = SchemaBuilder.string(
                description: "Directory (or full path) to navigate to (for file action).")
            properties["name"] = SchemaBuilder.string(description: "Filename to enter (for save dialogs).")
            properties["select"] = SchemaBuilder.string(
                description: "Button to click after setting path/name; default clicks OKButton.")
            properties["ensure_expanded"] = SchemaBuilder.boolean(
                description: "Ensure file dialogs are expanded (Show Details) before applying path navigation.",
                default: false)
            properties["force"] = SchemaBuilder.boolean(description: "Force dismiss (sends Escape).", default: false)
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
        let startTime = Date()
        var setupFocusResult: MCPInteractionFocusResult?

        do {
            let action = try DialogToolAction(arguments: arguments)
            let inputs = try DialogToolInputs(arguments: arguments)

            if action == .list, inputs.foreground {
                throw DialogToolInputError.invalid("foreground", "dialog list is always read-only/background")
            }
            if action == .file, !inputs.foreground {
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
            if action == .input, !dialogTarget.hasTarget, !inputs.foreground {
                throw DialogToolInputError.foregroundRequired(action)
            }
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
                setupFocusResult = try await target.focusResultIfRequested(windows: self.context.windows)
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
                    preparedReceipt: preparedReceipt,
                    focusResult: setupFocusResult),
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
            let failure = setupFocusResult?.preservingFailure(
                failure,
                operation: "Dialog action") ?? failure
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil)
        } catch {
            if let setupFocusResult {
                return try await MCPDesktopActionFailureHandler.response(
                    for: setupFocusResult.preservingFailure(error, operation: "Dialog action"),
                    uiSnapshots: self.context.uiSnapshots,
                    snapshotID: nil)
            }
            self.logger.error("Dialog execution failed: \(error.localizedDescription)")
            return ToolResponse.error("Dialog failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    // swiftlint:disable:next function_body_length
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
            let targetIdentity = try self.validatedDialogListTarget(
                elements,
                selector: target.selector,
                operation: "Dialog list")
            let executionTime = Date().timeIntervalSince(startTime)
            return try self.formatList(
                elements: elements,
                executionTime: executionTime,
                windowTitle: windowTitle,
                appHint: appHint,
                targetIdentity: targetIdentity)

        case .click:
            let button = try inputs.requireButton()
            guard let receipt = target.preparedReceipt else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "Dialog click lost its prepared action receipt before execution.",
                    hint: "Prepare the dialog action again before retrying.")
            }
            try self.validatePreparedReceiptAgainstAuthorization(
                receipt,
                operation: "Dialog click")
            let result = try await self.context.dialogs.performPreparedDialogAction(receipt)
            let leafOutcome = try result.requiredPreparedOutcome(kind: .clickButton)
            let actionResult = try self.combinedResult(
                leafOutcome,
                result: result,
                target: target,
                operation: "Dialog click")
            let outcome = try self.requiredOutcome(actionResult, operation: "Dialog click")
            return try self.formatActionResult(
                context: ActionResultContext(
                    verb: "Clicked",
                    expectedAction: .clickButton,
                    notes: button,
                    windowTitle: windowTitle,
                    appHint: appHint),
                result: result,
                outcome: outcome,
                targetIdentity: actionResult.targetIdentity,
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
                        autoFocus: inputs.foreground,
                        timeout: 5,
                        retryCount: 3,
                        switchSpace: false,
                        bringToCurrentSpace: false))
                result = if inputs.foreground {
                    try await self.context.dialogs.enterTextForegroundCompatible(exactRequest)
                } else {
                    try await self.context.dialogs.enterText(exactRequest)
                }
            } else {
                result = try await self.context.dialogs.enterText(
                    text: request.text,
                    fieldIdentifier: request.fieldIdentifier,
                    clearExisting: request.clearExisting,
                    windowTitle: nil,
                    appName: nil)
            }
            let leafOutcome = try self.dialogInputOutcome(
                result,
                foreground: inputs.foreground,
                targetIsExact: target.selector.hasTarget)
            let actionResult = try self.combinedResult(
                leafOutcome,
                result: result,
                target: target,
                operation: "Dialog input")
            let outcome = try self.requiredOutcome(actionResult, operation: "Dialog input")
            let notes = request.fieldIdentifier ?? "field"
            return try self.formatActionResult(
                context: ActionResultContext(
                    verb: "Entered text",
                    expectedAction: .enterText,
                    notes: notes,
                    windowTitle: windowTitle,
                    appHint: appHint),
                result: result,
                outcome: outcome,
                targetIdentity: actionResult.targetIdentity,
                startTime: startTime)

        case .file:
            return try await self.handleFileAction(
                inputs: inputs,
                target: target,
                startTime: startTime)

        case .dismiss:
            let force = inputs.force ?? false
            let result: DialogActionResult
            let actionResult: UIAutomationActionResult<Void>
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
                let leafOutcome = result.foregroundOutcomeOrUnverified(
                    route: self.context.dialogs.foregroundOutcomeRoute)
                actionResult = try self.combinedResult(
                    leafOutcome,
                    result: result,
                    target: target,
                    operation: "Dialog dismiss")
            } else {
                guard let receipt = target.preparedReceipt else {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .runtimeIncompatible,
                        message: "Dialog dismiss lost its prepared action receipt before execution.",
                        hint: "Prepare the dialog action again before retrying.")
                }
                try self.validatePreparedReceiptAgainstAuthorization(
                    receipt,
                    operation: "Dialog dismiss")
                result = try await self.context.dialogs.performPreparedDialogAction(receipt)
                let leafOutcome = try result.requiredPreparedOutcome(kind: .dismiss)
                actionResult = try self.combinedResult(
                    leafOutcome,
                    result: result,
                    target: target,
                    operation: "Dialog dismiss")
            }
            let outcome = try self.requiredOutcome(actionResult, operation: "Dialog dismiss")
            let verb = force ? "Dismissed (forced)" : "Dismissed"
            return try self.formatActionResult(
                context: ActionResultContext(
                    verb: verb,
                    expectedAction: .dismiss,
                    notes: nil,
                    windowTitle: windowTitle,
                    appHint: appHint),
                result: result,
                outcome: outcome,
                targetIdentity: actionResult.targetIdentity,
                startTime: startTime)
        }
    }

    private func validatePreparedReceiptAgainstAuthorization(
        _ receipt: PreparedDialogActionReceipt,
        operation: String) throws
    {
        _ = try self.context.coalesceAuthorizedDesktopTarget(
            DesktopTargetIdentity(exactWindow: receipt.target),
            operation: operation)
    }

    @MainActor
    private func handleFileAction(
        inputs: DialogToolInputs,
        target: ExecutionTarget,
        startTime: Date) async throws -> ToolResponse
    {
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
            appName: target.appHint)
        let leafOutcome = result.foregroundOutcomeOrUnverified(
            route: self.context.dialogs.foregroundOutcomeRoute)
        let actionResult = try self.combinedResult(
            leafOutcome,
            result: result,
            target: target,
            operation: "Dialog file action")
        let outcome = try self.requiredOutcome(actionResult, operation: "Dialog file action")
        try Self.requireSuccessfulActionResult(
            result,
            outcome: outcome,
            operation: "Dialog file action",
            expectedAction: .handleFileDialog)

        let executionTime = Date().timeIntervalSince(startTime)
        let clicked = result.details["button_clicked"] ?? (request.select ?? "default")
        let savedPath = result.details["saved_path"]
        let savedVerified = result.details["saved_path_verified"] == "true" ||
            result.details["saved_path_exists"] == "true"

        let prefix = outcome.effect == .unverifiable
            ? AgentDisplayTokens.Status.warning
            : AgentDisplayTokens.Status.success
        var message = "\(prefix) Handled file dialog"
        if let savedPath {
            let verifySuffix = savedVerified ? " (verified)" : ""
            message += ": \(clicked) → \(savedPath)\(verifySuffix)"
        } else {
            message += ": clicked \(clicked)"
        }
        message += " in \(Self.formattedDuration(executionTime))"
        if outcome.effect == .unverifiable {
            message += "; effect is unverifiable, observe before retrying"
        }

        var targetFields = try MCPDesktopTargetMetadataProjector.fields(actionResult.targetIdentity)
        if let targetReceipt = result.targetReceipt {
            targetFields["target_receipt"] = try Value(targetReceipt)
        }
        let meta = try MCPToolResponseMetadataProjector.metadata(merging: [
            "action": .string(result.action.rawValue),
            "success": .bool(result.success),
            "execution_time": .double(executionTime),
            "details": .object(result.details.mapValues { .string($0) }),
        ].merging(targetFields) { _, target in target }, outcome: outcome)

        let summary = ToolEventSummary(
            targetApp: target.appHint,
            windowTitle: target.windowTitle,
            actionDescription: "Dialog File",
            notes: savedPath ?? clicked)

        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: ToolEventSummary.merge(summary: summary, into: meta))
    }

    @MainActor
    private func combinedResult(
        _ leafOutcome: DesktopActionOutcome,
        result: DialogActionResult,
        target: ExecutionTarget,
        operation: String) throws -> UIAutomationActionResult<Void>
    {
        let resultTarget = try self.validatedDialogResultTarget(
            result,
            target: target,
            leafOutcome: leafOutcome,
            operation: operation)
        let leafResult = UIAutomationActionResult(
            payload: (),
            outcome: leafOutcome,
            targetIdentity: resultTarget)
        guard let focusResult = target.focusResult else { return leafResult }
        return try focusResult.combining(
            leafResult,
            operation: operation)
    }

    @MainActor
    private func requiredOutcome(
        _ result: UIAutomationActionResult<Void>,
        operation: String) throws -> DesktopActionOutcome
    {
        guard let outcome = result.outcome else {
            throw DesktopActionFailure.indeterminate(
                route: self.context.dialogs.foregroundOutcomeRoute,
                evidence: .completionUnknown,
                message: "\(operation) lost its canonical action outcome.",
                hint: "Observe the exact dialog before retrying and update the execution provider.")
                .attributed(to: result.targetIdentity?.actionTargetReceipt)
        }
        return outcome
    }

    @MainActor
    private func dialogInputOutcome(
        _ result: DialogActionResult,
        foreground: Bool,
        targetIsExact: Bool) throws -> DesktopActionOutcome
    {
        guard targetIsExact, !foreground else {
            return result.foregroundOutcomeOrUnverified(route: self.context.dialogs.foregroundOutcomeRoute)
        }
        guard let outcome = result.outcome?.routed(to: self.context.dialogs.foregroundOutcomeRoute),
              result.success,
              result.action == .enterText,
              outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background),
              outcome.isAccepted(by: .confirmedOrDispatched)
        else {
            throw DesktopActionFailure.indeterminate(
                route: self.context.dialogs.foregroundOutcomeRoute,
                delivery: result.outcome?.delivery,
                evidence: .completionUnknown,
                unitCount: result.outcome?.dispatchState.unitCount,
                message: "Exact background dialog input returned contradictory result semantics.",
                hint: "Observe the exact dialog before retrying and update the execution provider.")
                .attributed(to: result.targetReceipt)
        }
        return outcome
    }

    @MainActor
    private func validatedDialogResultTarget(
        _ result: DialogActionResult,
        target: ExecutionTarget,
        leafOutcome: DesktopActionOutcome,
        operation: String) throws -> DesktopTargetIdentity?
    {
        let hasWindowEvidence = result.targetWindowIdentity != nil ||
            result.targetWindowBounds != nil ||
            result.focusedElement != nil
        let hasResultTargetEvidence = hasWindowEvidence || result.targetReceipt != nil || result.resolvedTarget != nil
        if target.selector.hasTarget, !hasResultTargetEvidence {
            throw self.dialogLeafTargetFailure(
                result: result,
                leafOutcome: leafOutcome,
                operation: operation,
                cause: "The targeted dialog result omitted its exact target evidence.")
        }
        var candidates: [DesktopTargetIdentity?] = [
            target.preparedReceipt.map { DesktopTargetIdentity(exactWindow: $0.target) },
            target.focusResult?.targetIdentity,
        ]
        if let resolved = result.resolvedTarget {
            guard !target.selector.hasTarget || resolved.matches(target.selector) else {
                throw self.dialogLeafTargetFailure(
                    result: result,
                    leafOutcome: leafOutcome,
                    operation: operation,
                    cause: "The resolved dialog target does not match the requested selector.")
            }
            candidates.append(DesktopTargetIdentity(exactWindow: resolved.target))
        }
        if hasWindowEvidence {
            guard let identity = result.targetWindowIdentity,
                  let bounds = result.targetWindowBounds
            else {
                throw self.dialogLeafTargetFailure(
                    result: result,
                    leafOutcome: leafOutcome,
                    operation: operation,
                    cause: "The dialog result carried incomplete window target evidence.")
            }
            do {
                try candidates.append(DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                    identity: identity,
                    bounds: bounds,
                    focusedElement: result.focusedElement)))
            } catch {
                throw self.dialogLeafTargetFailure(
                    result: result,
                    leafOutcome: leafOutcome,
                    operation: operation,
                    cause: error.localizedDescription)
            }
        }

        if let receipt = result.targetReceipt {
            let receiptIdentity: DesktopTargetIdentity
            do {
                receiptIdentity = try DesktopTargetIdentity(processIdentity: .init(
                    processIdentifier: receipt.processIdentifier,
                    processStartIdentity: receipt.processStartIdentity))
            } catch {
                throw self.dialogLeafTargetFailure(
                    result: result,
                    leafOutcome: leafOutcome,
                    operation: operation,
                    cause: error.localizedDescription)
            }
            candidates.append(receiptIdentity)
        }

        guard candidates.contains(where: { $0 != nil }) else {
            guard !target.selector.hasTarget else {
                throw self.dialogLeafTargetFailure(
                    result: result,
                    leafOutcome: leafOutcome,
                    operation: operation,
                    cause: "The targeted dialog result omitted its exact target evidence.")
            }
            return nil
        }
        do {
            guard let resultTarget = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.coalesce(candidates)
            else { return nil }
            let authorizedTarget = try self.context.coalesceAuthorizedDesktopTarget(
                resultTarget,
                operation: operation)
            if target.selector.hasTarget, authorizedTarget.exactWindow == nil {
                guard let receipt = result.targetReceipt,
                      target.selector.applicationIdentifier == nil,
                      target.selector.windowTitle == nil,
                      target.selector.windowIndex == nil,
                      target.selector.processIdentifier == receipt.processIdentifier,
                      target.selector.windowID.map({ $0 == receipt.windowID }) ?? true
                else {
                    throw DesktopTargetIdentityError.incompleteExactWindow
                }
            }
            if let receiptWindowID = result.targetReceipt?.windowID,
               let exactWindowID = authorizedTarget.exactWindow?.identity.windowID,
               receiptWindowID != exactWindowID
            {
                throw DesktopTargetIdentityError.contradictoryWindowIdentifier
            }
            return authorizedTarget
        } catch {
            throw self.dialogLeafTargetFailure(
                result: result,
                leafOutcome: leafOutcome,
                operation: operation,
                cause: error.localizedDescription)
        }
    }

    @MainActor
    private func validatedDialogListTarget(
        _ elements: DialogElements,
        selector: DialogTargetSelector,
        operation: String) throws -> DesktopTargetIdentity?
    {
        guard selector.hasTarget else {
            guard elements.resolvedTarget == nil else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "Targetless dialog list returned unexpected exact-target evidence.",
                    hint: "Retry against a provider that preserves the requested list scope.")
            }
            return nil
        }
        guard let resolved = elements.resolvedTarget, resolved.matches(selector) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Targeted dialog list did not return matching exact-target evidence.",
                hint: "Refresh the dialog target and retry the read.")
        }
        return DesktopTargetIdentity(exactWindow: resolved.target)
    }

    private func dialogLeafTargetFailure(
        result: DialogActionResult,
        leafOutcome: DesktopActionOutcome,
        operation: String,
        cause: String) -> DesktopActionFailure
    {
        let validationFailure = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "\(operation) returned target evidence that did not match its setup focus.",
            hint: "Observe both targets before retrying.",
            causeDescription: cause)
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.reportedOutcome(leafOutcome, defaultDispatchedUnitCount: .one))
        return sequence.failure(
            combining: validationFailure,
            message: validationFailure.message,
            hint: validationFailure.hint,
            causeDescription: validationFailure.causeDescription)
            .attributed(to: result.targetReceipt)
    }
}
