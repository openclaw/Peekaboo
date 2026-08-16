import CoreGraphics
import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP
import UniformTypeIdentifiers

/// MCP tool for atomic clipboard+paste+restore.
public struct PasteTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "PasteTool")
    private let context: MCPToolContext

    public let name = "paste"

    public var description: String {
        """
        Paste the current clipboard, or atomically set the clipboard, paste (Cmd+V), then restore it.

        Use this when you want fewer steps than:
        - clipboard set
        - foreground raw press cmd+v --foreground
        - clipboard restore

        Targeting:
        - Provide app/pid for process-targeted background paste.
        - app and pid are alternatives. Provide at most one window selector; title/index require app or pid.
        - Add window_id, window_title, or window_index for atomic exact-window background delivery. Peekaboo pins the
          selected window ID, owner PID, and bounds through dispatch instead of falling back to a sibling window.
        - Set foreground=true only for intentional focus-changing/global paste.

        Payload:
        - Omit payload fields to paste the current clipboard.
        - Or provide text OR filePath/imagePath OR dataBase64+uti (optionally alsoText).

        Result honesty:
        - Targeted text uses direct background text delivery without touching the clipboard. If delivery fails or is
          cancelled after it begins, a prefix may already be present; Peekaboo returns an indeterminate, retry-unsafe
          error and requires a fresh observation.
        - Targeted Cmd+V delivery has no receiver acknowledgement, so binary/current-clipboard calls return an
          explicit may-have-pasted error after restoring and unlocking. Observe the target; do not retry blindly.
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                // Targeting
                "app": SchemaBuilder.string(description: "Target app name/bundle ID, or 'PID:<n>'."),
                "pid": SchemaBuilder.integer(description: "Target process ID (alternative to app)."),
                "window_id": SchemaBuilder.integer(
                    description: "Exact window ID for atomic background delivery, or foreground focus when requested."),
                "window_title": SchemaBuilder
                    .string(description: "Window title substring for atomic exact-window background delivery."),
                "window_index": SchemaBuilder
                    .integer(description: "Window index (0-based); requires app/pid and pins that exact window."),

                // Payload
                "text": SchemaBuilder.string(
                    description: "Plain text. Background delivery leaves the clipboard untouched; a failure after " +
                        "dispatch begins is retry-unsafe because a prefix may already be present."),
                "filePath": SchemaBuilder
                    .string(description: "Path to a file to paste (file bytes placed on clipboard)."),
                "imagePath": SchemaBuilder.string(description: "Path to an image to paste (alias of filePath)."),
                "dataBase64": SchemaBuilder.string(description: "Base64-encoded payload to paste."),
                "uti": SchemaBuilder.string(description: "UTI for dataBase64, or to force type when pasting a file."),
                "alsoText": SchemaBuilder.string(description: "Optional plain-text companion when pasting binary."),
                "allowLarge": SchemaBuilder.boolean(description: "Allow payloads larger than 10 MB.", default: false),

                // Restore timing
                "restore_delay_ms": SchemaBuilder.integer(
                    description: "Delay before restoring the previous clipboard (ms). Default: 150.",
                    minimum: 0,
                    default: 150),
                "foreground": SchemaBuilder.boolean(
                    description: "Optional. Focus a target or intentionally send foreground/global Cmd+V.",
                    default: false),
            ],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    func validateArgumentSemantics(_ arguments: ToolArguments) throws {
        _ = try MCPInteractionTarget(
            app: arguments.getString("app"),
            pid: arguments.validatedInt("pid"),
            windowTitle: arguments.getString("window_title"),
            windowIndex: arguments.validatedInt("window_index"),
            windowId: arguments.validatedInt("window_id"))
        try Self.validatePayloadShape(arguments)
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let startTime = Date()
        var setupFocusResult: MCPInteractionFocusResult?

        do {
            let target = try MCPInteractionTarget(
                app: arguments.getString("app"),
                pid: arguments.validatedInt("pid"),
                windowTitle: arguments.getString("window_title"),
                windowIndex: arguments.validatedInt("window_index"),
                windowId: arguments.validatedInt("window_id"))

            let foreground = arguments.getBool("foreground") ?? false
            let expectedPIDIdentity = try self.explicitPIDIdentity(target: target)
            let payload = try self.makePayload(arguments: arguments)
            let restoreDelayMs = try max(0, arguments.validatedInt("restore_delay_ms") ?? 150)

            if case let .explicit(request, text?) = payload, !foreground {
                let destination = try await self.resolveDeliveryDestination(
                    target: target,
                    foreground: false,
                    expectedPIDIdentity: expectedPIDIdentity)
                guard destination.processIdentifier != nil else {
                    throw PasteToolError(
                        "Background text paste requires an app or pid target.",
                        refusalReason: .invalidRequest)
                }
                return try await self.performBackgroundTextPaste(
                    text: text,
                    request: request,
                    target: target,
                    destination: destination,
                    startedAt: startTime)
            }

            if case .current = payload {
                let outcome = try await ClipboardPasteTransactionGate.withExclusiveTransaction {
                    let destination = try await self.resolveDeliveryDestination(
                        target: target,
                        foreground: foreground,
                        expectedPIDIdentity: expectedPIDIdentity)
                    if destination.processIdentifier == nil {
                        setupFocusResult = try await target.focusResultIfRequested(windows: self.context.windows)
                    }
                    return try await self.performCurrentClipboardPaste(
                        destination: destination,
                        restoreDelayMs: restoreDelayMs)
                }
                let actionResult: UIAutomationActionResult<Void>
                do {
                    actionResult = try self.combinedPasteActionResult(
                        outcome.actionResult,
                        focusResult: setupFocusResult)
                } catch {
                    // `combining` already preserves the completed focus in its failure.
                    setupFocusResult = nil
                    throw error
                }
                return try await self.currentClipboardResponse(
                    outcome: outcome,
                    actionResult: actionResult,
                    target: target,
                    restoreDelayMs: restoreDelayMs,
                    startedAt: startTime)
            }

            guard case let .explicit(request, _) = payload else {
                throw PasteToolError("Invalid paste payload.", refusalReason: .invalidRequest)
            }
            let outcome = try await ClipboardPasteTransactionGate.withExclusiveTransaction {
                let destination = try await self.resolveDeliveryDestination(
                    target: target,
                    foreground: foreground,
                    expectedPIDIdentity: expectedPIDIdentity)
                if destination.processIdentifier == nil {
                    setupFocusResult = try await target.focusResultIfRequested(windows: self.context.windows)
                }
                return try await self.performClipboardPasteTransaction(
                    request: request,
                    destination: destination,
                    restoreDelayMs: restoreDelayMs)
            }
            let actionResult: UIAutomationActionResult<Void>
            do {
                actionResult = try self.combinedPasteActionResult(
                    outcome.actionResult,
                    focusResult: setupFocusResult)
            } catch {
                // `combining` already preserves the completed focus in its failure.
                setupFocusResult = nil
                throw error
            }

            let executionTime = Date().timeIntervalSince(startTime)
            let message = if outcome.restoreErrorDescription != nil {
                "\(AgentDisplayTokens.Status.warning) Pasted (Cmd+V), but clipboard restoration failed " +
                    "in \(String(format: "%.2f", executionTime))s. Do not retry the paste; " +
                    "the previous clipboard contents may be unavailable."
            } else {
                "\(AgentDisplayTokens.Status.success) Pasted (Cmd+V) and restored clipboard " +
                    "in \(String(format: "%.2f", executionTime))s"
            }

            let pastedObject: [String: Value] = [
                "uti": .string(outcome.setResult.utiIdentifier),
                "size": .int(outcome.setResult.data.count),
                "textPreview": outcome.setResult.textPreview.map(Value.string) ?? .null,
            ]

            let restoredUti: Value = outcome.restoreResult.map { .string($0.utiIdentifier) } ?? .null
            let restoredSize: Value = outcome.restoreResult.map { .int($0.data.count) } ?? .null
            let restoredObject: [String: Value] = [
                "uti": restoredUti,
                "size": restoredSize,
            ]

            var metaFields: [String: Value] = [
                "pasted": .object(pastedObject),
                "previous_clipboard_present": .bool(outcome.previousClipboardPresent),
                "restored": .object(restoredObject),
                "restore_succeeded": .bool(outcome.restoreErrorDescription == nil),
                "restore_error": outcome.restoreErrorDescription.map(Value.string) ?? .null,
                "restore_delay_ms": .int(restoreDelayMs),
                "execution_time": .double(executionTime),
                "delivery_mode": .string(outcome.targetPID == nil ? "foreground" : "background"),
                "target_pid": outcome.targetPID.map { .int(Int($0)) } ?? .null,
                "target_window_id": outcome.targetWindowID.map(Value.int) ?? .null,
            ]
            try metaFields.merge(Self.targetMetadataFields(actionResult.targetIdentity)) { _, target in target }
            let meta = try MCPToolResponseMetadataProjector.metadata(
                merging: metaFields,
                outcome: actionResult.outcome)

            let resolvedWindowTitle = try? await target.resolveWindowTitleIfNeeded(windows: self.context.windows)
            if Task.isCancelled {
                throw ClipboardPasteOutcomeError(
                    kind: .indeterminate,
                    causeDescription: "The caller cancelled after Cmd+V dispatch completed.",
                    clipboardRestoreAttempted: true,
                    clipboardRestoreErrorDescription: outcome.restoreErrorDescription,
                    targetProcessIdentifier: outcome.targetPID)
            }
            let summary = ToolEventSummary(
                targetApp: target.appIdentifier,
                windowTitle: resolvedWindowTitle,
                actionDescription: "Paste",
                notes: outcome.setResult.utiIdentifier)

            return ToolResponse(
                content: [.text(text: message, annotations: nil, _meta: nil)],
                meta: ToolEventSummary.merge(summary: summary, into: meta))
        } catch let error as MCPInteractionTargetError {
            return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: error.localizedDescription,
                reason: error.refusalReason)
        } catch let failure as DesktopActionFailure {
            return try await self.failureResponse(failure, focusResult: setupFocusResult)
        } catch let error as ClipboardPasteOutcomeError {
            return try await self.pasteOutcomeResponse(error, focusResult: setupFocusResult)
        } catch let error as PasteToolError {
            return try await self.pasteToolErrorResponse(error, focusResult: setupFocusResult)
        } catch {
            return try await self.unexpectedErrorResponse(error, focusResult: setupFocusResult)
        }
    }

    @MainActor
    private func failureResponse(
        _ failure: DesktopActionFailure,
        focusResult: MCPInteractionFocusResult?) async throws -> ToolResponse
    {
        let failure = focusResult?.preservingFailure(failure, operation: "Paste") ?? failure
        return try await MCPDesktopActionFailureHandler.response(
            for: failure,
            uiSnapshots: self.context.uiSnapshots,
            snapshotID: nil)
    }

    @MainActor
    private func pasteOutcomeResponse(
        _ error: ClipboardPasteOutcomeError,
        focusResult: MCPInteractionFocusResult?) async throws -> ToolResponse
    {
        if let focusResult {
            let leaf = DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .clipboardTransaction, mode: .foreground),
                evidence: .completionUnknown,
                message: error.localizedDescription,
                hint: "Observe the focused target and clipboard before retrying.",
                causeDescription: error.causeDescription)
            return try await self.failureResponse(
                focusResult.preservingFailure(leaf, operation: "Paste"),
                focusResult: nil)
        }
        self.logger.error("Paste outcome was \(error.kind.rawValue, privacy: .public)")
        return ToolResponse.error(
            error.localizedDescription,
            meta: .object([
                "paste_outcome": .string(error.kind.rawValue),
                "may_have_pasted": .bool(true),
                "retry_safe": .bool(false),
                "clipboard_restore_attempted": .bool(error.clipboardRestoreAttempted),
                "clipboard_restore_succeeded": error.clipboardRestoreAttempted
                    ? .bool(error.clipboardRestoreErrorDescription == nil)
                    : .null,
                "clipboard_restore_error": error.clipboardRestoreErrorDescription.map(Value.string) ?? .null,
                "target_pid": error.targetProcessIdentifier.map { .int(Int($0)) } ?? .null,
                "requires_fresh_observation": .bool(true),
            ]))
    }

    @MainActor
    private func pasteToolErrorResponse(
        _ error: PasteToolError,
        focusResult: MCPInteractionFocusResult?) async throws -> ToolResponse
    {
        guard let focusResult else {
            return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: error.message,
                reason: error.refusalReason)
        }
        let failure = DesktopActionFailure.preDispatchRefusal(
            reason: error.refusalReason,
            message: error.message)
        return try await self.failureResponse(
            focusResult.preservingFailure(failure, operation: "Paste"),
            focusResult: nil)
    }

    @MainActor
    private func unexpectedErrorResponse(
        _ error: any Error,
        focusResult: MCPInteractionFocusResult?) async throws -> ToolResponse
    {
        if let focusResult {
            return try await self.failureResponse(
                focusResult.preservingFailure(error, operation: "Paste"),
                focusResult: nil)
        }
        self.logger.error("Paste failed: \(error.localizedDescription)")
        return ToolResponse.error("Paste failed: \(error.localizedDescription)")
    }

    @MainActor
    private func directTextOutcomeResponse(
        _ error: InputDeliveryIndeterminateError,
        requestedCharacterCount: Int,
        destination: UIAutomationTarget) async throws -> ToolResponse
    {
        self.logger.error("Direct text paste outcome was indeterminate")
        let identity = try Self.desktopTargetIdentity(destination)
        let failure = Self.attributing(
            error.desktopActionFailure(delivery: Self.backgroundDelivery(for: destination)),
            to: identity)
        return try await MCPDesktopActionFailureHandler.response(
            for: failure,
            uiSnapshots: self.context.uiSnapshots,
            snapshotID: nil,
            additionalFields: [
                "paste_outcome": .string("indeterminate"),
                "paste_method": .string("background_text"),
                "delivery_mode": .string("background"),
                "may_have_pasted": .bool(true),
                "partial_text_possible": .bool(true),
                "retry_safe": .bool(false),
                "clipboard_mutated": .bool(false),
                "clipboard_restore_attempted": .bool(false),
                "clipboard_restore_succeeded": .null,
                "clipboard_restore_error": .null,
                "requested_characters": .int(requestedCharacterCount),
                "characters_typed": error.emittedUnitCount.map(Value.int) ?? .null,
                "target_pid": destination.processIdentifier.map { .int(Int($0)) } ?? .null,
                "target_window_id": destination.exactWindow.map { .int($0.identity.windowID) } ?? .null,
            ])
    }

    @MainActor
    private func pasteHotkeyRoute(for destination: UIAutomationTarget) throws -> PasteHotkeyRoute {
        if destination.exactWindow != nil {
            do {
                return try .exact(ExactWindowKeyboardRuntime.requireOutcomeProvider(
                    automation: self.context.automation,
                    operation: "Exact-window paste"))
            } catch {
                throw PasteToolError(
                    error.localizedDescription,
                    refusalReason: .runtimeIncompatible)
            }
        }
        if destination.processIdentifier != nil {
            guard let automation = self.context.automation as? any TargetedHotkeyServiceProtocol,
                  automation.supportsTargetedHotkeys,
                  automation.supportsProcessGenerationPinnedHotkeys
            else {
                throw PasteToolError(
                    "This automation host does not support background paste delivery.",
                    refusalReason: .runtimeIncompatible)
            }
            return .process(automation)
        }
        return .foreground
    }

    @MainActor
    private func dispatchPasteHotkey(
        route: PasteHotkeyRoute,
        destination: UIAutomationTarget) async throws -> UIAutomationActionResult<Void>
    {
        switch route {
        case let .exact(automation):
            guard let exactWindow = destination.exactWindow,
                  let focusedElement = exactWindow.focusedElement
            else {
                throw PasteToolError("Exact-window paste requires a focused-element receipt.")
            }
            let result = try await automation.hotkeyWithOutcome(
                keys: "cmd,v",
                holdDuration: 50,
                target: ExactWindowKeyboardTarget(
                    windowIdentity: exactWindow.identity,
                    windowBounds: exactWindow.bounds,
                    focusedElement: focusedElement))
            let validated = try ExactWindowKeyboardRuntime.validateRouteReceipt(
                result,
                operation: "Exact-window paste")
            try DesktopActionFailure.requireConfirmedIfReported(
                validated.outcome,
                operation: "Paste hotkey")
            return validated
        case let .process(automation):
            guard let processIdentity = destination.processIdentity else {
                throw PasteToolError("Background paste requires a process-generation receipt.")
            }
            if let outcomeAutomation = automation as? any UIAutomationActionOutcomeProviding {
                let result = try await outcomeAutomation.hotkeyWithOutcome(
                    keys: "cmd,v",
                    holdDuration: 50,
                    expectedProcessIdentity: processIdentity)
                try DesktopActionFailure.requireConfirmedIfReported(
                    result.outcome,
                    operation: "Paste hotkey")
                return result
            }
            try await automation.hotkey(keys: "cmd,v", holdDuration: 50, expectedProcessIdentity: processIdentity)
            return UIAutomationActionResult(payload: (), outcome: nil)
        case .foreground:
            if let outcomeAutomation = self.context.automation as? any UIAutomationActionOutcomeProviding {
                let result = try await outcomeAutomation.hotkeyWithOutcome(keys: "cmd,v", holdDuration: 50)
                try DesktopActionFailure.requireConfirmedIfReported(
                    result.outcome,
                    operation: "Paste hotkey")
                return result
            }
            try await self.context.automation.hotkey(keys: "cmd,v", holdDuration: 50)
            return UIAutomationActionResult(payload: (), outcome: nil)
        }
    }

    @MainActor
    private func performClipboardPasteTransaction(
        request: ClipboardWriteRequest,
        destination: UIAutomationTarget,
        restoreDelayMs: Int) async throws -> ClipboardPasteTransactionOutcome
    {
        let hotkeyRoute = try self.pasteHotkeyRoute(for: destination)

        try Task.checkCancellation()
        let priorClipboard = try self.context.clipboard.get(prefer: nil)
        let restoreSlot = "paste-\(UUID().uuidString)"
        try Task.checkCancellation()
        if priorClipboard != nil {
            try self.context.clipboard.save(slot: restoreSlot)
        }
        try Task.checkCancellation()

        func restoreClipboard() throws -> ClipboardReadResult? {
            guard priorClipboard != nil else {
                self.context.clipboard.clear()
                return nil
            }
            return try self.context.clipboard.restore(slot: restoreSlot)
        }

        func restoreAfterConsumption() async throws -> ClipboardReadResult? {
            await ClipboardPasteTransactionGate.waitForPasteConsumption(milliseconds: restoreDelayMs)
            return try restoreClipboard()
        }

        var restorePending = false
        func restoreBeforeDispatchFailure(_ primaryError: any Error) throws -> Never {
            do {
                _ = try restoreClipboard()
                restorePending = false
            } catch {
                restorePending = false
                throw ClipboardServiceError.writeFailed(
                    "Paste payload setup failed (\(primaryError.localizedDescription)); " +
                        "restoring the prior clipboard also failed: \(error.localizedDescription). " +
                        "The clipboard may have changed; do not retry until its state is inspected.")
            }
            throw primaryError
        }
        defer {
            if restorePending {
                do {
                    _ = try restoreClipboard()
                } catch {
                    self.logger.error(
                        "Failed to restore clipboard after paste error: \(error.localizedDescription)")
                }
            }
        }

        restorePending = true
        let setResult: ClipboardReadResult
        do {
            setResult = try self.context.clipboard.set(request)
            try Task.checkCancellation()
        } catch {
            try restoreBeforeDispatchFailure(error)
        }

        let dispatchFailure: DesktopActionFailure?
        let dispatchErrorDescription: String?
        let actionResult: UIAutomationActionResult<Void>?
        do {
            actionResult = try await self.dispatchPasteHotkey(route: hotkeyRoute, destination: destination)
            dispatchFailure = nil
            dispatchErrorDescription = nil
        } catch let failure as DesktopActionFailure {
            actionResult = nil
            dispatchFailure = failure
            dispatchErrorDescription = nil
        } catch {
            actionResult = nil
            dispatchFailure = nil
            dispatchErrorDescription = error.localizedDescription
        }

        let restoreResult: ClipboardReadResult?
        let restoreErrorDescription: String?
        do {
            restoreResult = try await restoreAfterConsumption()
            restoreErrorDescription = nil
        } catch {
            restoreResult = nil
            restoreErrorDescription = error.localizedDescription
            self.logger.error("Failed to restore clipboard: \(error.localizedDescription)")
        }
        restorePending = false

        if let dispatchFailure {
            guard let restoreErrorDescription else { throw dispatchFailure }
            throw ClipboardPasteOutcomeError(
                kind: .indeterminate,
                causeDescription: "\(dispatchFailure.localizedDescription); clipboard restoration also failed: " +
                    restoreErrorDescription,
                clipboardRestoreAttempted: true,
                clipboardRestoreErrorDescription: restoreErrorDescription,
                targetProcessIdentifier: destination.processIdentifier)
        }
        if dispatchErrorDescription != nil || Task.isCancelled {
            throw ClipboardPasteOutcomeError(
                kind: .indeterminate,
                causeDescription: dispatchErrorDescription ?? "The caller cancelled after Cmd+V dispatch began.",
                clipboardRestoreAttempted: true,
                clipboardRestoreErrorDescription: restoreErrorDescription,
                targetProcessIdentifier: destination.processIdentifier)
        }
        if destination.processIdentifier != nil {
            throw ClipboardPasteOutcomeError(
                kind: .unverified,
                causeDescription: "The targeted event API does not acknowledge receiver consumption.",
                clipboardRestoreAttempted: true,
                clipboardRestoreErrorDescription: restoreErrorDescription,
                targetProcessIdentifier: destination.processIdentifier)
        }
        guard let actionResult else {
            preconditionFailure("A successful paste dispatch must retain its action result")
        }

        return ClipboardPasteTransactionOutcome(
            setResult: setResult,
            previousClipboardPresent: priorClipboard != nil,
            restoreResult: restoreResult,
            restoreErrorDescription: restoreErrorDescription,
            targetPID: destination.processIdentifier,
            targetWindowID: destination.exactWindow?.identity.windowID,
            actionResult: actionResult)
    }

    @MainActor
    private func performCurrentClipboardPaste(
        destination: UIAutomationTarget,
        restoreDelayMs: Int) async throws -> CurrentClipboardPasteOutcome
    {
        let hotkeyRoute = try self.pasteHotkeyRoute(for: destination)

        let currentClipboard = try self.context.clipboard.get(prefer: nil)
        try Task.checkCancellation()
        let dispatchFailure: DesktopActionFailure?
        let dispatchErrorDescription: String?
        let actionResult: UIAutomationActionResult<Void>?
        do {
            actionResult = try await self.dispatchPasteHotkey(route: hotkeyRoute, destination: destination)
            dispatchFailure = nil
            dispatchErrorDescription = nil
        } catch let failure as DesktopActionFailure {
            actionResult = nil
            dispatchFailure = failure
            dispatchErrorDescription = nil
        } catch {
            actionResult = nil
            dispatchFailure = nil
            dispatchErrorDescription = error.localizedDescription
        }

        await ClipboardPasteTransactionGate.waitForPasteConsumption(milliseconds: restoreDelayMs)
        if let dispatchFailure {
            throw dispatchFailure
        }
        if dispatchErrorDescription != nil || Task.isCancelled {
            throw ClipboardPasteOutcomeError(
                kind: .indeterminate,
                causeDescription: dispatchErrorDescription ?? "The caller cancelled after Cmd+V dispatch began.",
                clipboardRestoreAttempted: false,
                targetProcessIdentifier: destination.processIdentifier)
        }
        if destination.processIdentifier != nil {
            throw ClipboardPasteOutcomeError(
                kind: .unverified,
                causeDescription: "The targeted event API does not acknowledge receiver consumption.",
                clipboardRestoreAttempted: false,
                targetProcessIdentifier: destination.processIdentifier)
        }
        guard let actionResult else {
            preconditionFailure("A successful paste dispatch must retain its action result")
        }
        return CurrentClipboardPasteOutcome(
            clipboard: currentClipboard,
            targetPID: destination.processIdentifier,
            targetWindowID: destination.exactWindow?.identity.windowID,
            actionResult: actionResult)
    }

    @MainActor
    private func performBackgroundTextPaste(
        text: String,
        request: ClipboardWriteRequest,
        target: MCPInteractionTarget,
        destination: UIAutomationTarget,
        startedAt: Date) async throws -> ToolResponse
    {
        guard let targetPID = destination.processIdentifier else {
            throw PasteToolError("Background text paste requires a resolved target process.")
        }
        let actionResult: UIAutomationActionResult<TypeResult>
        if let exactWindow = destination.exactWindow {
            let outcomeAutomation = try ExactWindowKeyboardRuntime.requireOutcomeProvider(
                automation: self.context.automation,
                operation: "Exact-window background text delivery")
            guard let focusedElement = exactWindow.focusedElement else {
                throw PasteToolError("Exact-window paste requires a focused-element receipt.")
            }
            try Task.checkCancellation()
            do {
                actionResult = try await ExactWindowKeyboardRuntime.validateRouteReceipt(
                    outcomeAutomation.typeActionsWithOutcome(
                        [.text(text)],
                        cadence: .fixed(milliseconds: 0),
                        snapshotId: nil,
                        target: ExactWindowKeyboardTarget(
                            windowIdentity: exactWindow.identity,
                            windowBounds: exactWindow.bounds,
                            focusedElement: focusedElement)),
                    operation: "Exact-window background text delivery")
            } catch let error as InputDeliveryIndeterminateError {
                return try await self.directTextOutcomeResponse(
                    Self.pasteDeliveryError(from: error),
                    requestedCharacterCount: text.count,
                    destination: destination)
            }
        } else {
            guard let automation = self.context.automation as? any TargetedTypeServiceProtocol,
                  automation.supportsTargetedTypeActions,
                  automation.supportsProcessGenerationPinnedTypeActions,
                  let processIdentity = destination.processIdentity
            else {
                throw PasteToolError(
                    "This automation host does not support background text delivery.",
                    refusalReason: .runtimeIncompatible)
            }
            try Task.checkCancellation()
            do {
                if let outcomeAutomation = automation as? any UIAutomationActionOutcomeProviding {
                    actionResult = try await outcomeAutomation.typeActionsWithOutcome(
                        [.text(text)],
                        cadence: .fixed(milliseconds: 0),
                        snapshotId: nil,
                        expectedProcessIdentity: processIdentity)
                } else {
                    actionResult = try await UIAutomationActionResult(
                        payload: automation.typeActions(
                            [.text(text)],
                            cadence: .fixed(milliseconds: 0),
                            snapshotId: nil,
                            expectedProcessIdentity: processIdentity),
                        outcome: nil)
                }
            } catch let error as InputDeliveryIndeterminateError {
                return try await self.directTextOutcomeResponse(
                    Self.pasteDeliveryError(from: error),
                    requestedCharacterCount: text.count,
                    destination: destination)
            }
        }
        let validatedActionResult = try self.validatedBackgroundTextResult(
            actionResult,
            destination: destination)
        let typeResult = validatedActionResult.payload
        if Task.isCancelled {
            return try await self.directTextOutcomeResponse(
                InputDeliveryIndeterminateError(
                    operation: .paste,
                    emittedUnitCount: typeResult.totalCharacters,
                    causeDescription: "The caller cancelled after direct text dispatch completed."),
                requestedCharacterCount: text.count,
                destination: destination)
        }
        let setResult = try Self.readResult(for: request)
        let executionTime = Date().timeIntervalSince(startedAt)
        let resultIdentity = validatedActionResult.targetIdentity
        let resultTarget = resultIdentity?.target ?? destination
        var metaFields: [String: Value] = [
            "pasted": .object([
                "uti": .string(setResult.utiIdentifier),
                "size": .int(setResult.data.count),
                "textPreview": setResult.textPreview.map(Value.string) ?? .null,
            ]),
            "paste_method": .string("background_text"),
            "characters_typed": .int(typeResult.totalCharacters),
            "execution_time": .double(executionTime),
            "delivery_mode": .string("background"),
            "target_pid": resultTarget.processIdentifier.map { .int(Int($0)) } ?? .int(Int(targetPID)),
            "target_window_id": resultTarget.exactWindow.map { .int($0.identity.windowID) } ?? .null,
        ]
        try metaFields.merge(Self.targetMetadataFields(resultIdentity)) { _, target in target }
        let summary = ToolEventSummary(
            targetApp: target.appIdentifier,
            windowTitle: nil,
            actionDescription: "Paste text",
            notes: setResult.utiIdentifier)
        return try ToolResponse(
            content: [.text(
                text: "\(AgentDisplayTokens.Status.success) Pasted text in the background " +
                    "in \(String(format: "%.2f", executionTime))s",
                annotations: nil,
                _meta: nil)],
            meta: ToolEventSummary.merge(
                summary: summary,
                into: MCPToolResponseMetadataProjector.metadata(
                    merging: metaFields,
                    outcome: validatedActionResult.outcome)))
    }

    private static func pasteDeliveryError(
        from error: InputDeliveryIndeterminateError) -> InputDeliveryIndeterminateError
    {
        InputDeliveryIndeterminateError(
            operation: .paste,
            emittedUnitCount: error.emittedUnitCount,
            causeDescription: error.causeDescription ?? error.localizedDescription)
    }

    private func validatedBackgroundTextResult(
        _ result: UIAutomationActionResult<TypeResult>,
        destination: UIAutomationTarget) throws -> UIAutomationActionResult<TypeResult>
    {
        guard let authorizedPlan = AuthorizedDesktopTargetPlan.current else {
            try DesktopActionFailure.requireConfirmedIfReported(
                result.outcome,
                operation: "Background text paste")
            return result
        }

        let destinationIdentity = try Self.desktopTargetIdentity(destination)
        let authorizedIdentity: DesktopTargetIdentity
        do {
            authorizedIdentity = try authorizedPlan.coalescing(
                destinationIdentity,
                operation: "Background text paste")
        } catch let failure as DesktopActionFailure {
            throw Self.attributing(failure, to: authorizedPlan.targetIdentity)
        }

        guard let returnedIdentity = result.targetIdentity else {
            throw Self.attributing(
                .indeterminate(
                    route: result.outcome?.route ?? .local,
                    delivery: result.outcome?.delivery ?? Self.backgroundDelivery(for: destination),
                    evidence: .completionUnknown,
                    unitCount: result.outcome?.dispatchState.unitCount ?? .one,
                    message: "Background text paste returned without its exact target identity.",
                    hint: "Observe the exact target before retrying and update the runtime host."),
                to: authorizedIdentity)
        }
        let resultIdentity: DesktopTargetIdentity
        do {
            resultIdentity = try authorizedIdentity.coalescing(returnedIdentity)
        } catch {
            // A contradictory provider target is not safely attributable to either claimed identity.
            throw DesktopActionFailure.indeterminate(
                route: result.outcome?.route ?? .local,
                delivery: result.outcome?.delivery ?? Self.backgroundDelivery(for: destination),
                evidence: .completionUnknown,
                unitCount: result.outcome?.dispatchState.unitCount ?? .one,
                message: "Background text paste returned a target different from its authorization.",
                hint: "Observe both targets before retrying and update the runtime host.",
                causeDescription: error.localizedDescription)
        }
        guard let outcome = result.outcome else {
            throw Self.attributing(
                .indeterminate(
                    delivery: Self.backgroundDelivery(for: destination),
                    evidence: .completionUnknown,
                    unitCount: .one,
                    message: "Background text paste returned without a canonical outcome.",
                    hint: "Observe the exact target before retrying and update the runtime host."),
                to: resultIdentity)
        }
        do {
            try DesktopActionFailure.requireConfirmedIfReported(
                outcome,
                operation: "Background text paste")
        } catch let failure as DesktopActionFailure {
            throw Self.attributing(failure, to: resultIdentity)
        }
        if let delivery = outcome.delivery, delivery.mode != .background {
            throw Self.attributing(
                .indeterminate(
                    route: outcome.route,
                    delivery: delivery,
                    evidence: .completionUnknown,
                    unitCount: outcome.dispatchState.unitCount,
                    message: "Background text paste reported foreground delivery.",
                    hint: "Observe the exact target before retrying and update the runtime host."),
                to: resultIdentity)
        }
        return UIAutomationActionResult(
            payload: result.payload,
            outcome: outcome,
            targetIdentity: resultIdentity)
    }

    private static func desktopTargetIdentity(_ target: UIAutomationTarget) throws -> DesktopTargetIdentity {
        if let exactWindow = target.exactWindow {
            return DesktopTargetIdentity(exactWindow: exactWindow)
        }
        guard let processIdentity = target.processIdentity else {
            throw PasteToolError(
                "Background text paste requires a process-generation target.",
                refusalReason: .targetUnavailable)
        }
        return try DesktopTargetIdentity(processIdentity: processIdentity)
    }

    private static func backgroundDelivery(for target: UIAutomationTarget) -> DesktopActionOutcome.Delivery {
        .init(
            mechanism: target.exactWindow == nil ? .processTargetedEvents : .windowTargetedEvents,
            mode: .background)
    }

    private static func attributing(
        _ failure: DesktopActionFailure,
        to identity: DesktopTargetIdentity) -> DesktopActionFailure
    {
        if let exactWindow = identity.exactWindow {
            return failure.attributed(to: DesktopActionTargetReceipt(
                processIdentifier: exactWindow.identity.ownerProcessIdentifier,
                processStartIdentity: exactWindow.identity.ownerProcessStartIdentity,
                windowID: exactWindow.identity.windowID))
        }
        return failure.attributed(to: DesktopActionTargetReceipt(
            processIdentifier: identity.processIdentity.processIdentifier,
            processStartIdentity: identity.processIdentity.processStartIdentity))
    }

    @MainActor
    private func currentClipboardResponse(
        outcome: CurrentClipboardPasteOutcome,
        actionResult: UIAutomationActionResult<Void>,
        target: MCPInteractionTarget,
        restoreDelayMs: Int,
        startedAt: Date) async throws -> ToolResponse
    {
        let executionTime = Date().timeIntervalSince(startedAt)
        var metaFields: [String: Value] = [
            "pasted": .object([
                "uti": .string(outcome.clipboard?.utiIdentifier ?? "current-clipboard"),
                "size": .int(outcome.clipboard?.data.count ?? 0),
                "textPreview": .null,
            ]),
            "paste_method": .string("current_clipboard"),
            "previous_clipboard_present": .bool(outcome.clipboard != nil),
            "clipboard_mutated": .bool(false),
            "restore_delay_ms": .int(restoreDelayMs),
            "execution_time": .double(executionTime),
            "delivery_mode": .string(outcome.targetPID == nil ? "foreground" : "background"),
            "target_pid": outcome.targetPID.map { .int(Int($0)) } ?? .null,
            "target_window_id": outcome.targetWindowID.map(Value.int) ?? .null,
        ]
        try metaFields.merge(Self.targetMetadataFields(actionResult.targetIdentity)) { _, target in target }
        let meta = try MCPToolResponseMetadataProjector.metadata(
            merging: metaFields,
            outcome: actionResult.outcome)
        let resolvedWindowTitle = try? await target.resolveWindowTitleIfNeeded(windows: self.context.windows)
        if Task.isCancelled {
            throw ClipboardPasteOutcomeError(
                kind: .indeterminate,
                causeDescription: "The caller cancelled after Cmd+V dispatch completed.",
                clipboardRestoreAttempted: false,
                targetProcessIdentifier: outcome.targetPID)
        }
        let summary = ToolEventSummary(
            targetApp: target.appIdentifier,
            windowTitle: resolvedWindowTitle,
            actionDescription: "Paste current clipboard")
        return ToolResponse(
            content: [.text(
                text: "\(AgentDisplayTokens.Status.success) Pasted the current clipboard " +
                    "in \(String(format: "%.2f", executionTime))s",
                annotations: nil,
                _meta: nil)],
            meta: ToolEventSummary.merge(summary: summary, into: meta))
    }

    private func combinedPasteActionResult(
        _ leaf: UIAutomationActionResult<Void>,
        focusResult: MCPInteractionFocusResult?) throws -> UIAutomationActionResult<Void>
    {
        guard let focusResult else { return leaf }
        guard leaf.outcome != nil else {
            let legacyLeaf = UIAutomationActionResult(
                payload: leaf.payload,
                outcome: .dispatchedUnverified(
                    route: focusResult.outcome.route,
                    delivery: .init(mechanism: .globalEvents, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                targetIdentity: leaf.targetIdentity)
            return try focusResult.combining(legacyLeaf, operation: "Paste")
        }
        return try focusResult.combining(leaf, operation: "Paste")
    }

    private static func targetMetadataFields(
        _ identity: DesktopTargetIdentity?) throws -> [String: Value]
    {
        guard let identity else { return [:] }
        let receipt = if let exactWindow = identity.exactWindow {
            DesktopActionTargetReceipt(
                processIdentifier: exactWindow.identity.ownerProcessIdentifier,
                processStartIdentity: exactWindow.identity.ownerProcessStartIdentity,
                windowID: exactWindow.identity.windowID)
        } else {
            DesktopActionTargetReceipt(
                processIdentifier: identity.processIdentity.processIdentifier,
                processStartIdentity: identity.processIdentity.processStartIdentity)
        }
        return try ["target_receipt": Value(receipt)]
    }

    @MainActor
    private func resolveDeliveryDestination(
        target: MCPInteractionTarget,
        foreground: Bool,
        expectedPIDIdentity: UInt64?) async throws -> UIAutomationTarget
    {
        if foreground {
            try Self.validateExplicitPIDIdentity(target: target, expectedPIDIdentity: expectedPIDIdentity)
            return .foreground
        }
        let plannedTarget = try await target.requireBackgroundKeyboardTarget(
            applications: self.context.applications,
            windows: self.context.windows)
        let authorizedTarget = try self.authorizedBackgroundDestination(plannedTarget)
        guard let processIdentifier = authorizedTarget.processIdentifier else {
            throw PasteToolError("Background paste requires a resolved target process.")
        }
        if target.pid != nil {
            guard let expectedPIDIdentity,
                  authorizedTarget.processIdentity?.processStartIdentity == expectedPIDIdentity
            else {
                throw PasteToolError("Target process PID \(processIdentifier) changed identity while waiting.")
            }
        }
        guard authorizedTarget.exactWindow != nil else { return authorizedTarget }
        do {
            _ = try ExactWindowKeyboardRuntime.requireOutcomeProvider(
                automation: self.context.automation,
                operation: "Exact-window paste")
        } catch {
            throw PasteToolError(
                error.localizedDescription,
                refusalReason: .runtimeIncompatible)
        }
        guard self.context.automation is any TargetedFocusedElementServiceProtocol else {
            throw PasteToolError(
                "This automation host does not support focused exact-window background paste.",
                refusalReason: .runtimeIncompatible)
        }
        let focusedTarget = try await authorizedTarget.pinningCurrentFocusedElement(using: self.context.automation)
        return try self.authorizedBackgroundDestination(focusedTarget)
    }

    private func explicitPIDIdentity(target: MCPInteractionTarget) throws -> UInt64? {
        guard let pid = target.pid else { return nil }
        let processIdentifier = try Self.checkedProcessIdentifier(pid)
        if let plan = AuthorizedDesktopTargetPlan.current {
            guard plan.processIdentity.processIdentifier == processIdentifier else {
                throw PasteToolError("Authorized paste target does not match pid \(pid).")
            }
            return plan.processIdentity.processStartIdentity
        }
        guard let identity = ClipboardPasteTransactionGate.processStartIdentity(processIdentifier) else {
            throw PasteToolError("Could not verify process identity for pid \(pid).")
        }
        return identity
    }

    private static func validateExplicitPIDIdentity(
        target: MCPInteractionTarget,
        expectedPIDIdentity: UInt64?) throws
    {
        guard let pid = target.pid else { return }
        let processIdentifier = try Self.checkedProcessIdentifier(pid)
        guard let expectedPIDIdentity,
              ClipboardPasteTransactionGate.processStartIdentity(processIdentifier) == expectedPIDIdentity
        else {
            throw PasteToolError("Target process PID \(pid) changed identity while waiting.")
        }
    }

    static func checkedProcessIdentifier(_ value: Int) throws -> pid_t {
        guard value > 0, let processIdentifier = pid_t(exactly: value) else {
            throw MCPInteractionTargetError.invalidProcessIdentifier
        }
        return processIdentifier
    }

    private static func validatePayloadShape(_ arguments: ToolArguments) throws {
        let stringKeys = [
            "app", "window_title", "text", "filePath", "imagePath", "dataBase64", "uti", "alsoText",
        ]
        for key in stringKeys {
            guard let value = arguments.getValue(for: key) else { continue }
            guard case .string = value else {
                throw PasteToolError("Parameter '\(key)' must be a string.", refusalReason: .invalidRequest)
            }
        }
        for key in ["allowLarge", "foreground"] {
            guard let value = arguments.getValue(for: key) else { continue }
            guard case .bool = value else {
                throw PasteToolError("Parameter '\(key)' must be a boolean.", refusalReason: .invalidRequest)
            }
        }

        let hasText = arguments.getValue(for: "text") != nil
        let hasFilePath = arguments.getValue(for: "filePath") != nil
        let hasImagePath = arguments.getValue(for: "imagePath") != nil
        let hasData = arguments.getValue(for: "dataBase64") != nil
        let primaryPayloadCount = [hasText, hasFilePath || hasImagePath, hasData].count(where: { $0 })
        guard primaryPayloadCount <= 1 else {
            throw PasteToolError(
                "Provide exactly one of text, filePath/imagePath, or dataBase64+uti.",
                refusalReason: .invalidRequest)
        }
        guard !(hasFilePath && hasImagePath) else {
            throw PasteToolError(
                "filePath and imagePath are aliases; provide only one.",
                refusalReason: .invalidRequest)
        }
        if hasData, arguments.getValue(for: "uti") == nil {
            throw PasteToolError("dataBase64 requires uti.", refusalReason: .invalidRequest)
        }
        let hasPayloadModifier = ["uti", "alsoText", "allowLarge"].contains {
            arguments.getValue(for: $0) != nil
        }
        if primaryPayloadCount == 0, hasPayloadModifier {
            throw PasteToolError(
                "Provide text, filePath/imagePath, or dataBase64+uti before payload modifiers.",
                refusalReason: .invalidRequest)
        }
    }

    private func makePayload(arguments: ToolArguments) throws -> PasteToolPayload {
        if arguments.getValue(for: "text") != nil, let text = arguments.getString("text") {
            let request = try ClipboardPayloadBuilder.textRequest(
                text: text,
                alsoText: nil,
                allowLarge: arguments.getBool("allowLarge") ?? false)
            return .explicit(request: request, text: text)
        }

        if let filePath = arguments.getString("filePath") ?? arguments.getString("imagePath") {
            let url = ClipboardPathResolver.fileURL(from: filePath)
            let data = try Data(contentsOf: url)
            let inferred = UTType(filenameExtension: url.pathExtension) ?? .data
            let forced = arguments.getString("uti").flatMap(UTType.init(_:)) ?? inferred
            let request = ClipboardPayloadBuilder.dataRequest(
                data: data,
                uti: forced,
                alsoText: arguments.getString("alsoText"),
                allowLarge: arguments.getBool("allowLarge") ?? false)
            return .explicit(request: request, text: Self.backgroundPlainText(from: request))
        }

        if let b64 = arguments.getString("dataBase64"), let utiId = arguments.getString("uti") {
            let request = try ClipboardPayloadBuilder.base64Request(
                base64: b64,
                utiIdentifier: utiId,
                alsoText: arguments.getString("alsoText"),
                allowLarge: arguments.getBool("allowLarge") ?? false)
            return .explicit(request: request, text: Self.backgroundPlainText(from: request))
        }

        let payloadModifiers = ["uti", "alsoText", "allowLarge"]
        if payloadModifiers.contains(where: { arguments.getValue(for: $0) != nil }) ||
            arguments.getValue(for: "dataBase64") != nil
        {
            throw ClipboardServiceError.writeFailed(
                "Provide text, filePath/imagePath, or dataBase64+uti.")
        }
        return .current
    }

    private func authorizedBackgroundDestination(_ candidate: UIAutomationTarget) throws -> UIAutomationTarget {
        guard AuthorizedDesktopTargetPlan.current != nil else { return candidate }
        let identity = try Self.desktopTargetIdentity(candidate)
        return try self.context.coalesceAuthorizedDesktopTarget(
            identity,
            operation: "Background text paste").target
    }
}

extension PasteTool: MCPToolArgumentSemanticValidating {}

extension PasteTool {
    fileprivate static func readResult(for request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        guard let primary = request.representations.first else {
            throw ClipboardServiceError.writeFailed("No representations provided.")
        }
        let textPreview: String? = if let text = request.alsoText {
            String(text.prefix(80))
        } else if primary.utiIdentifier == UTType.plainText.identifier ||
            primary.utiIdentifier == UTType.utf8PlainText.identifier,
            let string = String(data: primary.data, encoding: .utf8)
        {
            String(string.prefix(80))
        } else {
            nil
        }
        return ClipboardReadResult(
            utiIdentifier: primary.utiIdentifier,
            data: primary.data,
            textPreview: textPreview)
    }

    fileprivate static func backgroundPlainText(from request: ClipboardWriteRequest) -> String? {
        guard let primary = request.representations.first,
              primary.utiIdentifier == UTType.plainText.identifier ||
              primary.utiIdentifier == UTType.utf8PlainText.identifier
        else {
            return nil
        }
        return String(data: primary.data, encoding: .utf8)
    }
}

private enum PasteToolPayload: Sendable {
    case current
    case explicit(request: ClipboardWriteRequest, text: String?)
}

private enum PasteHotkeyRoute {
    case foreground
    case process(any TargetedHotkeyServiceProtocol)
    case exact(any UIAutomationActionOutcomeProviding)
}

private struct ClipboardPasteTransactionOutcome: Sendable {
    let setResult: ClipboardReadResult
    let previousClipboardPresent: Bool
    let restoreResult: ClipboardReadResult?
    let restoreErrorDescription: String?
    let targetPID: pid_t?
    let targetWindowID: Int?
    let actionResult: UIAutomationActionResult<Void>
}

private struct CurrentClipboardPasteOutcome: Sendable {
    let clipboard: ClipboardReadResult?
    let targetPID: pid_t?
    let targetWindowID: Int?
    let actionResult: UIAutomationActionResult<Void>
}

private struct PasteToolError: LocalizedError {
    let message: String
    let refusalReason: DesktopActionOutcome.RefusalReason

    init(
        _ message: String,
        refusalReason: DesktopActionOutcome.RefusalReason = .targetUnavailable)
    {
        self.message = message
        self.refusalReason = refusalReason
    }

    var errorDescription: String? {
        self.message
    }
}
