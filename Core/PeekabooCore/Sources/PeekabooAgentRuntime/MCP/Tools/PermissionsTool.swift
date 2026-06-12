import Foundation
import MCP
import PeekabooAutomation
import TachikomaMCP

/// MCP tool for checking macOS system permissions
public struct PermissionsTool: MCPTool {
    private let context: MCPToolContext

    public let name = "permissions"
    public let description = """
    Check macOS system permissions required for automation.
    Verifies both Screen Recording and Accessibility permissions.
    Returns the current permission status for each required permission.
    \(PeekabooMCPVersion.banner) using openai/gpt-5.5, anthropic/claude-opus-4-8
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
        // Get permissions from PeekabooCore services
        let screenRecording = await self.context.screenCapture.hasScreenRecordingPermission()
        let accessibility = await self.context.automation.hasAccessibilityPermission()

        // Build response text
        var lines: [String] = []
        lines.append("macOS Permissions Status:")
        lines.append("")
        let screenRecordingStatus = screenRecording
            ? "\(AgentDisplayTokens.Status.success) Granted"
            : "\(AgentDisplayTokens.Status.failure) Not Granted"
        let accessibilityStatus = accessibility
            ? "\(AgentDisplayTokens.Status.success) Granted"
            : "\(AgentDisplayTokens.Status.warning) Not Granted (Optional)"

        lines.append("Screen Recording: \(screenRecordingStatus)")
        lines.append("Accessibility: \(accessibilityStatus)")

        if !screenRecording {
            lines.append("")
            let warning = "\(AgentDisplayTokens.Status.warning) Screen Recording permission is REQUIRED " +
                "for capturing screenshots."
            lines.append(warning)
            lines.append("Grant via: System Settings > Privacy & Security > Screen Recording")
        }

        if !accessibility {
            lines.append("")
            lines.append("ℹ️  Accessibility permission is optional but needed for UI automation.")
            lines.append("Grant via: System Settings > Privacy & Security > Accessibility")
        }

        let responseText = lines.joined(separator: "\n")

        // Return error response if required permissions are missing
        if !screenRecording {
            let summary = ToolEventSummary(actionDescription: "Permissions", notes: "Screen Recording missing")
            return ToolResponse.error(responseText, meta: ToolEventSummary.merge(summary: summary, into: nil))
        }

        let baseMeta: [String: Value] = [
            "screen_recording": .bool(screenRecording),
            "accessibility": .bool(accessibility),
        ]
        let summary = ToolEventSummary(
            actionDescription: "Permissions",
            notes: "Screen Recording ✅, Accessibility \(accessibility ? "✅" : "⚠️")")

        return ToolResponse.text(
            responseText,
            meta: ToolEventSummary.merge(summary: summary, into: .object(baseMeta)))
    }
}
