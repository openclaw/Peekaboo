import Commander
import Foundation
import PeekabooCore
import UniformTypeIdentifiers

@available(macOS 14.0, *)
@MainActor
struct ClipboardCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "clipboard",
                abstract: "Read and write the macOS clipboard",
                subcommands: [
                    GetSubcommand.self,
                    SetSubcommand.self,
                    ClearSubcommand.self,
                    SaveSubcommand.self,
                    RestoreSubcommand.self,
                ],
                showHelpOnEmptyInvocation: true
            )
        }
    }
}

@available(macOS 14.0, *)
extension ClipboardCommand {
    @MainActor
    struct GetSubcommand: RuntimeBackedCommand {
        static let commandDescription = CommandDescription(commandName: "get", abstract: "Read the clipboard")

        @Option(name: .long, help: "Preferred UTI when reading clipboard")
        var prefer: String?

        @Option(name: .shortAndLong, help: "Output path for binary reads ('-' for stdout)")
        var output: String?

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                let preferType = self.prefer.flatMap { UTType($0) }
                guard let result = try self.services.clipboard.get(prefer: preferType) else {
                    throw ValidationError("Clipboard is empty")
                }

                let text = result.textPreview.flatMap { _ in String(data: result.data, encoding: .utf8) }
                let dataBase64 = self.jsonOutput && self.output == "-" && text == nil
                    ? result.data.base64EncodedString()
                    : nil
                let resolvedOutput = self.output.flatMap {
                    $0 == "-" ? $0 : ClipboardPathResolver.filePath(from: $0)
                }
                if let output = resolvedOutput, output != "-" {
                    try result.data.write(to: ClipboardPathResolver.fileURL(from: output))
                } else if resolvedOutput == "-", !self.jsonOutput {
                    FileHandle.standardOutput.write(result.data)
                }

                let payload = ClipboardCommandResult(
                    action: "get",
                    uti: result.utiIdentifier,
                    size: result.data.count,
                    filePath: resolvedOutput,
                    slot: nil,
                    text: text,
                    textPreview: result.textPreview,
                    dataBase64: dataBase64,
                    verification: nil
                )
                self.output(payload) {
                    if resolvedOutput == "-" {
                        return
                    }
                    if let text = String(data: result.data, encoding: .utf8) {
                        print(text)
                    } else if let output = resolvedOutput {
                        print("📋 Saved \(result.data.count) bytes (\(result.utiIdentifier)) to \(output)")
                    } else {
                        print(
                            "📋 Clipboard contains \(result.data.count) bytes of \(result.utiIdentifier); " +
                                "use --output to save."
                        )
                    }
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }

    @MainActor
    struct SetSubcommand: RuntimeBackedCommand {
        static let commandDescription = CommandDescription(commandName: "set", abstract: "Write the clipboard")

        @Option(name: .long, help: "Text to set")
        var text: String?

        @Option(name: .long, help: "Path to file to copy")
        var filePath: String?

        @Option(name: .long, help: "Base64 data to copy")
        var dataBase64: String?

        @Option(name: .long, help: "UTI for base64 payload or to force type")
        var uti: String?

        @Option(name: .long, help: "Optional plain-text companion when setting binary")
        var alsoText: String?

        @Flag(name: .long, help: "Allow payloads larger than 10 MB")
        var allowLarge = false

        @Flag(name: .long, help: "Read back clipboard after setting and validate contents")
        var verify = false

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                let request = try makeClipboardWriteRequest(from: self)
                self.resolvedRuntime.beginInteractionMutation()
                let actionResult = try self.services.clipboard.setResult(request)
                let outcome = try ClipboardMutationResultSemantics.requireSuccessfulOutcome(
                    actionResult.outcome,
                    operation: "Clipboard set"
                )
                let verification: ClipboardVerifyResult?
                do {
                    verification = try verifyClipboardWriteIfNeeded(
                        request: request,
                        verify: self.verify,
                        clipboard: self.services.clipboard
                    )
                } catch {
                    throw ClipboardMutationResultSemantics.postWriteFailure(error, operation: "Clipboard set")
                }
                let payload = ClipboardCommandResult(
                    action: "set",
                    uti: actionResult.payload.utiIdentifier,
                    size: actionResult.payload.data.count,
                    filePath: nil,
                    slot: nil,
                    text: nil,
                    textPreview: actionResult.payload.textPreview,
                    dataBase64: nil,
                    verification: verification
                )
                self.output(payload, outcome: outcome) {
                    print(
                        "✅ Set clipboard " +
                            "(\(actionResult.payload.utiIdentifier), \(actionResult.payload.data.count) bytes)"
                    )
                    printClipboardVerificationSummary(verification)
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }

