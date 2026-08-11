import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation
import UniformTypeIdentifiers

/// Pastes text through background typing when targeted, otherwise uses clipboard + Cmd+V.
@available(macOS 14.0, *)
@MainActor
struct PasteCommand: ActionOutputFormattable, ErrorHandlingCommand, OutputFormattable, RuntimeBackedCommand {
    @Argument(help: "Text to paste")
    var text: String?

    @Option(name: .customLong("text"), help: "Text to paste (alternative to positional argument)")
    var textOption: String?

    @Option(name: .long, help: "Path to file to paste (copies file bytes into clipboard first)")
    var filePath: String?

    @Option(name: .long, help: "Base64 data to paste")
    var dataBase64: String?

    @Option(name: .long, help: "UTI for base64 payload or to force type")
    var uti: String?

    @Option(name: .long, help: "Optional plain-text companion when setting binary")
    var alsoText: String?

    @Flag(name: .long, help: "Allow payloads larger than 10 MB")
    var allowLarge = false

    @Option(help: "Delay before restoring the previous clipboard (bare values are milliseconds; default: 150ms)")
    var restoreDelay: CLIDuration?

    @OptionGroup var target: InteractionTargetOptions
    @OptionGroup var focusOptions: FocusCommandOptions

    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    private var resolvedText: String? {
        if let primary = self.text, !primary.isEmpty {
            return primary
        }
        return self.textOption
    }

    private var resolvedRestoreDelayMs: Int {
        self.restoreDelay?.roundedMilliseconds ?? 150
    }

