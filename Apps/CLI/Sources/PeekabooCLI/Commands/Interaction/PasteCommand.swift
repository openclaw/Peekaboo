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
                if let deliveryTarget = try await self.preDispatchBackgroundTarget(
                    expectedPIDIdentity: expectedPIDIdentity
                ) {
                    try await self.pasteTextInBackground(text, request: request, target: deliveryTarget)
                    return
                }
            }

            let expectedPIDIdentity = try self.explicitPIDIdentity()
            let actionSequence = CommandActionSequenceAccumulator()
            let actionRoute = commandActionRoute(for: self.services)
            let outcome = try await self.preservingPasteSequence(actionSequence, route: actionRoute) {
                try await self.withInteractionMutationInvalidation {
                    try await ClipboardPasteTransactionGate.withExclusiveTransaction {
                        let deliveryTarget = try await self.preDispatchBackgroundTarget(
                            expectedPIDIdentity: expectedPIDIdentity
                        )
                        if deliveryTarget == nil {
                            try await self.ensureForegroundFocus(
                                recordingIn: actionSequence,
                                route: actionRoute
                            )
                        }
                        return try await self.performClipboardPasteTransaction(
                            request: request,
                            target: deliveryTarget ?? .foreground,
                            actionSequence: deliveryTarget == nil ? actionSequence : nil,
                            actionRoute: actionRoute
                        )
                    }
                }
            }
            if Task.isCancelled {
                let error = ClipboardPasteOutcomeError(
                    kind: .indeterminate,
                    causeDescription: "The caller cancelled after Cmd+V dispatch completed.",
                    clipboardRestoreAttempted: true,
                    clipboardRestoreErrorDescription: outcome.restoreErrorDescription
                )
                throw self.preservedPasteFailure(error, sequence: actionSequence, route: actionRoute)
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
                targetPID: outcome.targetPID.map(Int.init),
                targetWindowID: outcome.targetWindowID
            )
            let actionResult = actionSequence.result(payload: result)
            let outputOutcome = Self.outputOutcome(
                actionResult.outcome,
                mutationDisposition: actionSequence.mutationDisposition,
                restoreErrorDescription: outcome.restoreErrorDescription,
                fallbackRoute: actionRoute
            )

            self.output(
                actionResult.payload,
                effect: outcome.restoreErrorDescription == nil ? .unverifiable :
                    (outputOutcome?.effect ?? .unverifiable),
                outcome: outputOutcome,
                targetIdentity: outputOutcome == nil ? nil : actionResult.targetIdentity
            ) {
                if outcome.restoreErrorDescription != nil {
                    print("⚠️  Pasted, but clipboard restoration failed. Do not retry the paste; " +
                        "the previous clipboard contents may be unavailable.")
                } else if let outputOutcome {
                    print(ActionOutcomeHumanRenderer.statusLine(for: outputOutcome, operation: "Paste"))
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
                if let targetWindowID = outcome.targetWindowID {
                    print("🪟 Window: \(targetWindowID)")
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
        target: UIAutomationTarget,
        actionSequence: CommandActionSequenceAccumulator?,
        actionRoute: DesktopActionOutcome.Route
    ) async throws -> ClipboardPasteTransactionOutcome {
        if target.exactWindow != nil {
            _ = try ExactWindowKeyboardRuntime.requireOutcomeProvider(
                automation: self.services.automation,
                operation: "Exact-window paste"
            )
        } else if target.processIdentifier != nil {
            guard let automation = self.services.automation as? any TargetedHotkeyServiceProtocol,
                  automation.supportsTargetedHotkeys,
                  automation.supportsProcessGenerationPinnedHotkeys
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

        let dispatchFailure: DesktopActionFailure?
        let dispatchErrorDescription: String?
        do {
            try await self.dispatchPasteHotkey(
                target: target,
                recordingIn: actionSequence,
                route: actionRoute
            )
            dispatchFailure = nil
            dispatchErrorDescription = nil
        } catch let failure as DesktopActionFailure {
            dispatchFailure = failure
            dispatchErrorDescription = nil
        } catch {
            dispatchFailure = nil
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

        if let dispatchFailure {
            guard let restoreErrorDescription else { throw dispatchFailure }
            let error = ClipboardPasteOutcomeError(
                kind: .indeterminate,
                causeDescription: "\(dispatchFailure.localizedDescription); clipboard restoration also failed: " +
                    restoreErrorDescription,
                clipboardRestoreAttempted: true,
                clipboardRestoreErrorDescription: restoreErrorDescription,
                targetProcessIdentifier: target.processIdentifier
            )
            throw self.postDispatchPasteFailure(error, target: target, route: actionRoute)
        }
        if dispatchErrorDescription != nil || Task.isCancelled {
            let error = ClipboardPasteOutcomeError(
                kind: .indeterminate,
                causeDescription: dispatchErrorDescription ?? "The caller cancelled after Cmd+V dispatch began.",
                clipboardRestoreAttempted: true,
                clipboardRestoreErrorDescription: restoreErrorDescription,
                targetProcessIdentifier: target.processIdentifier
            )
            if dispatchErrorDescription != nil || actionSequence?.mutationDisposition.mutationDispatched != true {
                throw self.postDispatchPasteFailure(error, target: target, route: actionRoute)
            }
            throw error
        }
        if target.processIdentifier != nil {
            let error = ClipboardPasteOutcomeError(
                kind: .unverified,
                causeDescription: "The targeted event API does not acknowledge receiver consumption.",
                clipboardRestoreAttempted: true,
                clipboardRestoreErrorDescription: restoreErrorDescription,
                targetProcessIdentifier: target.processIdentifier
            )
            throw self.postDispatchPasteFailure(error, target: target, route: actionRoute)
        }

        return ClipboardPasteTransactionOutcome(
            setResult: setResult,
            previousClipboardPresent: priorClipboard != nil,
            restoreResult: restoreResult,
            restoreErrorDescription: restoreErrorDescription,
            targetPID: target.processIdentifier,
            targetWindowID: target.exactWindow?.identity.windowID
        )
    }

    private func pasteTextInBackground(
        _ text: String,
        request: ClipboardWriteRequest,
        target: UIAutomationTarget
    ) async throws {
        let setResult = try Self.readResult(for: request)
        let actionResult = try await self.withInteractionMutationInvalidation {
            try await AutomationServiceBridge.typeActions(
                automation: self.services.automation,
                request: TypeActionsRequest(
                    actions: [.text(text)],
                    cadence: .fixed(milliseconds: 0),
                    snapshotId: nil
                ),
                target: target
            )
        }
        let resultTargetIdentity = try Self.validateBackgroundTextResult(
            actionResult,
            authorizedTarget: target
        )
        let resultTarget = resultTargetIdentity.target

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
            targetPID: resultTarget.processIdentifier.map(Int.init),
            targetWindowID: resultTarget.exactWindow?.identity.windowID
        )

        self.output(
            result,
            outcome: actionResult.outcome,
            targetIdentity: resultTargetIdentity
        ) {
            print("✅ Pasted text")
            print("📋 Pasted: \(setResult.utiIdentifier) (\(setResult.data.count) bytes)")
            if let processIdentifier = resultTarget.processIdentifier {
                print("🎯 Mode: background to PID \(processIdentifier)")
            }
            if let windowID = resultTarget.exactWindow?.identity.windowID {
                print("🪟 Window: \(windowID)")
            }
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
        let actionSequence = CommandActionSequenceAccumulator()
        let actionRoute = commandActionRoute(for: self.services)
        let outcome = try await self.preservingPasteSequence(actionSequence, route: actionRoute) {
            let outcome = try await self.withInteractionMutationInvalidation {
                try await ClipboardPasteTransactionGate.withExclusiveTransaction {
                    let deliveryTarget = try await self.preDispatchBackgroundTarget(
                        expectedPIDIdentity: expectedPIDIdentity
                    )
                    if deliveryTarget == nil {
                        try await self.ensureForegroundFocus(
                            recordingIn: actionSequence,
                            route: actionRoute
                        )
                    }
                    let currentClipboard = try self.services.clipboard.get(prefer: nil)
                    try Task.checkCancellation()
                    let dispatchFailure: DesktopActionFailure?
                    let dispatchErrorDescription: String?
                    do {
                        try await self.dispatchPasteHotkey(
                            target: deliveryTarget ?? .foreground,
                            recordingIn: deliveryTarget == nil ? actionSequence : nil,
                            route: actionRoute
                        )
                        dispatchFailure = nil
                        dispatchErrorDescription = nil
                    } catch let failure as DesktopActionFailure {
                        dispatchFailure = failure
                        dispatchErrorDescription = nil
                    } catch {
                        dispatchFailure = nil
                        dispatchErrorDescription = error.localizedDescription
                    }
                    await ClipboardPasteTransactionGate.waitForPasteConsumption(
                        milliseconds: self.resolvedRestoreDelayMs
                    )
                    if let dispatchFailure {
                        throw dispatchFailure
                    }
                    if dispatchErrorDescription != nil || Task.isCancelled {
                        let error = ClipboardPasteOutcomeError(
                            kind: .indeterminate,
                            causeDescription: dispatchErrorDescription ??
                                "The caller cancelled after Cmd+V dispatch began.",
                            clipboardRestoreAttempted: false,
                            targetProcessIdentifier: deliveryTarget?.processIdentifier
                        )
                        if dispatchErrorDescription != nil ||
                            !actionSequence.mutationDisposition.mutationDispatched {
                            throw self.postDispatchPasteFailure(
                                error,
                                target: deliveryTarget ?? .foreground,
                                route: actionRoute
                            )
                        }
                        throw error
                    }
                    if let deliveryTarget {
                        let error = ClipboardPasteOutcomeError(
                            kind: .unverified,
                            causeDescription: "The targeted event API does not acknowledge receiver consumption.",
                            clipboardRestoreAttempted: false,
                            targetProcessIdentifier: deliveryTarget.processIdentifier
                        )
                        throw self.postDispatchPasteFailure(
                            error,
                            target: deliveryTarget,
                            route: actionRoute
                        )
                    }
                    return CurrentClipboardPasteOutcome(
                        clipboard: currentClipboard,
                        targetPID: deliveryTarget?.processIdentifier,
                        targetWindowID: deliveryTarget?.exactWindow?.identity.windowID
                    )
                }
            }
            if Task.isCancelled {
                throw ClipboardPasteOutcomeError(
                    kind: .indeterminate,
                    causeDescription: "The caller cancelled after Cmd+V dispatch completed.",
                    clipboardRestoreAttempted: false
                )
            }
            return outcome
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
            targetPID: outcome.targetPID.map(Int.init),
            targetWindowID: outcome.targetWindowID
        )
        let actionResult = actionSequence.result(payload: result)

        self.output(
            actionResult.payload,
            effect: .unverifiable,
            outcome: actionResult.outcome,
            targetIdentity: actionResult.targetIdentity
        ) {
            if let actionOutcome = actionResult.outcome {
                print(ActionOutcomeHumanRenderer.statusLine(for: actionOutcome, operation: "Paste"))
            } else {
                print("✅ Pasted current clipboard")
            }
            if let targetPID = outcome.targetPID {
                print("🎯 Mode: background to PID \(targetPID)")
            } else {
                print("🎯 Mode: foreground")
            }
            if let targetWindowID = outcome.targetWindowID {
                print("🪟 Window: \(targetWindowID)")
            }
        }
    }

    private func dispatchPasteHotkey(
        target: UIAutomationTarget,
        recordingIn actionSequence: CommandActionSequenceAccumulator?,
        route: DesktopActionOutcome.Route
    ) async throws {
        let result = try await AutomationServiceBridge.hotkey(
            automation: self.services.automation,
            keys: "cmd,v",
            holdDuration: 50,
            target: target
        )
        try DesktopActionFailure.requireConfirmedIfReported(
            result.outcome,
            operation: "Paste hotkey"
        )
        if let actionSequence {
            try actionSequence.recordExactTargetLeaf(
                outcome: result.outcome,
                targetIdentity: nil,
                operation: "Paste hotkey",
                receiptlessStep: .dispatched(
                    route: route,
                    delivery: .init(mechanism: .globalEvents, mode: .foreground),
                    unitCount: .one
                )
            )
        }
    }

    private func preservingPasteSequence<T: Sendable>(
        _ actionSequence: CommandActionSequenceAccumulator,
        route: DesktopActionOutcome.Route,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw self.preservedPasteFailure(error, sequence: actionSequence, route: route)
        }
    }

    private func preservedPasteFailure(
        _ error: any Error,
        sequence: CommandActionSequenceAccumulator,
        route: DesktopActionOutcome.Route
    ) -> any Error {
        sequence.preservingFailure(
            error,
            fallbackRoute: route,
            message: error.localizedDescription,
            hint: "Observe the target and clipboard before deciding whether to retry the paste."
        )
    }

    private func postDispatchPasteFailure(
        _ error: ClipboardPasteOutcomeError,
        target: UIAutomationTarget,
        route: DesktopActionOutcome.Route
    ) -> DesktopActionFailure {
        let delivery = Self.pasteDelivery(for: target)
        let failure: DesktopActionFailure = switch error.kind {
        case .unverified:
            .dispatchedUnverified(
                route: route,
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: .one,
                message: error.localizedDescription,
                hint: "Observe the exact target before deciding how to continue.",
                causeDescription: error.causeDescription
            )
        case .indeterminate:
            .indeterminate(
                route: route,
                delivery: delivery,
                evidence: .completionUnknown,
                unitCount: .one,
                message: error.localizedDescription,
                hint: "Observe the exact target before deciding how to continue.",
                causeDescription: error.causeDescription
            )
        }
        return failure.attributed(to: Self.pasteTargetReceipt(for: target))
    }

    private func ensureForegroundFocus(
        recordingIn actionSequence: CommandActionSequenceAccumulator,
        route _: DesktopActionOutcome.Route
    ) async throws {
        guard let focusResult = try await ensureConfirmedForegroundFocus(
            snapshotId: nil,
            target: self.target,
            options: self.focusOptions,
            services: self.services,
            operation: "Paste setup focus"
        ) else { return }
        try actionSequence.record(focusResult, operation: "Paste setup focus")
    }

    private static func outputOutcome(
        _ actionOutcome: DesktopActionOutcome?,
        mutationDisposition: DesktopActionMutationDisposition,
        restoreErrorDescription: String?,
        fallbackRoute: DesktopActionOutcome.Route
    ) -> DesktopActionOutcome? {
        guard restoreErrorDescription != nil else { return actionOutcome }
        guard mutationDisposition.mutationDispatched else { return actionOutcome }
        let route = actionOutcome?.route ?? fallbackRoute
        switch mutationDisposition {
        case .none:
            return actionOutcome
        case .definite:
            if let delivery = actionOutcome?.delivery {
                return .partial(
                    route: route,
                    delivery: delivery,
                    unitCount: mutationDisposition.unitCount
                )
            }
            return .indeterminate(
                route: route,
                evidence: .completionUnknown,
                unitCount: mutationDisposition.unitCount
            )
        case .possible:
            return .indeterminate(
                route: route,
                delivery: actionOutcome?.delivery,
                evidence: .completionUnknown,
                unitCount: mutationDisposition.unitCount
            )
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
            throw self.preDispatchActionError(
                for: ValidationError("Could not verify process identity for --pid \(pid)."),
                reason: .targetUnavailable
            )
        }
        return identity
    }

    private func verifiedBackgroundTarget(
        expectedPIDIdentity: UInt64? = nil
    ) async throws -> UIAutomationTarget? {
        if self.focusOptions.foreground {
            try self.validateExplicitPIDIdentity(expectedPIDIdentity)
            return nil
        }

        let plannedTarget = try await KeyboardDeliverySupport.requireBackgroundKeyboardTarget(
            target: self.target,
            snapshotId: nil,
            services: self.services
        )
        guard let processIdentifier = plannedTarget.processIdentifier else {
            throw ValidationError("Background paste requires a resolved target process.")
        }
        if self.target.pid != nil {
            guard let expectedPIDIdentity,
                  ClipboardPasteTransactionGate.processStartIdentity(processIdentifier) == expectedPIDIdentity
            else {
                throw ValidationError("Target process PID \(processIdentifier) changed identity while waiting.")
            }
        }
        if plannedTarget.exactWindow != nil {
            do {
                _ = try ExactWindowKeyboardRuntime.requireOutcomeProvider(
                    automation: self.services.automation,
                    operation: "Exact-window paste"
                )
            } catch {
                throw PreDispatchActionError(
                    message: error.localizedDescription,
                    code: .INTERACTION_FAILED,
                    hint: "Update the Peekaboo host and retry with a fresh exact-window target.",
                    reason: .runtimeIncompatible
                )
            }
            guard self.services.automation is any TargetedFocusedElementServiceProtocol else {
                throw PreDispatchActionError(
                    message: "This automation host does not support focused exact-window background paste.",
                    code: .INTERACTION_FAILED,
                    hint: "Update the Peekaboo host and retry with a fresh exact-window target.",
                    reason: .runtimeIncompatible
                )
            }
            return try await plannedTarget.pinningCurrentFocusedElement(using: self.services.automation)
        }
        return plannedTarget
    }

    private func preDispatchBackgroundTarget(
        expectedPIDIdentity: UInt64? = nil
    ) async throws -> UIAutomationTarget? {
        do {
            return try await self.verifiedBackgroundTarget(expectedPIDIdentity: expectedPIDIdentity)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw self.preDispatchActionError(for: error, reason: .targetUnavailable)
        }
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
    let targetWindowID: Int?
}

private struct CurrentClipboardPasteOutcome: Sendable {
    let clipboard: ClipboardReadResult?
    let targetPID: pid_t?
    let targetWindowID: Int?
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
    let targetWindowID: Int?
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
                    Background paste requires an exact window selector, or an app/PID with at most
                    one eligible window. Add --foreground for intentional foreground/global paste.

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
                      peekaboo paste --text \"Hello\" --app TextEdit --window-title \"Untitled\"
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
