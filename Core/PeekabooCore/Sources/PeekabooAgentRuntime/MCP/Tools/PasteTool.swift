import Foundation
import MCP
import os.log
import PeekabooAutomation
import TachikomaMCP
import UniformTypeIdentifiers

/// MCP tool for atomic clipboard+paste+restore.
public struct PasteTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "PasteTool")
    private let context: MCPToolContext

    public let name = "paste"

    public var description: String {
        """
        Atomically set the clipboard, paste (Cmd+V), then restore the previous clipboard.

        Use this when you want fewer steps than:
        - clipboard set
        - hotkey cmd+v
        - clipboard restore

        Targeting:
        - Provide app/pid to paste in the background, or set foreground=true for intentional global paste and window
          targeting.

        Payload:
        - text OR filePath/imagePath OR dataBase64+uti (optionally alsoText).
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                // Targeting
                "app": SchemaBuilder.string(description: "Target app name/bundle ID, or 'PID:<n>'."),
                "pid": SchemaBuilder.number(description: "Target process ID (alternative to app)."),
                "window_id": SchemaBuilder.number(description: "Window ID; requires foreground=true."),
                "window_title": SchemaBuilder
                    .string(description: "Window title (substring match); requires foreground=true."),
                "window_index": SchemaBuilder
                    .number(description: "Window index (0-based); requires app/pid and foreground=true."),

                // Payload
                "text": SchemaBuilder.string(description: "Plain text to paste."),
                "filePath": SchemaBuilder
                    .string(description: "Path to a file to paste (file bytes placed on clipboard)."),
                "imagePath": SchemaBuilder.string(description: "Path to an image to paste (alias of filePath)."),
                "dataBase64": SchemaBuilder.string(description: "Base64-encoded payload to paste."),
                "uti": SchemaBuilder.string(description: "UTI for dataBase64, or to force type when pasting a file."),
                "alsoText": SchemaBuilder.string(description: "Optional plain-text companion when pasting binary."),
                "allowLarge": SchemaBuilder.boolean(description: "Allow payloads larger than 10 MB.", default: false),

                // Restore timing
                "restore_delay_ms": SchemaBuilder.number(
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

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let startTime = Date()

        do {
            let target = MCPInteractionTarget(
                app: arguments.getString("app"),
                pid: arguments.getInt("pid"),
                windowTitle: arguments.getString("window_title"),
                windowIndex: arguments.getInt("window_index"),
                windowId: arguments.getInt("window_id"))

            let foreground = arguments.getBool("foreground") ?? false
            let targetPID = foreground ? nil : try await target.requireBackgroundProcessIdentifier(
                applications: self.context.applications,
                windows: self.context.windows)
            if targetPID == nil {
                _ = try await target.focusIfRequested(windows: self.context.windows)
            }
            let request = try self.makeWriteRequest(arguments: arguments)

            let priorClipboard = try? self.context.clipboard.get(prefer: nil)
            let restoreSlot = "paste-\(UUID().uuidString)"

            if priorClipboard != nil {
                try self.context.clipboard.save(slot: restoreSlot)
            }

            let restoreDelayMs = max(0, arguments.getInt("restore_delay_ms") ?? 150)
            var restoreResult: ClipboardReadResult?
            var restoreErrorDescription: String?
            var restorePending = true

            func restoreClipboard() throws -> ClipboardReadResult? {
                if restoreDelayMs > 0 {
                    usleep(useconds_t(restoreDelayMs) * 1000)
                }
                guard priorClipboard != nil else {
                    self.context.clipboard.clear()
                    return nil
                }
                return try self.context.clipboard.restore(slot: restoreSlot)
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

            let setResult = try self.context.clipboard.set(request)
            if let targetPID {
                guard let automation = self.context.automation as? any TargetedHotkeyServiceProtocol,
                      automation.supportsTargetedHotkeys
                else {
                    throw PasteToolError("This automation host does not support background paste delivery.")
                }
                try await automation.hotkey(keys: "cmd,v", holdDuration: 50, targetProcessIdentifier: targetPID)
            } else {
                try await self.context.automation.hotkey(keys: "cmd,v", holdDuration: 50)
            }

            do {
                restoreResult = try restoreClipboard()
            } catch {
                restoreErrorDescription = error.localizedDescription
                self.logger.error("Failed to restore clipboard: \(error.localizedDescription)")
            }
            restorePending = false

            let executionTime = Date().timeIntervalSince(startTime)
            let message = if restoreErrorDescription != nil {
                "\(AgentDisplayTokens.Status.warning) Pasted (Cmd+V), but clipboard restoration failed " +
                    "in \(String(format: "%.2f", executionTime))s. Do not retry the paste; " +
                    "the previous clipboard contents may be unavailable."
            } else {
                "\(AgentDisplayTokens.Status.success) Pasted (Cmd+V) and restored clipboard " +
                    "in \(String(format: "%.2f", executionTime))s"
            }

            let pastedObject: [String: Value] = [
                "uti": .string(setResult.utiIdentifier),
                "size": .int(setResult.data.count),
                "textPreview": setResult.textPreview.map(Value.string) ?? .null,
            ]

            let restoredUti: Value = restoreResult.map { .string($0.utiIdentifier) } ?? .null
            let restoredSize: Value = restoreResult.map { .int($0.data.count) } ?? .null
            let restoredObject: [String: Value] = [
                "uti": restoredUti,
                "size": restoredSize,
            ]

            let meta: Value = .object([
                "pasted": .object(pastedObject),
                "previous_clipboard_present": .bool(priorClipboard != nil),
                "restored": .object(restoredObject),
                "restore_succeeded": .bool(restoreErrorDescription == nil),
                "restore_error": restoreErrorDescription.map(Value.string) ?? .null,
                "restore_delay_ms": .int(restoreDelayMs),
                "execution_time": .double(executionTime),
                "delivery_mode": .string(targetPID == nil ? "foreground" : "background"),
                "target_pid": targetPID.map { .int(Int($0)) } ?? .null,
            ])

            let resolvedWindowTitle = try await target.resolveWindowTitleIfNeeded(windows: self.context.windows)
            let summary = ToolEventSummary(
                targetApp: target.appIdentifier,
                windowTitle: resolvedWindowTitle,
                actionDescription: "Paste",
                notes: setResult.utiIdentifier)

            return ToolResponse(
                content: [.text(text: message, annotations: nil, _meta: nil)],
                meta: ToolEventSummary.merge(summary: summary, into: meta))
        } catch let error as MCPInteractionTargetError {
            return ToolResponse.error(error.localizedDescription)
        } catch let error as PasteToolError {
            return ToolResponse.error(error.message)
        } catch {
            self.logger.error("Paste failed: \(error.localizedDescription)")
            return ToolResponse.error("Paste failed: \(error.localizedDescription)")
        }
    }

    private func makeWriteRequest(arguments: ToolArguments) throws -> ClipboardWriteRequest {
        if let text = arguments.getString("text"), !text.isEmpty {
            return try ClipboardPayloadBuilder.textRequest(
                text: text,
                alsoText: nil,
                allowLarge: arguments.getBool("allowLarge") ?? false)
        }

        if let filePath = arguments.getString("filePath") ?? arguments.getString("imagePath") {
            let url = ClipboardPathResolver.fileURL(from: filePath)
            let data = try Data(contentsOf: url)
            let inferred = UTType(filenameExtension: url.pathExtension) ?? .data
            let forced = arguments.getString("uti").flatMap(UTType.init(_:)) ?? inferred
            return ClipboardPayloadBuilder.dataRequest(
                data: data,
                uti: forced,
                alsoText: arguments.getString("alsoText"),
                allowLarge: arguments.getBool("allowLarge") ?? false)
        }

        if let b64 = arguments.getString("dataBase64"), let utiId = arguments.getString("uti") {
            return try ClipboardPayloadBuilder.base64Request(
                base64: b64,
                utiIdentifier: utiId,
                alsoText: arguments.getString("alsoText"),
                allowLarge: arguments.getBool("allowLarge") ?? false)
        }

        throw ClipboardServiceError.writeFailed(
            "Provide text, filePath/imagePath, or dataBase64+uti.")
    }
}

private struct PasteToolError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}
