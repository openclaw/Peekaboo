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
    private let windowIdentityProvider: @Sendable (CGWindowID) -> SystemWindowIdentity?
    private let windowMutationIdentityProvider: @Sendable (CGWindowID) -> WindowMutationIdentity?

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
        self.windowIdentityProvider = SystemIdentityResolver.windowIdentity
        self.windowMutationIdentityProvider = SystemIdentityResolver.windowMutationIdentity
    }

    init(
        context: MCPToolContext,
        windowIdentityProvider: @escaping @Sendable (CGWindowID) -> SystemWindowIdentity?)
    {
        self.context = context
        self.windowIdentityProvider = windowIdentityProvider
        self.windowMutationIdentityProvider = { windowID in
            guard let window = windowIdentityProvider(windowID) else { return nil }
            return WindowMutationIdentity(
                windowID: Int(windowID),
                ownerProcessIdentifier: window.ownerProcessIdentifier,
                ownerProcessStartIdentity: 1,
                capturedBounds: window.bounds)
        }
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let startTime = Date()

        do {
            let target = try MCPInteractionTarget(
                app: arguments.getString("app"),
                pid: arguments.validatedInt("pid"),
                windowTitle: arguments.getString("window_title"),
                windowIndex: arguments.validatedInt("window_index"),
                windowId: arguments.validatedInt("window_id"))

            let foreground = arguments.getBool("foreground") ?? false
            let expectedPIDIdentity = try Self.explicitPIDIdentity(target: target)
            let payload = try self.makePayload(arguments: arguments)
            let restoreDelayMs = try max(0, arguments.validatedInt("restore_delay_ms") ?? 150)

            if case let .explicit(request, text?) = payload, !foreground {
                let destination = try await self.resolveDeliveryDestination(
                    target: target,
                    foreground: false,
                    expectedPIDIdentity: expectedPIDIdentity)
                guard destination.targetPID != nil else {
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
                    if destination.targetPID == nil {
                        _ = try await target.focusIfRequested(windows: self.context.windows)
                    }
                    return try await self.performCurrentClipboardPaste(
                        destination: destination,
                        restoreDelayMs: restoreDelayMs)
                }
                return try await self.currentClipboardResponse(
                    outcome: outcome,
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
                if destination.targetPID == nil {
                    _ = try await target.focusIfRequested(windows: self.context.windows)
                }
                return try await self.performClipboardPasteTransaction(
                    request: request,
                    destination: destination,
                    restoreDelayMs: restoreDelayMs)
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

            let meta: Value = .object([
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
            ])

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
        } catch let error as ClipboardPasteOutcomeError {
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
        } catch let error as PasteToolError {
            return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: error.message,
                reason: error.refusalReason)
        } catch {
            self.logger.error("Paste failed: \(error.localizedDescription)")
            return ToolResponse.error("Paste failed: \(error.localizedDescription)")
        }
    }

    private func directTextOutcomeResponse(
        _ error: InputDeliveryIndeterminateError,
        requestedCharacterCount: Int,
        destination: PasteDeliveryDestination) -> ToolResponse
    {
        self.logger.error("Direct text paste outcome was indeterminate")
        return ToolResponse.error(
            error.localizedDescription,
            meta: .object([
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
                "target_pid": destination.targetPID.map { .int(Int($0)) } ?? .null,
                "target_window_id": destination.exactWindow.map { .int($0.windowID) } ?? .null,
                "requires_fresh_observation": .bool(true),
            ]))
    }

    @MainActor
    private func performClipboardPasteTransaction(
        request: ClipboardWriteRequest,
        destination: PasteDeliveryDestination,
        restoreDelayMs: Int) async throws -> ClipboardPasteTransactionOutcome
    {
        let exactWindowAutomation: (any ExactWindowTargetedKeyboardServiceProtocol)?
        let targetedAutomation: (any TargetedHotkeyServiceProtocol)?
        if destination.exactWindow != nil {
            guard let automation = self.context.automation as? any ExactWindowTargetedKeyboardServiceProtocol,
                  automation.supportsExactWindowTargetedKeyboard
            else {
                throw PasteToolError(
                    "This automation host does not support atomic exact-window background paste delivery.",
                    refusalReason: .runtimeIncompatible)
            }
            exactWindowAutomation = automation
            targetedAutomation = nil
        } else if destination.targetPID != nil {
            guard let automation = self.context.automation as? any TargetedHotkeyServiceProtocol,
                  automation.supportsTargetedHotkeys,
                  automation.supportsProcessGenerationPinnedHotkeys
            else {
                throw PasteToolError(
                    "This automation host does not support background paste delivery.",
                    refusalReason: .runtimeIncompatible)
            }
            exactWindowAutomation = nil
            targetedAutomation = automation
        } else {
            exactWindowAutomation = nil
            targetedAutomation = nil
        }

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

        let dispatchErrorDescription: String?
        do {
            if let exactWindow = destination.exactWindow, let exactWindowAutomation {
                try await exactWindowAutomation.hotkey(
                    keys: "cmd,v",
                    holdDuration: 50,
                    expectedWindowIdentity: exactWindow.windowIdentity,
                    expectedWindowBounds: exactWindow.bounds)
            } else if let processIdentity = destination.processIdentity, let targetedAutomation {
                try await targetedAutomation.hotkey(
                    keys: "cmd,v",
                    holdDuration: 50,
                    expectedProcessIdentity: processIdentity)
            } else {
                try await self.context.automation.hotkey(keys: "cmd,v", holdDuration: 50)
            }
            dispatchErrorDescription = nil
        } catch {
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

        if dispatchErrorDescription != nil || Task.isCancelled {
            throw ClipboardPasteOutcomeError(
                kind: .indeterminate,
                causeDescription: dispatchErrorDescription ?? "The caller cancelled after Cmd+V dispatch began.",
                clipboardRestoreAttempted: true,
                clipboardRestoreErrorDescription: restoreErrorDescription,
                targetProcessIdentifier: destination.targetPID)
        }
        if destination.targetPID != nil {
            throw ClipboardPasteOutcomeError(
                kind: .unverified,
                causeDescription: "The targeted event API does not acknowledge receiver consumption.",
                clipboardRestoreAttempted: true,
                clipboardRestoreErrorDescription: restoreErrorDescription,
                targetProcessIdentifier: destination.targetPID)
        }

        return ClipboardPasteTransactionOutcome(
            setResult: setResult,
            previousClipboardPresent: priorClipboard != nil,
            restoreResult: restoreResult,
            restoreErrorDescription: restoreErrorDescription,
            targetPID: destination.targetPID,
            targetWindowID: destination.exactWindow?.windowID)
    }

    @MainActor
    private func performCurrentClipboardPaste(
        destination: PasteDeliveryDestination,
        restoreDelayMs: Int) async throws -> CurrentClipboardPasteOutcome
    {
        let exactWindowAutomation: (any ExactWindowTargetedKeyboardServiceProtocol)?
        let targetedAutomation: (any TargetedHotkeyServiceProtocol)?
        if destination.exactWindow != nil {
            guard let automation = self.context.automation as? any ExactWindowTargetedKeyboardServiceProtocol,
                  automation.supportsExactWindowTargetedKeyboard
            else {
                throw PasteToolError(
                    "This automation host does not support atomic exact-window background paste delivery.",
                    refusalReason: .runtimeIncompatible)
            }
            exactWindowAutomation = automation
            targetedAutomation = nil
        } else if destination.targetPID != nil {
            guard let automation = self.context.automation as? any TargetedHotkeyServiceProtocol,
                  automation.supportsTargetedHotkeys,
                  automation.supportsProcessGenerationPinnedHotkeys
            else {
                throw PasteToolError(
                    "This automation host does not support background paste delivery.",
                    refusalReason: .runtimeIncompatible)
            }
            exactWindowAutomation = nil
            targetedAutomation = automation
        } else {
            exactWindowAutomation = nil
            targetedAutomation = nil
        }

        let currentClipboard = try self.context.clipboard.get(prefer: nil)
        try Task.checkCancellation()
        let dispatchErrorDescription: String?
        do {
            if let exactWindow = destination.exactWindow, let exactWindowAutomation {
                try await exactWindowAutomation.hotkey(
                    keys: "cmd,v",
                    holdDuration: 50,
                    expectedWindowIdentity: exactWindow.windowIdentity,
                    expectedWindowBounds: exactWindow.bounds)
            } else if let processIdentity = destination.processIdentity, let targetedAutomation {
                try await targetedAutomation.hotkey(
                    keys: "cmd,v",
                    holdDuration: 50,
                    expectedProcessIdentity: processIdentity)
            } else {
                try await self.context.automation.hotkey(keys: "cmd,v", holdDuration: 50)
            }
            dispatchErrorDescription = nil
        } catch {
            dispatchErrorDescription = error.localizedDescription
        }

        await ClipboardPasteTransactionGate.waitForPasteConsumption(milliseconds: restoreDelayMs)
        if dispatchErrorDescription != nil || Task.isCancelled {
            throw ClipboardPasteOutcomeError(
                kind: .indeterminate,
                causeDescription: dispatchErrorDescription ?? "The caller cancelled after Cmd+V dispatch began.",
                clipboardRestoreAttempted: false,
                targetProcessIdentifier: destination.targetPID)
        }
        if destination.targetPID != nil {
            throw ClipboardPasteOutcomeError(
                kind: .unverified,
                causeDescription: "The targeted event API does not acknowledge receiver consumption.",
                clipboardRestoreAttempted: false,
                targetProcessIdentifier: destination.targetPID)
        }
        return CurrentClipboardPasteOutcome(
            clipboard: currentClipboard,
            targetPID: destination.targetPID,
            targetWindowID: destination.exactWindow?.windowID)
    }

    @MainActor
    private func performBackgroundTextPaste(
        text: String,
        request: ClipboardWriteRequest,
        target: MCPInteractionTarget,
        destination: PasteDeliveryDestination,
        startedAt: Date) async throws -> ToolResponse
    {
        guard let targetPID = destination.targetPID else {
            throw PasteToolError("Background text paste requires a resolved target process.")
        }
        let typeResult: TypeResult
        if let exactWindow = destination.exactWindow {
            guard let automation = self.context.automation as? any ExactWindowTargetedKeyboardServiceProtocol,
                  automation.supportsExactWindowTargetedKeyboard
            else {
                throw PasteToolError(
                    "This automation host does not support atomic exact-window background text delivery.",
                    refusalReason: .runtimeIncompatible)
            }
            try Task.checkCancellation()
            do {
                typeResult = try await automation.typeActions(
                    [.text(text)],
                    cadence: .fixed(milliseconds: 0),
                    snapshotId: nil,
                    expectedWindowIdentity: exactWindow.windowIdentity,
                    expectedWindowBounds: exactWindow.bounds)
            } catch let error as InputDeliveryIndeterminateError {
                return self.directTextOutcomeResponse(
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
                typeResult = try await automation.typeActions(
                    [.text(text)],
                    cadence: .fixed(milliseconds: 0),
                    snapshotId: nil,
                    expectedProcessIdentity: processIdentity)
            } catch let error as InputDeliveryIndeterminateError {
                return self.directTextOutcomeResponse(
                    Self.pasteDeliveryError(from: error),
                    requestedCharacterCount: text.count,
                    destination: destination)
            }
        }
        if Task.isCancelled {
            return self.directTextOutcomeResponse(
                InputDeliveryIndeterminateError(
                    operation: .paste,
                    emittedUnitCount: typeResult.totalCharacters,
                    causeDescription: "The caller cancelled after direct text dispatch completed."),
                requestedCharacterCount: text.count,
                destination: destination)
        }
        let setResult = try Self.readResult(for: request)
        let executionTime = Date().timeIntervalSince(startedAt)
        let meta: Value = .object([
            "pasted": .object([
                "uti": .string(setResult.utiIdentifier),
                "size": .int(setResult.data.count),
                "textPreview": setResult.textPreview.map(Value.string) ?? .null,
            ]),
            "paste_method": .string("background_text"),
            "characters_typed": .int(typeResult.totalCharacters),
            "execution_time": .double(executionTime),
            "delivery_mode": .string("background"),
            "target_pid": .int(Int(targetPID)),
            "target_window_id": destination.exactWindow.map { .int($0.windowID) } ?? .null,
        ])
        let summary = ToolEventSummary(
            targetApp: target.appIdentifier,
            windowTitle: nil,
            actionDescription: "Paste text",
            notes: setResult.utiIdentifier)
        return ToolResponse(
            content: [.text(
                text: "\(AgentDisplayTokens.Status.success) Pasted text in the background " +
                    "in \(String(format: "%.2f", executionTime))s",
                annotations: nil,
                _meta: nil)],
            meta: ToolEventSummary.merge(summary: summary, into: meta))
    }

    private static func pasteDeliveryError(
        from error: InputDeliveryIndeterminateError) -> InputDeliveryIndeterminateError
    {
        InputDeliveryIndeterminateError(
            operation: .paste,
            emittedUnitCount: error.emittedUnitCount,
            causeDescription: error.causeDescription ?? error.localizedDescription)
    }

    @MainActor
    private func currentClipboardResponse(
        outcome: CurrentClipboardPasteOutcome,
        target: MCPInteractionTarget,
        restoreDelayMs: Int,
        startedAt: Date) async throws -> ToolResponse
    {
        let executionTime = Date().timeIntervalSince(startedAt)
        let meta: Value = .object([
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
        ])
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

    @MainActor
    private func resolveDeliveryDestination(
        target: MCPInteractionTarget,
        foreground: Bool,
        expectedPIDIdentity: UInt64?) async throws -> PasteDeliveryDestination
    {
        if foreground {
            try Self.validateExplicitPIDIdentity(target: target, expectedPIDIdentity: expectedPIDIdentity)
            return .foreground
        }
        if target.hasWindowSelector {
            return try await self.resolveExactWindowDestination(
                target: target,
                expectedPIDIdentity: expectedPIDIdentity)
        }
        let processIdentity = try await target.requireBackgroundProcessIdentity(
            applications: self.context.applications,
            windows: self.context.windows)
        let processIdentifier = processIdentity.processIdentifier
        let applications = try await self.context.applications.listApplications().data.applications
        guard let application = applications.first(where: { $0.processIdentifier == processIdentifier }) else {
            throw PasteToolError("Target process PID \(processIdentifier) is no longer running.")
        }
        try application.requireBackgroundInputEligibility()
        if target.pid != nil {
            guard let expectedPIDIdentity,
                  ClipboardPasteTransactionGate.processStartIdentity(processIdentifier) == expectedPIDIdentity
            else {
                throw PasteToolError("Target process PID \(processIdentifier) changed identity while waiting.")
            }
        }
        return .process(processIdentity)
    }

    @MainActor
    private func resolveExactWindowDestination(
        target: MCPInteractionTarget,
        expectedPIDIdentity: UInt64?) async throws -> PasteDeliveryDestination
    {
        try target.validate()
        guard let windowTarget = try target.toWindowTarget() else {
            throw PasteToolError(
                "Exact-window background paste requires a window selector.",
                refusalReason: .invalidRequest)
        }
        guard let selectedWindow = try await self.context.windows.listWindows(target: windowTarget).first else {
            throw PasteToolError("Could not resolve the requested exact window.")
        }
        guard selectedWindow.windowID > 0,
              let windowID = CGWindowID(exactly: selectedWindow.windowID),
              let identity = self.windowIdentityProvider(windowID)
        else {
            throw PasteToolError("Window \(selectedWindow.windowID) is no longer present.")
        }
        guard !identity.bounds.isEmpty else {
            throw PasteToolError("Window \(selectedWindow.windowID) no longer has usable bounds.")
        }

        let requestedProcessIdentifier = try await self.requestedProcessIdentifier(target: target)
        if let requestedProcessIdentifier,
           requestedProcessIdentifier != identity.ownerProcessIdentifier
        {
            throw PasteToolError(
                "Window \(selectedWindow.windowID) is owned by PID \(identity.ownerProcessIdentifier), not the " +
                    "requested PID \(requestedProcessIdentifier).")
        }

        let applications = try await self.context.applications.listApplications().data.applications
        guard let application = applications.first(where: {
            $0.processIdentifier == identity.ownerProcessIdentifier
        }) else {
            throw PasteToolError("Target process PID \(identity.ownerProcessIdentifier) is no longer running.")
        }
        try application.requireBackgroundInputEligibility()
        if target.pid != nil {
            guard let expectedPIDIdentity,
                  ClipboardPasteTransactionGate.processStartIdentity(identity.ownerProcessIdentifier) ==
                  expectedPIDIdentity
            else {
                throw PasteToolError(
                    "Target process PID \(identity.ownerProcessIdentifier) changed identity while waiting.")
            }
        }

        return try .exactWindow(PasteExactWindowDestination(
            processIdentifier: identity.ownerProcessIdentifier,
            windowID: selectedWindow.windowID,
            bounds: identity.bounds,
            windowIdentity: self.requireWindowMutationIdentity(
                windowID: selectedWindow.windowID,
                processIdentifier: identity.ownerProcessIdentifier,
                bounds: identity.bounds)))
    }

    private func requireWindowMutationIdentity(
        windowID: Int,
        processIdentifier: pid_t,
        bounds: CGRect) throws -> WindowMutationIdentity
    {
        guard let cgWindowID = CGWindowID(exactly: windowID),
              let identity = self.windowMutationIdentityProvider(cgWindowID),
              identity.ownerProcessIdentifier == processIdentifier,
              let current = self.windowIdentityProvider(cgWindowID),
              current.ownerProcessIdentifier == processIdentifier,
              current.bounds == bounds
        else {
            throw PasteToolError("Exact-window identity changed before paste dispatch.")
        }
        return identity
    }

    @MainActor
    private func requestedProcessIdentifier(target: MCPInteractionTarget) async throws -> pid_t? {
        if let pid = target.pid {
            return try Self.checkedProcessIdentifier(pid)
        }
        guard let app = target.app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else {
            return nil
        }
        let application = try await self.context.applications.findApplication(identifier: app)
        return pid_t(application.processIdentifier)
    }

    private static func explicitPIDIdentity(target: MCPInteractionTarget) throws -> UInt64? {
        guard let pid = target.pid else { return nil }
        let processIdentifier = try Self.checkedProcessIdentifier(pid)
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
}

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

private struct PasteExactWindowDestination: Sendable {
    let processIdentifier: pid_t
    let windowID: Int
    let bounds: CGRect
    let windowIdentity: WindowMutationIdentity
}

extension ServiceApplicationInfo {
    fileprivate func requireBackgroundInputEligibility() throws {
        guard self.isEligibleForBackgroundInput else {
            throw PasteToolError(
                "Target process PID \(self.processIdentifier) cannot receive background input because it is a " +
                    "prohibited helper or its application metadata is incomplete.")
        }
    }
}

private struct PasteDeliveryDestination: Sendable {
    let targetPID: pid_t?
    let processIdentity: ApplicationProcessIdentity?
    let exactWindow: PasteExactWindowDestination?

    static let foreground = PasteDeliveryDestination(targetPID: nil, processIdentity: nil, exactWindow: nil)

    static func process(_ identity: ApplicationProcessIdentity) -> PasteDeliveryDestination {
        PasteDeliveryDestination(
            targetPID: identity.processIdentifier,
            processIdentity: identity,
            exactWindow: nil)
    }

    static func exactWindow(_ window: PasteExactWindowDestination) -> PasteDeliveryDestination {
        PasteDeliveryDestination(
            targetPID: window.processIdentifier,
            processIdentity: ApplicationProcessIdentity(
                processIdentifier: window.processIdentifier,
                processStartIdentity: window.windowIdentity.ownerProcessStartIdentity),
            exactWindow: window)
    }
}

private struct ClipboardPasteTransactionOutcome: Sendable {
    let setResult: ClipboardReadResult
    let previousClipboardPresent: Bool
    let restoreResult: ClipboardReadResult?
    let restoreErrorDescription: String?
    let targetPID: pid_t?
    let targetWindowID: Int?
}

private struct CurrentClipboardPasteOutcome: Sendable {
    let clipboard: ClipboardReadResult?
    let targetPID: pid_t?
    let targetWindowID: Int?
}

private struct PasteToolError: Error {
    let message: String
    let refusalReason: DesktopActionOutcome.RefusalReason

    init(
        _ message: String,
        refusalReason: DesktopActionOutcome.RefusalReason = .targetUnavailable)
    {
        self.message = message
        self.refusalReason = refusalReason
    }
}
