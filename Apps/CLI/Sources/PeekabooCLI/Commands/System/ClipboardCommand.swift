import Commander
import Foundation
import PeekabooCore
import UniformTypeIdentifiers

@available(macOS 14.0, *)
@MainActor
struct ClipboardActionCommand: ActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
RuntimeOptionsConfigurable {
    var action: String?
    var actionOption: String?

    @Option(name: .long, help: "Text to set")
    var text: String?

    @Option(name: .long, help: "Path to file to copy")
    var filePath: String?

    @Option(name: .long, help: "Base64 data to copy")
    var dataBase64: String?

    @Option(name: .long, help: "UTI for base64 payload or to force type")
    var uti: String?

    @Option(name: .long, help: "Preferred UTI when reading clipboard")
    var prefer: String?

    @Option(name: .shortAndLong, help: "Output path for binary reads ('-' for stdout)")
    var output: String?

    @Option(name: .long, help: "Slot name for save/restore (default: 0)")
    var slot: String?

    @Option(name: .long, help: "Optional plain-text companion when setting binary")
    var alsoText: String?

    @Flag(name: .long, help: "Allow payloads larger than 10 MB")
    var allowLarge = false

    @Flag(name: .long, help: "Read back clipboard after setting and validate contents")
    var verify = false

    @RuntimeStorage private var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    private var resolvedRuntime: CommandRuntime {
        guard let runtime else { preconditionFailure("CommandRuntime must be configured") }
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

    private var configuration: CommandRuntime.Configuration {
        if let runtime {
            runtime.configuration
        } else {
            self.runtimeOptions.makeConfiguration()
        }
    }

    var jsonOutput: Bool {
        self.configuration.jsonOutput
    }

    var defaultEffect: ActionEffect? {
        let action = (self.action ?? self.actionOption)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.actionMayMutate(action) else { return nil }
        return .unverifiable
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            let action = try self.resolvedAction()
            if Self.actionMayMutate(action) {
                self.resolvedRuntime.beginInteractionMutation()
            }
            switch action.lowercased() {
            case "get":
                try self.handleGet()
            case "set":
                try self.handleSet()
            case "clear":
                self.handleClear()
            case "save":
                try self.handleSave()
            case "restore":
                try self.handleRestore()
            default:
                throw ValidationError("Invalid action: \(action)")
            }
        } catch {
            self.handleError(error)
            throw ExitCode.failure
        }
    }

    // MARK: - Actions

    static func actionMayMutate(_ action: String?) -> Bool {
        guard let action = action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["set", "clear", "restore"].contains(action)
    }

    private func resolvedAction() throws -> String {
        let positionalAction = self.action?.trimmingCharacters(in: .whitespacesAndNewlines)
        let optionAction = self.actionOption?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (positionalAction, optionAction) {
        case let (positional?, option?) where !positional.isEmpty && !option.isEmpty && positional != option:
            throw ValidationError("Conflicting clipboard actions")
        case let (positional?, _) where !positional.isEmpty:
            return positional
        case let (_, option?) where !option.isEmpty:
            return option
        default:
            throw ValidationError("Missing clipboard action")
        }
    }

    private func handleGet() throws {
        let preferType = self.prefer.flatMap { UTType($0) }
        guard let result = try self.services.clipboard.get(prefer: preferType) else {
            throw ValidationError("Clipboard is empty")
        }

        let text = result.textPreview.flatMap { _ in String(data: result.data, encoding: .utf8) }
        let dataBase64 = self.jsonOutput && self.output == "-" && text == nil
            ? result.data.base64EncodedString()
            : nil

        let resolvedOutput = self.output.flatMap { $0 == "-" ? $0 : ClipboardPathResolver.filePath(from: $0) }
        if let output = resolvedOutput, output != "-" {
            let url = ClipboardPathResolver.fileURL(from: output)
            try result.data.write(to: url)
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
                    "📋 Clipboard contains \(result.data.count) bytes of \(result.utiIdentifier); use --output to save."
                )
            }
        }
    }

    private func handleSet() throws {
        let request = try self.makeWriteRequest()
        let result = try self.services.clipboard.set(request)
        let verification = try self.verifyWriteIfNeeded(request: request)
        let payload = ClipboardCommandResult(
            action: "set",
            uti: result.utiIdentifier,
            size: result.data.count,
            filePath: nil,
            slot: nil,
            text: nil,
            textPreview: result.textPreview,
            dataBase64: nil,
            verification: verification
        )

        self.output(payload, effect: verification == nil ? .unverifiable : .confirmed) {
            print("✅ Set clipboard (\(result.utiIdentifier), \(result.data.count) bytes)")
            self.printVerificationSummary(verification)
        }
    }

    private func handleClear() {
        self.services.clipboard.clear()
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
        self.output(payload) {
            print("🧹 Cleared clipboard")
        }
    }

    private func handleSave() throws {
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
    }

    private func handleRestore() throws {
        let slotName = self.slot ?? "0"
        let result = try self.services.clipboard.restore(slot: slotName)
        let payload = ClipboardCommandResult(
            action: "restore",
            uti: result.utiIdentifier,
            size: result.data.count,
            filePath: nil,
            slot: slotName,
            text: nil,
            textPreview: result.textPreview,
            dataBase64: nil,
            verification: nil
        )
        self.output(payload) {
            print("♻️  Restored slot \"\(slotName)\" (\(result.utiIdentifier), \(result.data.count) bytes)")
        }
    }

    // MARK: - Helpers

    private func makeWriteRequest(overridePath: String? = nil) throws -> ClipboardWriteRequest {
        if let text {
            return try ClipboardPayloadBuilder.textRequest(
                text: text,
                alsoText: self.alsoText,
                allowLarge: self.allowLarge
            )
        }

        if let path = overridePath ?? self.filePath {
            let url = ClipboardPathResolver.fileURL(from: path)
            let data = try Data(contentsOf: url)
            let uti = UTType(filenameExtension: url.pathExtension) ?? .data
            return ClipboardPayloadBuilder.dataRequest(
                data: data,
                uti: uti,
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

        throw ValidationError("Provide --text, --file-path, or --data-base64 with --uti")
    }

    private func verifyWriteIfNeeded(request: ClipboardWriteRequest) throws -> ClipboardVerifyResult? {
        guard self.verify else { return nil }

        var verifiedTypes: [String] = []
        var skippedTypes: [String] = []

        for representation in request.representations {
            guard let preferredType = UTType(representation.utiIdentifier) else {
                skippedTypes.append(representation.utiIdentifier)
                continue
            }

            guard let readBack = try self.services.clipboard.get(prefer: preferredType) else {
                throw ValidationError("Clipboard verify failed: missing \(representation.utiIdentifier)")
            }

            guard readBack.utiIdentifier == representation.utiIdentifier else {
                throw ValidationError(
                    "Clipboard verify failed: expected \(representation.utiIdentifier), got \(readBack.utiIdentifier)"
                )
            }

            if Self.isTextUTI(representation.utiIdentifier) {
                guard let expected = Self.normalizedTextData(representation.data),
                      let actual = Self.normalizedTextData(readBack.data) else {
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

    private func printVerificationSummary(_ verification: ClipboardVerifyResult?) {
        guard let verification else { return }
        let types = verification.verifiedTypes.joined(separator: ", ")
        print("✅ Verified clipboard readback (\(types))")
        if let skipped = verification.skippedTypes, !skipped.isEmpty {
            print("⚠️  Skipped verify for: \(skipped.joined(separator: ", "))")
        }
    }

    private static func isTextUTI(_ utiIdentifier: String) -> Bool {
        utiIdentifier == UTType.plainText.identifier || utiIdentifier == UTType.utf8PlainText.identifier
    }

    private static func normalizedTextData(_ data: Data) -> Data? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        let normalized = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
            of: "\r",
            with: "\n"
        )
        return normalized.data(using: .utf8)
    }
}
