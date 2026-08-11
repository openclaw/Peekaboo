import Foundation
import MCP
import PeekabooAutomation
import PeekabooAutomationKit
import TachikomaMCP

/// MCP tool for checking macOS system permissions
public struct PermissionsTool: MCPTool {
    private let context: MCPToolContext

    public let name = "permissions"
    public let description = """
    Check macOS system permissions required for automation.
    Verifies Screen Recording and Accessibility as required permissions and reports
    Event Synthesizing as an action-specific input limitation when it is unavailable.
    \(PeekabooMCPVersion.banner) using openai/gpt-5.6, anthropic/claude-opus-5
    """

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [:],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        _ = arguments
        let status: PermissionsStatus
        do {
            status = try await self.context.permissionsStatusProvider.permissionsStatus()
        } catch {
            let meta: Value = .object([
                "permission_snapshot_available": .bool(false),
                "screen_recording": .null,
                "accessibility": .null,
                "event_synthesizing": .null,
                "required_permissions_granted": .null,
                "event_synthesizing_limits": .array([]),
            ])
            let summary = ToolEventSummary(
                actionDescription: "Permissions",
                notes: "Selected-host permission snapshot unavailable")
            return ToolResponse.error(
                "Could not read permissions from the selected execution host: \(error.localizedDescription)",
                meta: ToolEventSummary.merge(summary: summary, into: meta))
        }

        var lines: [String] = []
        lines.append("macOS Permissions Status:")
        lines.append("")
        let screenRecordingStatus = status.screenRecording
            ? "\(AgentDisplayTokens.Status.success) Granted"
            : "\(AgentDisplayTokens.Status.failure) Not Granted"
        let accessibilityStatus = status.accessibility
            ? "\(AgentDisplayTokens.Status.success) Granted"
            : "\(AgentDisplayTokens.Status.failure) Not Granted"
        let eventSynthesizingStatus = status.postEvent
            ? "\(AgentDisplayTokens.Status.success) Granted"
            : "\(AgentDisplayTokens.Status.warning) Not Granted"

        lines.append("Screen Recording (Required): \(screenRecordingStatus)")
        lines.append("Accessibility (Required): \(accessibilityStatus)")
        lines.append("Event Synthesizing (Action-specific): \(eventSynthesizingStatus)")

        if !status.screenRecording {
            lines.append("")
            let warning = "\(AgentDisplayTokens.Status.warning) Screen Recording permission is REQUIRED " +
                "for capturing screenshots."
            lines.append(warning)
            lines.append("Grant via: System Settings > Privacy & Security > Screen Recording")
        }

        if !status.accessibility {
            lines.append("")
            lines.append("\(AgentDisplayTokens.Status.warning) Accessibility permission is REQUIRED " +
                "for UI automation.")
            lines.append("Grant via: System Settings > Privacy & Security > Accessibility")
        }

        let eventSynthesizingLimits: [String] = status.postEvent
            ? []
            : ["background keyboard input", "foreground synthetic pointer input"]
        if !eventSynthesizingLimits.isEmpty {
            lines.append("")
            lines.append("Event Synthesizing is not globally required, but these actions are unavailable: " +
                eventSynthesizingLimits.joined(separator: ", ") + ".")
            lines.append("Background Accessibility actions remain available.")
        }

        let responseText = lines.joined(separator: "\n")
        let requiredPermissionsGranted = status.screenRecording && status.accessibility
        let baseMeta: [String: Value] = [
            "permission_snapshot_available": .bool(true),
            "screen_recording": .bool(status.screenRecording),
            "accessibility": .bool(status.accessibility),
            "event_synthesizing": .bool(status.postEvent),
            "required_permissions_granted": .bool(requiredPermissionsGranted),
            "event_synthesizing_limits": .array(eventSynthesizingLimits.map(Value.string)),
        ]
        let summary = ToolEventSummary(
            actionDescription: "Permissions",
            notes: "Screen Recording \(status.screenRecording ? "✅" : "❌"), " +
                "Accessibility \(status.accessibility ? "✅" : "❌"), " +
                "Event Synthesizing \(status.postEvent ? "✅" : "⚠️")")
        let meta = ToolEventSummary.merge(summary: summary, into: .object(baseMeta))

        if !requiredPermissionsGranted {
            return ToolResponse.error(responseText, meta: meta)
        }

        return ToolResponse.text(
            responseText,
            meta: meta)
    }
}
