import Foundation
import MCP
import os.log
import PeekabooAutomation
import TachikomaMCP

/// MCP tool for pressing keyboard shortcuts and key combinations
public struct HotkeyTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "HotkeyTool")
    private let context: MCPToolContext

    public let name = "hotkey"

    public var description: String {
        """
        Presses keyboard shortcuts.
        Simulates one primary key plus optional modifiers, like Cmd+C or Ctrl+Shift+T.
        If app/pid/window targeting is supplied, sends the hotkey to that process in the background by default.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.5, anthropic/claude-opus-4-8
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "keys": SchemaBuilder.string(
                    description: """
                    Comma-separated hotkey chord to press (e.g., 'cmd,c' for copy,
                    'cmd,shift,t' for reopen tab). Supported keys: cmd, shift,
                    alt/option, ctrl, fn, a-z, 0-9, space, return, tab, escape,
                    delete, arrow_up, arrow_down, arrow_left, arrow_right, f1-f12.
                    """),
                "hold_duration": SchemaBuilder.number(
                    description: "Optional. Delay between key press and release in milliseconds. Default: 50.",
                    minimum: 0,
                    default: 50),
                "app": SchemaBuilder.string(description: "Optional. Target app name/bundle ID, or 'PID:<n>'."),
                "pid": SchemaBuilder.number(
                    description: "Optional. Target process ID for background hotkeys."),
                "window_id": SchemaBuilder.number(description: "Optional. Window ID for background hotkeys."),
                "window_title": SchemaBuilder.string(description: "Optional. Window title (substring match)."),
                "window_index": SchemaBuilder
                    .number(description: "Optional. Window index (0-based); requires app/pid."),
                "foreground": SchemaBuilder.boolean(
                    description: "Optional. Send foreground/global hotkey even when a target is supplied.",
                    default: false),
            ],
            required: ["keys"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        // Extract required keys parameter
        guard let keys = arguments.getString("keys") else {
            return ToolResponse.error("Missing required parameter: keys")
        }

        // Validate keys is not empty
        guard !keys.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ToolResponse.error("Keys parameter cannot be empty")
        }

        // Extract optional hold_duration parameter
        let holdDuration = arguments.getNumber("hold_duration") ?? 50

        // Validate hold_duration
        guard holdDuration >= 0 else {
            return ToolResponse.error("hold_duration must be non-negative")
        }

        // Convert to integer milliseconds
        let holdDurationMs = Int(holdDuration)
        guard holdDurationMs <= 10000 else { // Max 10 seconds
            return ToolResponse.error("hold_duration cannot exceed 10000ms (10 seconds)")
        }

        do {
            let startTime = Date()

            // Execute hotkey using PeekabooServices
            let hotkeyService = self.context.automation
            let foreground = arguments.getBool("foreground") == true
            let target = MCPInteractionTarget(
                app: arguments.getString("app"),
                pid: arguments.getInt("pid"),
                windowTitle: arguments.getString("window_title"),
                windowIndex: arguments.getInt("window_index"),
                windowId: arguments.getInt("window_id"))
            let targetPID = foreground ? nil : try await target.processIdentifierIfTargeted(
                applications: self.context.applications,
                windows: self.context.windows)
            if let targetPID, targetPID > 0 {
                guard let hotkeyService = hotkeyService as? any TargetedHotkeyServiceProtocol,
                      hotkeyService.supportsTargetedHotkeys
                else {
                    return ToolResponse.error("This automation host does not support background hotkeys.")
                }
                try await hotkeyService.hotkey(
                    keys: keys,
                    holdDuration: holdDurationMs,
                    targetProcessIdentifier: pid_t(targetPID))
            } else {
                _ = try await target.focusIfRequested(
                    windows: self.context.windows,
                    onlyWhenTargeted: true)
                try await hotkeyService.hotkey(keys: keys, holdDuration: holdDurationMs)
            }

            let executionTime = Date().timeIntervalSince(startTime)

            // Format keys for display
            let keyArray = keys.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let formattedKeys = keyArray.joined(separator: "+")

            let durationText = String(format: "%.2f", executionTime)
            let message = "\(AgentDisplayTokens.Status.success) Pressed \(formattedKeys) " +
                "(held for \(holdDurationMs)ms) in \(durationText)s"

            let baseMeta: Value = .object([
                "keys": .string(keys),
                "hold_duration": .double(Double(holdDurationMs)),
                "execution_time": .double(executionTime),
                "formatted_keys": .string(formattedKeys),
                "delivery_mode": .string(targetPID == nil ? "foreground" : "background"),
                "target_pid": targetPID.map { .int(Int($0)) } ?? .null,
            ])

            let resolvedWindowTitle = try await target.resolveWindowTitleIfNeeded(windows: self.context.windows)
            let summary = ToolEventSummary(
                targetApp: target.appIdentifier,
                windowTitle: resolvedWindowTitle,
                actionDescription: "Hotkey",
                waitDurationMs: Double(holdDurationMs),
                notes: formattedKeys)

            return ToolResponse(
                content: [.text(text: message, annotations: nil, _meta: nil)],
                meta: ToolEventSummary.merge(summary: summary, into: baseMeta))

        } catch let error as MCPInteractionTargetError {
            return ToolResponse.error(error.localizedDescription)
        } catch {
            self.logger.error("Hotkey execution failed: \(error)")
            return ToolResponse.error("Failed to press hotkey combination '\(keys)': \(error.localizedDescription)")
        }
    }
}
