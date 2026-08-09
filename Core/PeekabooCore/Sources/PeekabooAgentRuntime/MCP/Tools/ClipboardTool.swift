import Foundation
import MCP
import PeekabooAutomation
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
        - get: read the clipboard; optionally prefer a UTI and/or write binary data to a file.
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
                    .string(description: "When reading, path to write binary data. Use '-' for stdout."),
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
                return self.handleClear()
            case "save":
                return try self.handleSave(arguments: arguments)
            case "restore":
                return try self.handleRestore(arguments: arguments)
            default:
                return ToolResponse.error("Invalid action: \(action)")
            }
        } catch {
            return ToolResponse.error(error.localizedDescription)
        }
    }

    // MARK: - Actions

    @MainActor
    private func handleGet(arguments: ToolArguments) throws -> ToolResponse {
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
        let request = try self.makeWriteRequest(arguments: arguments)
        let result = try self.context.clipboard.set(request)
        return ToolResponse.text(
            "Set clipboard (\(result.utiIdentifier), \(result.data.count) bytes)",
            meta: self.meta(result: result, filePath: nil))
    }

    @MainActor
    private func handleClear() -> ToolResponse {
        self.context.clipboard.clear()
        return ToolResponse.text("Cleared clipboard.")
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
        let result = try self.context.clipboard.restore(slot: slot)
        return ToolResponse.text(
            "Restored clipboard from slot \"\(slot)\" (\(result.utiIdentifier), \(result.data.count) bytes).",
            meta: self.meta(result: result, filePath: nil, extra: ["slot": .string(slot)]))
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
        return .object(object)
    }
}
