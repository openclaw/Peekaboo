import Algorithms
import Foundation
import MCP
import PeekabooAutomation
import TachikomaMCP

/// MCP tool for listing various system items
public struct ListTool: MCPTool {
    private let context: MCPToolContext

    public let name = "list"
    public let description = """
    Lists system information so agents know what is running.

    Capabilities:
    - Running applications: enumerate names, bundle IDs, and PIDs.
    - Application windows: list titles for a target app and optionally include IDs, bounds, and off-screen hints.
    - Server status: report Peekaboo MCP version, permissions, and configured AI providers.

    Example queries:
    - { "item_type": "running_applications" }
    - { "item_type": "application_windows", "app": "Notes", "include_window_details": ["ids", "bounds"] }
    - { "item_type": "server_status" }
    \(PeekabooMCPVersion.banner) using openai/gpt-5.5, anthropic/claude-opus-4-8
    """

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "item_type": SchemaBuilder.string(
                    description: """
                    Controls what is listed. Defaults to:
                    - application_windows when `app` is provided
                    - running_applications otherwise

                    Valid values:
                    - running_applications
                    - application_windows
                    - server_status
                    """,
                    enum: ListItemType.allCases.map(\.rawValue)),
                "app": SchemaBuilder.string(
                    description: """
                    Target application when listing windows. Accepts app name,
                    bundle ID, or PID (e.g., PID:663). Partial names are fuzzy matched.
                    """),
                "include_window_details": SchemaBuilder.array(
                    items: SchemaBuilder.string(enum: WindowDetail.allCases.map(\.rawValue)),
                    description: """
                    Extra data for each window (application_windows only).
                    Choose any combination of `ids`, `bounds`, or `off_screen`.
                    """),
            ],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let request: ListRequest
        do {
            request = try ListRequest(arguments: arguments)
        } catch let error as ListInputError {
            return ToolResponse.error(error.message)
        }

        switch request.itemType {
        case .runningApplications:
            return try await self.listRunningApplications()
        case .applicationWindows:
            return try await self.listApplicationWindows(request: request)
        case .serverStatus:
            return await self.getServerStatus()
        }
    }

    private func listRunningApplications() async throws -> ToolResponse {
        do {
            let output = try await self.context.applications.listApplications()
            let apps = output.data.applications
            var lines: [String] = []
            let countSuffix = apps.count == 1 ? "" : "s"
            let appCountLine =
                "\(AgentDisplayTokens.Status.success) Found \(apps.count) running application\(countSuffix):"
            lines.append(appCountLine)
            lines.append("")

            for (index, app) in apps.indexed() {
                lines.append(RunningApplicationTextFormatter.format(app, index: index))
            }

            if let activeApp = apps.first(where: { $0.isActive }) {
                lines.append(RunningApplicationTextFormatter.activeLine(activeApp))
            }

            let summary = ToolEventSummary(
                actionDescription: "List Applications",
                notes: "\(apps.count) running")
            return ToolResponse.text(
                lines.joined(separator: "\n"),
                meta: ToolEventSummary.merge(summary: summary, into: nil))
        } catch {
            return ToolResponse.error("Failed to list applications: \(error.localizedDescription)")
        }
    }

    private func listApplicationWindows(request: ListRequest) async throws -> ToolResponse {
        do {
            let identifier = request.app ?? ""
            let output = try await self.context.applications.listWindows(for: identifier, timeout: nil)
            let formatter = WindowListFormatter(
                appInfo: output.data.targetApplication,
                identifier: identifier,
                windows: output.data.windows,
                details: request.windowDetails)
            return formatter.response()
        } catch {
            return ToolResponse.error("Failed to list windows: \(error.localizedDescription)")
        }
    }

    private func getServerStatus() async -> ToolResponse {
        var sections: [String] = []

        // 1. Server version
        sections.append("# Peekaboo MCP Server Status")
        sections.append("")
        sections.append("Version: \(PeekabooMCPVersion.current)")
        sections.append("Platform: macOS")
        sections.append("")

        // 2. System Permissions
        sections.append("## System Permissions")

        let screenRecording = await self.context.screenCapture.hasScreenRecordingPermission()
        let accessibility = await self.context.automation.hasAccessibilityPermission()

        let screenStatus = screenRecording
            ? "\(AgentDisplayTokens.Status.success) Granted"
            : "\(AgentDisplayTokens.Status.failure) Not granted"
        let accessibilityStatus = accessibility
            ? "\(AgentDisplayTokens.Status.success) Granted"
            : "\(AgentDisplayTokens.Status.failure) Not granted"

        sections.append("- Screen Recording: \(screenStatus)")
        sections.append("- Accessibility: \(accessibilityStatus)")
        sections.append("")

        // 3. AI Provider Status
        sections.append("## AI Provider Status")

        if let providersString = ProcessInfo.processInfo.environment["PEEKABOO_AI_PROVIDERS"] {
            sections.append("Configured providers: \(providersString)")
        } else {
            sections.append("\(AgentDisplayTokens.Status.failure) No AI providers configured")
            sections.append("Set PEEKABOO_AI_PROVIDERS to enable image analysis features.")
        }
        sections.append("")

        // 4. Configuration Issues
        sections.append("## Configuration Issues")

        var issues: [String] = []

        if !screenRecording {
            issues.append("\(AgentDisplayTokens.Status.failure) Screen Recording permission not granted")
        }

        if ProcessInfo.processInfo.environment["PEEKABOO_AI_PROVIDERS"] == nil {
            issues.append(
                "\(AgentDisplayTokens.Status.warning) No AI providers configured (analysis features will be limited)")
        }

        if issues.isEmpty {
            sections.append("\(AgentDisplayTokens.Status.success) No configuration issues detected")
        } else {
            for issue in issues {
                sections.append(issue)
            }
        }
        sections.append("")

        // 5. System Information
        sections.append("## System Information")
        sections.append("- Platform: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        sections.append("- Architecture: \(ProcessInfo.processInfo.processorArchitecture)")

        let fullStatus = sections.joined(separator: "\n")
        let summary = ToolEventSummary(actionDescription: "Server Status", notes: nil)

        return ToolResponse.text(fullStatus, meta: ToolEventSummary.merge(summary: summary, into: nil))
    }
}