    @MainActor
    struct ClearSubcommand: RuntimeBackedCommand {
        static let commandDescription = CommandDescription(commandName: "clear", abstract: "Empty the clipboard")
        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                self.resolvedRuntime.beginInteractionMutation()
                let actionResult = try self.services.clipboard.clearResult()
                let outcome = try ClipboardMutationResultSemantics.requireSuccessfulOutcome(
                    actionResult.outcome,
                    operation: "Clipboard clear"
                )
                let payload = ClipboardCommandResult(
                    action: "clear",
                    uti: nil,
                    size: nil,
                    filePath: nil,
                    slot: nil,
                    text: nil,
                    textPreview: nil,
                    dataBase64: nil,
                    verification: nil
                )
                self.output(payload, outcome: outcome) {
                    print("🧹 Cleared clipboard")
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }

    @MainActor
    struct SaveSubcommand: RuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "save",
            abstract: "Save the clipboard to a named slot"
        )

        @Option(name: .long, help: "Slot name (default: 0)")
        var slot: String?

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                let slotName = self.slot ?? "0"
                try self.services.clipboard.save(slot: slotName)
                let payload = ClipboardCommandResult(
                    action: "save",
                    uti: nil,
                    size: nil,
                    filePath: nil,
                    slot: slotName,
                    text: nil,
                    textPreview: nil,
                    dataBase64: nil,
                    verification: nil
                )
                self.output(payload) {
                    print("💾 Saved clipboard to slot \"\(slotName)\"")
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }

    @MainActor
    struct RestoreSubcommand: RuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "restore",
            abstract: "Restore the clipboard from a named slot"
        )

        @Option(name: .long, help: "Slot name (default: 0)")
        var slot: String?

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                self.resolvedRuntime.beginInteractionMutation()
                let slotName = self.slot ?? "0"
                let actionResult = try self.services.clipboard.restoreResult(slot: slotName)
                let outcome = try ClipboardMutationResultSemantics.requireSuccessfulOutcome(
                    actionResult.outcome,
                    operation: "Clipboard restore"
                )
                let payload = ClipboardCommandResult(
                    action: "restore",
                    uti: actionResult.payload.utiIdentifier,
                    size: actionResult.payload.data.count,
                    filePath: nil,
                    slot: slotName,
                    text: nil,
                    textPreview: actionResult.payload.textPreview,
                    dataBase64: nil,
                    verification: nil
                )
                self.output(payload, outcome: outcome) {
                    print(
                        "♻️  Restored slot \"\(slotName)\" " +
                            "(\(actionResult.payload.utiIdentifier), \(actionResult.payload.data.count) bytes)"
                    )
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }
}

extension ClipboardCommand.GetSubcommand: AsyncRuntimeCommand, ErrorHandlingCommand, OutputFormattable {}
extension ClipboardCommand.SetSubcommand: ActionOutputFormattable, AsyncRuntimeCommand, ErrorHandlingCommand,
OutputFormattable {}
extension ClipboardCommand.ClearSubcommand: ActionOutputFormattable, AsyncRuntimeCommand, ErrorHandlingCommand,
OutputFormattable {}
extension ClipboardCommand.SaveSubcommand: AsyncRuntimeCommand, ErrorHandlingCommand, OutputFormattable {}
extension ClipboardCommand.RestoreSubcommand: ActionOutputFormattable, AsyncRuntimeCommand, ErrorHandlingCommand,
OutputFormattable {}

@MainActor
extension ClipboardCommand.GetSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.prefer = values.singleOption("prefer")
        self.output = values.singleOption("output")
    }
}