    private var hasExplicitPayload: Bool {
        // Any payload source OR payload-modifier flag counts: `paste --uti public.rtf`
        // or `paste --allow-large` without data must fail validation, not silently
        // paste the current clipboard. An explicitly provided empty positional ("")
        // is also an explicit payload. Only targeting/focus/delivery flags may
        // combine with the bare-paste path. The restore delay is also the
        // consumption window for a current-clipboard paste, so it is valid there.
        self.text != nil || self.textOption != nil || self.filePath != nil
            || self.dataBase64 != nil || self.uti != nil || self.alsoText != nil
            || self.allowLarge
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            try self.target.validate()
            try KeyboardDeliverySupport.validateForegroundFlags(
                foreground: self.focusOptions.foreground,
                focusOptions: self.focusOptions
            )

            guard self.hasExplicitPayload else {
                try await self.pasteCurrentClipboard(
                    expectedPIDIdentity: self.explicitPIDIdentity()
                )
                return
            }

            let request = try self.makeWriteRequest()
            if let text = Self.backgroundPlainText(
                preferredText: self.resolvedText,
                request: request
            ) {
                let expectedPIDIdentity = try self.explicitPIDIdentity()
                if let targetPID = try await self.verifiedBackgroundProcessIdentifier(
                    expectedPIDIdentity: expectedPIDIdentity
                ) {
                    try await self.pasteTextInBackground(text, request: request, targetPID: targetPID)
                    return
                }
            }

            let expectedPIDIdentity = try self.explicitPIDIdentity()
            let outcome = try await self.withInteractionMutationInvalidation {
                try await ClipboardPasteTransactionGate.withExclusiveTransaction {
                    let targetPID = try await self.verifiedBackgroundProcessIdentifier(
                        expectedPIDIdentity: expectedPIDIdentity
                    )
                    if targetPID == nil {
                        try await ensureFocused(
                            snapshotId: nil,
                            target: self.target,
                            options: self.focusOptions,
                            services: self.services
                        )
                    }
                    return try await self.performClipboardPasteTransaction(request: request, targetPID: targetPID)
                }
            }
            if Task.isCancelled {
                throw ClipboardPasteOutcomeError(
                    kind: .indeterminate,
                    causeDescription: "The caller cancelled after Cmd+V dispatch completed.",
                    clipboardRestoreAttempted: true,
                    clipboardRestoreErrorDescription: outcome.restoreErrorDescription
                )
            }

            let result = PasteResult(
                pastedUti: outcome.setResult.utiIdentifier,
                pastedSize: outcome.setResult.data.count,
                pastedTextPreview: outcome.setResult.textPreview,
                previousClipboardPresent: outcome.previousClipboardPresent,
                restoredUti: outcome.restoreResult?.utiIdentifier,
                restoredSize: outcome.restoreResult?.data.count,
                restoreSucceeded: outcome.restoreErrorDescription == nil,
                restoreError: outcome.restoreErrorDescription,
                restoreDelayMs: self.resolvedRestoreDelayMs,
                deliveryMode: outcome.targetPID == nil ? KeyboardDeliveryMode.foreground.rawValue :
                    KeyboardDeliveryMode.background.rawValue,
                targetPID: outcome.targetPID.map(Int.init)
            )

            self.output(
                result,
                effect: outcome.restoreErrorDescription == nil ? .unverifiable : .partial
            ) {
                if outcome.restoreErrorDescription != nil {
                    print("⚠️  Pasted, but clipboard restoration failed. Do not retry the paste; " +
                        "the previous clipboard contents may be unavailable.")
                } else {
                    print("✅ Pasted and restored clipboard")
                }
                print("📋 Pasted: \(outcome.setResult.utiIdentifier) (\(outcome.setResult.data.count) bytes)")
                if let restoreErrorDescription = outcome.restoreErrorDescription {
                    print("♻️  Restore error: \(restoreErrorDescription)")
                } else if outcome.previousClipboardPresent {
                    print("♻️  Restored: \(outcome.restoreResult?.utiIdentifier ?? "unknown")")
                } else {
                    print("🧹 Restored: cleared (prior clipboard empty)")
                }
                if let targetPID = outcome.targetPID {
                    print("🎯 Mode: background to PID \(targetPID)")
                }
            }
        } catch let error as ClipboardPasteOutcomeError {
            self.handleError(error, customCode: .INTERACTION_FAILED)
            throw ExitCode.failure
        } catch {
            self.handleError(error)
            throw ExitCode.failure
        }
    }

    private func performClipboardPasteTransaction(
        request: ClipboardWriteRequest,
        targetPID: pid_t?
    ) async throws -> ClipboardPasteTransactionOutcome {
        if targetPID != nil {
            guard let automation = self.services.automation as? any TargetedHotkeyServiceProtocol,
                  automation.supportsTargetedHotkeys
            else {
                throw ValidationError("This automation host does not support background paste delivery.")
            }
        }

        try Task.checkCancellation()
        let priorClipboard = try self.services.clipboard.get(prefer: nil)
        let restoreSlot = "paste-\(UUID().uuidString)"
        try Task.checkCancellation()
        if priorClipboard != nil {
            try self.services.clipboard.save(slot: restoreSlot)
        }
        try Task.checkCancellation()

        var restorePending = false
        func restoreBeforeDispatchFailure(_ primaryError: any Error) throws -> Never {
            do {
                _ = try self.restoreClipboard(
                    priorClipboardPresent: priorClipboard != nil,
                    slot: restoreSlot
                )
                restorePending = false
            } catch {
                restorePending = false
                throw ClipboardServiceError.writeFailed(
                    "Paste payload setup failed (\(primaryError.localizedDescription)); " +
                        "restoring the prior clipboard also failed: \(error.localizedDescription). " +
                        "The clipboard may have changed; do not retry until its state is inspected."
                )
            }
            throw primaryError
        }
        defer {
            if restorePending {
                do {
                    _ = try self.restoreClipboard(
                        priorClipboardPresent: priorClipboard != nil,
                        slot: restoreSlot
                    )
                } catch {
                    self.logger.error(
                        "Failed to restore clipboard after paste error: \(error.localizedDescription)"
                    )
                }
            }
        }

        restorePending = true
        let setResult: ClipboardReadResult
        do {
            setResult = try self.services.clipboard.set(request)
            try Task.checkCancellation()
        } catch {
            try restoreBeforeDispatchFailure(error)
        }

        let dispatchErrorDescription: String?
        do {
            if let targetPID {
                try await AutomationServiceBridge.hotkey(
                    automation: self.services.automation,
                    keys: "cmd,v",
                    holdDuration: 50,
                    targetProcessIdentifier: targetPID
                )
            } else {
                try await AutomationServiceBridge.hotkey(
                    automation: self.services.automation,
                    keys: "cmd,v",
                    holdDuration: 50
                )
            }
            dispatchErrorDescription = nil
        } catch {
            dispatchErrorDescription = error.localizedDescription
        }

        let restoreResult: ClipboardReadResult?
        let restoreErrorDescription: String?
        do {
            restoreResult = try await self.restoreClipboardAfterConsumption(
                priorClipboardPresent: priorClipboard != nil,
                slot: restoreSlot
            )
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
                targetProcessIdentifier: targetPID
            )
        }
        if targetPID != nil {
            throw ClipboardPasteOutcomeError(
                kind: .unverified,
                causeDescription: "The targeted event API does not acknowledge receiver consumption.",
                clipboardRestoreAttempted: true,
                clipboardRestoreErrorDescription: restoreErrorDescription,
                targetProcessIdentifier: targetPID
            )
        }

        return ClipboardPasteTransactionOutcome(
            setResult: setResult,
            previousClipboardPresent: priorClipboard != nil,
            restoreResult: restoreResult,
            restoreErrorDescription: restoreErrorDescription,
            targetPID: targetPID
        )
    }

    private func pasteTextInBackground(
        _ text: String,
        request: ClipboardWriteRequest,
        targetPID: pid_t
    ) async throws {
        let setResult = try Self.readResult(for: request)
        _ = try await self.withInteractionMutationInvalidation {
            try await AutomationServiceBridge.typeActions(
                automation: self.services.automation,
                request: TypeActionsRequest(
                    actions: [.text(text)],
                    cadence: .fixed(milliseconds: 0),
                    snapshotId: nil
                ),
                targetProcessIdentifier: targetPID
            )
        }

        let result = PasteResult(
            pastedUti: setResult.utiIdentifier,
            pastedSize: setResult.data.count,
            pastedTextPreview: setResult.textPreview,
            previousClipboardPresent: false,
            restoredUti: nil,
            restoredSize: nil,
            restoreSucceeded: true,
            restoreError: nil,
            restoreDelayMs: 0,
            deliveryMode: KeyboardDeliveryMode.background.rawValue,
            targetPID: Int(targetPID)
        )

        self.output(result) {
            print("✅ Pasted text")
            print("📋 Pasted: \(setResult.utiIdentifier) (\(setResult.data.count) bytes)")
            print("🎯 Mode: background to PID \(targetPID)")
        }
    }

    private func restoreClipboard(
        priorClipboardPresent: Bool,
        slot: String
    ) throws -> ClipboardReadResult? {
        guard priorClipboardPresent else {
            self.services.clipboard.clear()
            return nil
        }
        return try self.services.clipboard.restore(slot: slot)
    }

    private func restoreClipboardAfterConsumption(
        priorClipboardPresent: Bool,
        slot: String
    ) async throws -> ClipboardReadResult? {
        await ClipboardPasteTransactionGate.waitForPasteConsumption(
            milliseconds: self.resolvedRestoreDelayMs
        )
        return try self.restoreClipboard(priorClipboardPresent: priorClipboardPresent, slot: slot)
    }

    private func makeWriteRequest() throws -> ClipboardWriteRequest {
        if let text = self.resolvedText {
            return try ClipboardPayloadBuilder.textRequest(
                text: text,
                alsoText: nil,
                allowLarge: self.allowLarge
            )
        }

        if let path = self.filePath {
            let url = ClipboardPathResolver.fileURL(from: path)
            let data = try Data(contentsOf: url)
            let inferred = UTType(filenameExtension: url.pathExtension) ?? .data
            let forced = self.uti.flatMap(UTType.init(_:)) ?? inferred
            return ClipboardPayloadBuilder.dataRequest(
                data: data,
                uti: forced,
                alsoText: self.alsoText,
                allowLarge: self.allowLarge
            )
        }

        if let b64 = self.dataBase64, let utiId = self.uti {
            guard let data = Data(base64Encoded: b64) else {
                throw ValidationError("data-base64 is not valid base64")
            }
            return ClipboardPayloadBuilder.dataRequest(
                data: data,
                utiIdentifier: utiId,
                alsoText: self.alsoText,
                allowLarge: self.allowLarge
            )
        }

        throw ValidationError("Provide text, --file-path, or --data-base64 with --uti")
    }

    private func pasteCurrentClipboard(expectedPIDIdentity: UInt64?) async throws {
        let outcome = try await self.withInteractionMutationInvalidation {
            try await ClipboardPasteTransactionGate.withExclusiveTransaction {
                let targetPID = try await self.verifiedBackgroundProcessIdentifier(
                    expectedPIDIdentity: expectedPIDIdentity
                )
                if targetPID == nil {
                    try await ensureFocused(
                        snapshotId: nil,
                        target: self.target,
                        options: self.focusOptions,
                        services: self.services
                    )
                }
                let currentClipboard = try self.services.clipboard.get(prefer: nil)
                try Task.checkCancellation()
                let dispatchErrorDescription: String?
                do {
                    if let targetPID {
                        try await AutomationServiceBridge.hotkey(
                            automation: self.services.automation,
                            keys: "cmd,v",
                            holdDuration: 50,
                            targetProcessIdentifier: targetPID
                        )
                    } else {
                        try await AutomationServiceBridge.hotkey(
                            automation: self.services.automation,
                            keys: "cmd,v",
                            holdDuration: 50
                        )
                    }
                    dispatchErrorDescription = nil
                } catch {
                    dispatchErrorDescription = error.localizedDescription
                }
                await ClipboardPasteTransactionGate.waitForPasteConsumption(
                    milliseconds: self.resolvedRestoreDelayMs
                )
                if dispatchErrorDescription != nil || Task.isCancelled {
                    throw ClipboardPasteOutcomeError(
                        kind: .indeterminate,
                        causeDescription: dispatchErrorDescription ??
                            "The caller cancelled after Cmd+V dispatch began.",
                        clipboardRestoreAttempted: false,
                        targetProcessIdentifier: targetPID
                    )
                }
                if targetPID != nil {
                    throw ClipboardPasteOutcomeError(
                        kind: .unverified,
                        causeDescription: "The targeted event API does not acknowledge receiver consumption.",
                        clipboardRestoreAttempted: false,
                        targetProcessIdentifier: targetPID
                    )
                }
                return CurrentClipboardPasteOutcome(clipboard: currentClipboard, targetPID: targetPID)
            }
        }
        if Task.isCancelled {
            throw ClipboardPasteOutcomeError(
                kind: .indeterminate,
                causeDescription: "The caller cancelled after Cmd+V dispatch completed.",
                clipboardRestoreAttempted: false
            )
        }

        let result = PasteResult(
            pastedUti: outcome.clipboard?.utiIdentifier ?? "current-clipboard",
            pastedSize: outcome.clipboard?.data.count ?? 0,
            // Never echo ambient clipboard content into structured output: the
            // user did not supply it to this command, and JSON lands in agent/CI
            // logs. Explicit-payload pastes still report the preview the caller
            // provided themselves.
            pastedTextPreview: nil,
            previousClipboardPresent: outcome.clipboard != nil,
            restoredUti: nil,
            restoredSize: nil,
            restoreSucceeded: true,
            restoreError: nil,
            restoreDelayMs: self.resolvedRestoreDelayMs,
            deliveryMode: outcome.targetPID == nil ? KeyboardDeliveryMode.foreground.rawValue :
                KeyboardDeliveryMode.background.rawValue,
            targetPID: outcome.targetPID.map(Int.init)
        )

        self.output(result) {
            print("✅ Pasted current clipboard")
            if let targetPID = outcome.targetPID {
                print("🎯 Mode: background to PID \(targetPID)")
            } else {
                print("🎯 Mode: foreground")
            }
        }
    }

    private func withInteractionMutationInvalidation<T: Sendable>(
        _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        self.resolvedRuntime.beginInteractionMutation()
        do {
            let result = try await operation()
            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "paste"
            )
            return result
        } catch {
            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "paste"
            )
            throw error
        }
    }

    private static func readResult(for request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        guard let primary = request.representations.first else {
            throw ClipboardServiceError.writeFailed("No representations provided.")
        }

        let textPreview: String? = if let text = request.alsoText {
            Self.makePreview(text)
        } else if primary.utiIdentifier == UTType.plainText.identifier ||
            primary.utiIdentifier == UTType.utf8PlainText.identifier,
            let string = String(data: primary.data, encoding: .utf8) {
            Self.makePreview(string)
        } else {
            nil
        }

        return ClipboardReadResult(
            utiIdentifier: primary.utiIdentifier,
            data: primary.data,
            textPreview: textPreview
        )
    }

    private static func backgroundPlainText(
        preferredText: String?,
        request: ClipboardWriteRequest
    ) -> String? {
        if let preferredText {
            return preferredText
        }
        guard let primary = request.representations.first,
              primary.utiIdentifier == UTType.plainText.identifier ||
              primary.utiIdentifier == UTType.utf8PlainText.identifier
        else {
            return nil
        }
        return String(data: primary.data, encoding: .utf8)
    }

    private static func makePreview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let max = 80
        guard trimmed.count > max else { return trimmed }
        let head = trimmed.prefix(max)
        return "\(head)..."
    }

    private func explicitPIDIdentity() throws -> UInt64? {
        guard let pid = self.target.pid else { return nil }
        guard let identity = ClipboardPasteTransactionGate.processStartIdentity(pid_t(pid)) else {
            throw ValidationError("Could not verify process identity for --pid \(pid).")
        }
        return identity
    }

    private func verifiedBackgroundProcessIdentifier(
        expectedPIDIdentity: UInt64? = nil
    ) async throws -> pid_t? {
        if self.focusOptions.foreground {
            try self.validateExplicitPIDIdentity(expectedPIDIdentity)
            return nil
        }

        let processIdentifier = try await KeyboardDeliverySupport.requireBackgroundProcessIdentifier(
            target: self.target,
            snapshotId: nil,
            services: self.services
        )
        let applications = try await self.services.applications.listApplications().data.applications
        guard let application = applications.first(where: { $0.processIdentifier == processIdentifier }) else {
            throw ValidationError("Target process PID \(processIdentifier) is no longer running.")
        }
        guard application.isEligibleForBackgroundInput else {
            throw ValidationError(
                "Target process PID \(processIdentifier) cannot receive background input because it is a " +
                    "prohibited helper or its application metadata is incomplete."
            )
        }
        if self.target.pid != nil {
            guard let expectedPIDIdentity,
                  ClipboardPasteTransactionGate.processStartIdentity(processIdentifier) == expectedPIDIdentity
            else {
                throw ValidationError("Target process PID \(processIdentifier) changed identity while waiting.")
            }
        }
        return processIdentifier
    }

    private func validateExplicitPIDIdentity(_ expectedPIDIdentity: UInt64?) throws {
        guard let pid = self.target.pid else { return }
        guard let expectedPIDIdentity,
              ClipboardPasteTransactionGate.processStartIdentity(pid_t(pid)) == expectedPIDIdentity
        else {
            throw ValidationError("Target process PID \(pid) changed identity while waiting.")
        }
    }
}

