import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation
import UniformTypeIdentifiers

/// Pastes text through background typing when targeted, otherwise uses clipboard + Cmd+V.
@available(macOS 14.0, *)
@MainActor
struct PasteCommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
    @Argument(help: "Text to paste")
    var text: String?

    @Option(name: .customLong("text"), help: "Text to paste (alternative to positional argument)")
    var textOption: String?

    @Option(name: .long, help: "Path to file to paste (copies file bytes into clipboard first)")
    var filePath: String?

    @Option(name: .long, help: "Path to image to paste (alias of file-path)")
    var imagePath: String?

    @Option(name: .long, help: "Base64 data to paste")
    var dataBase64: String?

    @Option(name: .long, help: "UTI for base64 payload or to force type")
    var uti: String?

    @Option(name: .long, help: "Optional plain-text companion when setting binary")
    var alsoText: String?

    @Flag(name: .long, help: "Allow payloads larger than 10 MB")
    var allowLarge = false

    @Option(name: .customLong("restore-delay-ms"), help: "Delay before restoring the previous clipboard (ms)")
    var restoreDelayMs: Int = 150

    @OptionGroup var target: InteractionTargetOptions
    @OptionGroup var focusOptions: FocusCommandOptions
    @Flag(help: "Focus target and send foreground/global Cmd+V")
    var foreground = false

    @RuntimeStorage private var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    private var resolvedRuntime: CommandRuntime {
        guard let runtime else {
            preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
        }
        return runtime
    }

    private var services: any PeekabooServiceProviding {
        self.resolvedRuntime.services
    }

    private var logger: Logger {
        self.resolvedRuntime.logger
    }

    var outputLogger: Logger {
        self.logger
    }

    var jsonOutput: Bool {
        self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput
    }

    private var resolvedText: String? {
        if let primary = self.text, !primary.isEmpty {
            return primary
        }
        return self.textOption
    }

    private var hasExplicitPayload: Bool {
        // Any payload source OR payload-modifier flag counts: `paste --uti public.rtf`
        // or `paste --allow-large` without data must fail validation, not silently
        // paste the current clipboard. An explicitly provided empty positional ("")
        // is also an explicit payload. Only targeting/focus/delivery flags may
        // combine with the bare-paste path. restoreDelayMs uses its default as the
        // "not provided" proxy since Commander cannot distinguish an explicit 150.
        self.text != nil || self.textOption != nil || self.filePath != nil || self.imagePath != nil
            || self.dataBase64 != nil || self.uti != nil || self.alsoText != nil
            || self.allowLarge || self.restoreDelayMs != 150
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            try self.target.validate()
            try KeyboardDeliverySupport.validateForegroundFlags(
                foreground: self.foreground,
                focusOptions: self.focusOptions
            )

            let targetPID = try await self.backgroundProcessIdentifier()
            guard self.hasExplicitPayload else {
                try await self.pasteCurrentClipboard(targetPID: targetPID)
                return
            }

            let request = try self.makeWriteRequest()
            if let targetPID,
               let text = self.resolvedText {
                try await self.pasteTextInBackground(text, request: request, targetPID: targetPID)
                return
            }

            self.resolvedRuntime.beginInteractionMutation()
            if targetPID == nil {
                try await ensureFocused(
                    snapshotId: nil,
                    target: self.target,
                    options: self.focusOptions,
                    services: self.services
                )
            }

            let priorClipboard = try? self.services.clipboard.get(prefer: nil)
            let restoreSlot = "paste-\(UUID().uuidString)"

            if priorClipboard != nil {
                try self.services.clipboard.save(slot: restoreSlot)
            }

            var restoreResult: ClipboardReadResult?
            var restoreErrorDescription: String?
            var restorePending = true

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

            let setResult = try self.services.clipboard.set(request)

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
            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "paste"
            )

            do {
                restoreResult = try self.restoreClipboard(
                    priorClipboardPresent: priorClipboard != nil,
                    slot: restoreSlot
                )
            } catch {
                restoreErrorDescription = error.localizedDescription
                self.logger.error("Failed to restore clipboard: \(error.localizedDescription)")
            }
            restorePending = false

            let result = PasteResult(
                success: true,
                pastedUti: setResult.utiIdentifier,
                pastedSize: setResult.data.count,
                pastedTextPreview: setResult.textPreview,
                previousClipboardPresent: priorClipboard != nil,
                restoredUti: restoreResult?.utiIdentifier,
                restoredSize: restoreResult?.data.count,
                restoreSucceeded: restoreErrorDescription == nil,
                restoreError: restoreErrorDescription,
                restoreDelayMs: self.restoreDelayMs,
                deliveryMode: targetPID == nil ? KeyboardDeliveryMode.foreground.rawValue :
                    KeyboardDeliveryMode.background.rawValue,
                targetPID: targetPID.map(Int.init)
            )

            self.output(result) {
                if restoreErrorDescription != nil {
                    print("⚠️  Pasted, but clipboard restoration failed. Do not retry the paste; " +
                        "the previous clipboard contents may be unavailable.")
                } else {
                    print("✅ Pasted and restored clipboard")
                }
                print("📋 Pasted: \(setResult.utiIdentifier) (\(setResult.data.count) bytes)")
                if let restoreErrorDescription {
                    print("♻️  Restore error: \(restoreErrorDescription)")
                } else if priorClipboard != nil {
                    print("♻️  Restored: \(restoreResult?.utiIdentifier ?? "unknown")")
                } else {
                    print("🧹 Restored: cleared (prior clipboard empty)")
                }
                if let targetPID {
                    print("🎯 Mode: background to PID \(targetPID)")
                }
            }
        } catch {
            self.handleError(error)
            throw ExitCode.failure
        }
    }

    private func pasteTextInBackground(
        _ text: String,
        request: ClipboardWriteRequest,
        targetPID: pid_t
    ) async throws {
        let setResult = try Self.readResult(for: request)
        self.resolvedRuntime.beginInteractionMutation()
        _ = try await AutomationServiceBridge.typeActions(
            automation: self.services.automation,
            request: TypeActionsRequest(
                actions: [.text(text)],
                cadence: .fixed(milliseconds: 0),
                snapshotId: nil
            ),
            targetProcessIdentifier: targetPID
        )
        await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: self.resolvedRuntime.interactionMutationTargets,
            logger: self.logger,
            reason: "paste"
        )

        let result = PasteResult(
            success: true,
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
        if self.restoreDelayMs > 0 {
            usleep(useconds_t(self.restoreDelayMs) * 1000)
        }
        guard priorClipboardPresent else {
            self.services.clipboard.clear()
            return nil
        }
        return try self.services.clipboard.restore(slot: slot)
    }

    private func makeWriteRequest() throws -> ClipboardWriteRequest {
        if let text = self.resolvedText {
            return try ClipboardPayloadBuilder.textRequest(
                text: text,
                alsoText: nil,
                allowLarge: self.allowLarge
            )
        }

        if let path = self.filePath ?? self.imagePath {
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

        throw ValidationError("Provide text, --file-path/--image-path, or --data-base64 with --uti")
    }

    private func pasteCurrentClipboard(targetPID: pid_t?) async throws {
        let currentClipboard = try? self.services.clipboard.get(prefer: nil)
        self.resolvedRuntime.beginInteractionMutation()
        if targetPID == nil {
            try await ensureFocused(
                snapshotId: nil,
                target: self.target,
                options: self.focusOptions,
                services: self.services
            )
        }

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

        await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: self.resolvedRuntime.interactionMutationTargets,
            logger: self.logger,
            reason: "paste"
        )

        let result = PasteResult(
            success: true,
            pastedUti: currentClipboard?.utiIdentifier ?? "current-clipboard",
            pastedSize: currentClipboard?.data.count ?? 0,
            // Never echo ambient clipboard content into structured output: the
            // user did not supply it to this command, and JSON lands in agent/CI
            // logs. Explicit-payload pastes still report the preview the caller
            // provided themselves.
            pastedTextPreview: nil,
            previousClipboardPresent: currentClipboard != nil,
            restoredUti: nil,
            restoredSize: nil,
            restoreSucceeded: true,
            restoreError: nil,
            restoreDelayMs: 0,
            deliveryMode: targetPID == nil ? KeyboardDeliveryMode.foreground.rawValue :
                KeyboardDeliveryMode.background.rawValue,
            targetPID: targetPID.map(Int.init)
        )

        self.output(result) {
            print("✅ Pasted current clipboard")
            if let targetPID {
                print("🎯 Mode: background to PID \(targetPID)")
            } else {
                print("🎯 Mode: foreground")
            }
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

    private static func makePreview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let max = 80
        guard trimmed.count > max else { return trimmed }
        let head = trimmed.prefix(max)
        return "\(head)..."
    }

    private func backgroundProcessIdentifier() async throws -> pid_t? {
        guard !KeyboardDeliverySupport.shouldUseForeground(
            foreground: self.foreground,
            focusOptions: self.focusOptions
        ) else {
            return nil
        }

        return try await KeyboardDeliverySupport.backgroundProcessIdentifier(
            target: self.target,
            snapshotId: nil,
            services: self.services
        )
    }
}

struct PasteResult: Codable {
    let success: Bool
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
                    Target flags send process-targeted Cmd+V when possible; otherwise it uses
                    the focused target/global foreground delivery.

                    This command reduces drift in automation flows by collapsing:
                      1) clipboard set
                      2) paste delivery
                      3) clipboard restore
                    into one operation when you provide text, a file, an image, or base64 data.
                    Background text delivery is used by default when a target process is known;
                    binary payloads use background Cmd+V. Add --foreground for focused/global paste.

                    EXAMPLES:
                      peekaboo paste
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
