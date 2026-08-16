import Foundation
import MCP
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP
import UniformTypeIdentifiers

/// MCP tool for reading and writing the macOS clipboard.
public struct ClipboardTool: MCPTool {
    public let name = "clipboard"
    private let context: MCPToolContext

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    public var description: String {
        """
        Work with the macOS clipboard (pasteboard). Actions: get, set, clear, save, restore.
        - get: read the clipboard; optionally prefer a UTI and/or write binary data to a filesystem path.
          MCP stdout is reserved for JSON-RPC, so outputPath '-' is rejected.
        - set: write text, file, image, or base64+UTI data to the clipboard (optionally also set plain text).
        - clear: empty the clipboard.
        - save/restore: snapshot and restore clipboard contents to/from a named slot (default slot \"0\").
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "action": SchemaBuilder.string(
                    description: "Action to perform",
                    enum: ["get", "set", "clear", "save", "restore"]),
                "text": SchemaBuilder.string(description: "Plain text to set on the clipboard"),
                "file_path": SchemaBuilder.string(description: "Path to a file to copy (binary or text)"),
                "data_base64": SchemaBuilder.string(description: "Base64-encoded data to copy"),
                "uti": SchemaBuilder.string(description: "Uniform Type Identifier for data_base64 or to force type"),
                "prefer": SchemaBuilder.string(description: "Preferred UTI when reading clipboard"),
                "outputPath": SchemaBuilder
                    .string(description: "When reading, filesystem path to write binary data. " +
                        "The '-' stdout sentinel is not supported because MCP stdout carries JSON-RPC; " +
                        "omit outputPath to receive UTF-8 text in the tool response."),
                "slot": SchemaBuilder.string(description: "Save/restore slot name (default: \"0\")"),
                "alsoText": SchemaBuilder.string(description: "Optional plain text companion when setting binary data"),
                "allowLarge": SchemaBuilder.boolean(description: "Allow writes larger than the 10 MB guard"),
            ],
            required: ["action"])
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        guard let action = arguments.getString("action") else {
            return ToolResponse.error("Missing required parameter: action")
        }

        do {
            switch action {
            case "get":
                return try self.handleGet(arguments: arguments)
            case "set":
                return try self.handleSet(arguments: arguments)
            case "clear":
                return try self.handleClear()
            case "save":
                return try self.handleSave(arguments: arguments)
            case "restore":
                return try self.handleRestore(arguments: arguments)
            default:
                return ToolResponse.error("Invalid action: \(action)")
            }
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil)
        } catch {
            return ToolResponse.error(error.localizedDescription)
        }
    }

    // MARK: - Actions

    @MainActor
    private func handleGet(arguments: ToolArguments) throws -> ToolResponse {
        if arguments.getString("outputPath") == "-" {
            return ToolResponse.error(
                "outputPath '-' is not supported by the MCP clipboard tool because stdout carries JSON-RPC " +
                    "messages. Omit outputPath to receive UTF-8 clipboard text in the tool response, or provide " +
                    "a filesystem path for binary data.",
                meta: .object([
                    "effect": .string("refused"),
                    "error_code": .string("MCP_CLIPBOARD_STDOUT_UNAVAILABLE"),
                    "mutation_dispatched": .bool(false),
                    "retry_safe": .bool(true),
                ]))
        }

        let preferUTI = arguments.getString("prefer").flatMap { UTType($0) }
        guard let result = try self.context.clipboard.get(prefer: preferUTI) else {
            return ToolResponse.error("Clipboard is empty.")
        }

        let outputPath = arguments.getString("outputPath")
        if let outputPath {
            let resolvedPath = ClipboardPathResolver.filePath(from: outputPath) ?? outputPath
            let url = ClipboardPathResolver.fileURL(from: resolvedPath)
            try result.data.write(to: url)
            return ToolResponse.text(
                "Saved clipboard (\(result.utiIdentifier)) to \(resolvedPath)",
                meta: self.meta(result: result, filePath: resolvedPath))
        }

        if let text = String(data: result.data, encoding: .utf8) {
            return ToolResponse.text(
                text,
                meta: self.meta(result: result, filePath: nil))
        }

        return ToolResponse.text(
            "Clipboard contains \(result.data.count) bytes of \(result.utiIdentifier). Provide outputPath to save.",
            meta: self.meta(result: result, filePath: nil))
    }

    @MainActor
    private func handleSet(arguments: ToolArguments) throws -> ToolResponse {
        let request: ClipboardWriteRequest
        do {
            request = try self.makeWriteRequest(arguments: arguments)
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Clipboard set was refused before dispatch.",
                hint: "Provide text, file_path, or data_base64+uti with valid data.",
                causeDescription: error.localizedDescription)
        }
        let actionResult = try self.context.clipboard.setResult(request)
        let outcome = try ClipboardMutationResultSemantics.requireSuccessfulOutcome(
            actionResult.outcome,
            operation: "Clipboard set")
        do {
            return try ToolResponse.text(
                "Set clipboard (\(actionResult.payload.utiIdentifier), \(actionResult.payload.data.count) bytes)",
                meta: MCPToolResponseMetadataProjector.metadata(
                    merging: self.metaFields(result: actionResult.payload, filePath: nil),
                    outcome: outcome))
        } catch {
            throw ClipboardMutationResultSemantics.postWriteFailure(error, operation: "Clipboard set")
        }
    }

    @MainActor
    private func handleClear() throws -> ToolResponse {
        let actionResult = try self.context.clipboard.clearResult()
        let outcome = try ClipboardMutationResultSemantics.requireSuccessfulOutcome(
            actionResult.outcome,
            operation: "Clipboard clear")
        do {
            return try ToolResponse.text(
                "Cleared clipboard.",
                meta: MCPToolResponseMetadataProjector.metadata(outcome: outcome))
        } catch {
            throw ClipboardMutationResultSemantics.postWriteFailure(error, operation: "Clipboard clear")
        }
    }

    @MainActor
    private func handleSave(arguments: ToolArguments) throws -> ToolResponse {
        let slot = arguments.getString("slot") ?? "0"
        try self.context.clipboard.save(slot: slot)
        return ToolResponse.text("Saved clipboard to slot \"\(slot)\".", meta: .object(["slot": .string(slot)]))
    }

    @MainActor
    private func handleRestore(arguments: ToolArguments) throws -> ToolResponse {
        let slot = arguments.getString("slot") ?? "0"
        let actionResult = try self.context.clipboard.restoreResult(slot: slot)
        let outcome = try ClipboardMutationResultSemantics.requireSuccessfulOutcome(
            actionResult.outcome,
            operation: "Clipboard restore")
        do {
            return try ToolResponse.text(
                "Restored clipboard from slot \"\(slot)\" " +
                    "(\(actionResult.payload.utiIdentifier), \(actionResult.payload.data.count) bytes).",
                meta: MCPToolResponseMetadataProjector.metadata(
                    merging: self.metaFields(
                        result: actionResult.payload,
                        filePath: nil,
                        extra: ["slot": .string(slot)]),
                    outcome: outcome))
        } catch {
            throw ClipboardMutationResultSemantics.postWriteFailure(error, operation: "Clipboard restore")
        }
    }

    // MARK: - Helpers

    private func makeWriteRequest(arguments: ToolArguments) throws -> ClipboardWriteRequest {
        if let text = arguments.getString("text") {
            return try ClipboardPayloadBuilder.textRequest(
                text: text,
                alsoText: arguments.getString("alsoText"),
                allowLarge: arguments.getBool("allowLarge") ?? false)
        }

        if let filePath = arguments.getString("file_path") {
            let url = ClipboardPathResolver.fileURL(from: filePath)
            let data = try Data(contentsOf: url)
            let uti = UTType(filenameExtension: url.pathExtension) ?? .data
            return ClipboardPayloadBuilder.dataRequest(
                data: data,
                uti: uti,
                alsoText: arguments.getString("alsoText"),
                allowLarge: arguments.getBool("allowLarge") ?? false)
        }

        if let b64 = arguments.getString("data_base64"), let utiId = arguments.getString("uti") {
            return try ClipboardPayloadBuilder.base64Request(
                base64: b64,
                utiIdentifier: utiId,
                alsoText: arguments.getString("alsoText"),
                allowLarge: arguments.getBool("allowLarge") ?? false)
        }

        throw ClipboardServiceError.writeFailed(
            "Provide text, file_path, or data_base64+uti to set the clipboard.")
    }

    private func meta(result: ClipboardReadResult, filePath: String?, extra: [String: Value] = [:]) -> Value {
        .object(self.metaFields(result: result, filePath: filePath, extra: extra))
    }

    private func metaFields(
        result: ClipboardReadResult,
        filePath: String?,
        extra: [String: Value] = [:]) -> [String: Value]
    {
        var object: [String: Value] = [
            "uti": .string(result.utiIdentifier),
            "size": .int(result.data.count),
        ]
        if let preview = result.textPreview {
            object["textPreview"] = .string(preview)
        }
        if let filePath {
            object["filePath"] = .string(filePath)
        }
        for (key, value) in extra {
            object[key] = value
        }
        return object
    }
}