@MainActor
extension ClipboardCommand.SetSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.text = values.singleOption("text")
        self.filePath = values.singleOption("filePath")
        self.dataBase64 = values.singleOption("dataBase64")
        self.uti = values.singleOption("uti")
        self.alsoText = values.singleOption("alsoText")
        self.allowLarge = values.flag("allowLarge")
        self.verify = values.flag("verify")
    }
}

@MainActor
extension ClipboardCommand.ClearSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        _ = values
    }
}

@MainActor
extension ClipboardCommand.SaveSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.slot = values.singleOption("slot")
    }
}

@MainActor
extension ClipboardCommand.RestoreSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.slot = values.singleOption("slot")
    }
}

@MainActor
private func makeClipboardWriteRequest(from command: ClipboardCommand.SetSubcommand) throws -> ClipboardWriteRequest {
    if let text = command.text {
        return try ClipboardPayloadBuilder.textRequest(
            text: text,
            alsoText: command.alsoText,
            allowLarge: command.allowLarge
        )
    }

    if let filePath = command.filePath {
        let url = ClipboardPathResolver.fileURL(from: filePath)
        let data = try Data(contentsOf: url)
        return ClipboardPayloadBuilder.dataRequest(
            data: data,
            uti: UTType(filenameExtension: url.pathExtension) ?? .data,
            alsoText: command.alsoText,
            allowLarge: command.allowLarge
        )
    }

    if let dataBase64 = command.dataBase64, let uti = command.uti {
        guard let data = Data(base64Encoded: dataBase64) else {
            throw ValidationError("data-base64 is not valid base64")
        }
        return ClipboardPayloadBuilder.dataRequest(
            data: data,
            utiIdentifier: uti,
            alsoText: command.alsoText,
            allowLarge: command.allowLarge
        )
    }

    throw ValidationError("Provide --text, --file-path, or --data-base64 with --uti")
}

private func verifyClipboardWriteIfNeeded(
    request: ClipboardWriteRequest,
    verify: Bool,
    clipboard: any ClipboardServiceProtocol
) throws -> ClipboardVerifyResult? {
    guard verify else { return nil }

    var verifiedTypes: [String] = []
    var skippedTypes: [String] = []
    for representation in request.representations {
        guard let preferredType = UTType(representation.utiIdentifier) else {
            skippedTypes.append(representation.utiIdentifier)
            continue
        }
        guard let readBack = try clipboard.get(prefer: preferredType) else {
            throw ValidationError("Clipboard verify failed: missing \(representation.utiIdentifier)")
        }
        guard readBack.utiIdentifier == representation.utiIdentifier else {
            throw ValidationError(
                "Clipboard verify failed: expected \(representation.utiIdentifier), got \(readBack.utiIdentifier)"
            )
        }

        if isTextClipboardUTI(representation.utiIdentifier) {
            guard let expected = normalizedClipboardTextData(representation.data),
                  let actual = normalizedClipboardTextData(readBack.data)
            else {
                throw ValidationError(
                    "Clipboard verify failed: unable to decode text for \(representation.utiIdentifier)"
                )
            }
            guard expected == actual else {
                throw ValidationError("Clipboard verify failed: text mismatch for \(representation.utiIdentifier)")
            }
        } else if readBack.data != representation.data {
            throw ValidationError("Clipboard verify failed: data mismatch for \(representation.utiIdentifier)")
        }
        verifiedTypes.append(representation.utiIdentifier)
    }

    return ClipboardVerifyResult(
        ok: true,
        verifiedTypes: verifiedTypes,
        skippedTypes: skippedTypes.isEmpty ? nil : skippedTypes
    )
}

private func printClipboardVerificationSummary(_ verification: ClipboardVerifyResult?) {
    guard let verification else { return }
    print("✅ Verified clipboard readback (\(verification.verifiedTypes.joined(separator: ", ")))")
    if let skipped = verification.skippedTypes, !skipped.isEmpty {
        print("⚠️  Skipped verify for: \(skipped.joined(separator: ", "))")
    }
}

private func isTextClipboardUTI(_ utiIdentifier: String) -> Bool {
    utiIdentifier == UTType.plainText.identifier || utiIdentifier == UTType.utf8PlainText.identifier
}

private func normalizedClipboardTextData(_ data: Data) -> Data? {
    guard let string = String(data: data, encoding: .utf8) else { return nil }
    return string
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .data(using: .utf8)
}