private struct ClipboardPasteTransactionOutcome: Sendable {
    let setResult: ClipboardReadResult
    let previousClipboardPresent: Bool
    let restoreResult: ClipboardReadResult?
    let restoreErrorDescription: String?
    let targetPID: pid_t?
}

private struct CurrentClipboardPasteOutcome: Sendable {
    let clipboard: ClipboardReadResult?
    let targetPID: pid_t?
}

struct PasteResult: Codable {
    let pastedUti: String
    let pastedSize: Int
    let pastedTextPreview: String?
    let previousClipboardPresent: Bool
    let restoredUti: String?
    let restoredSize: Int?
    let restoreSucceeded: Bool
    let restoreError: String?
    let restoreDelayMs: Int
    let deliveryMode: String
    let targetPID: Int?
}

@MainActor
extension PasteCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "paste",
                abstract: "Paste current clipboard or set clipboard, paste, and restore",
                discussion: """
                    With no payload, paste sends Cmd+V using the current clipboard contents.
                    Background paste requires --app or --pid. Add --foreground for intentional
                    paste into the current focus or to focus a selected window first.

                    This command reduces drift in automation flows by collapsing:
                      1) clipboard set
                      2) paste delivery
                      3) clipboard restore
                    into one operation when you provide text, a file, an image, or base64 data.
                    Background text delivery is used by default when a target process is known;
                    binary/current-clipboard payloads use targeted Cmd+V. Because macOS does not
                    acknowledge receiver consumption, those background calls return a may-have-pasted,
                    do-not-retry error after cleanup. Add --foreground for focused/global paste.

                    EXAMPLES:
                      peekaboo paste --foreground
                      peekaboo paste \"Hello\" --app TextEdit
                      peekaboo paste \"Hello\" --app TextEdit --foreground
                      peekaboo paste --text \"Hello\" --app TextEdit --window-title \"Untitled\" --foreground
                      peekaboo paste --data-base64 \"$BASE64\" --uti public.rtf --also-text \"fallback\" --app TextEdit
                      peekaboo paste --file-path /tmp/snippet.png --app Notes
                """,
                // Bare `peekaboo paste` pastes the current clipboard; routing it to help
                // would make the documented default invocation a no-op.
                showHelpOnEmptyInvocation: false
            )
        }
    }
}

extension PasteCommand: AsyncRuntimeCommand {}
