import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for controlling applications (launch/quit/focus/etc.)
public struct AppTool: MCPTool {
    private let logger = Logger(subsystem: "boo.peekaboo.mcp", category: "AppTool")
    private let context: MCPToolContext

    public let name = "app"

    public var description: String {
        if self.context.executionPolicy == .backgroundOnly {
            return """
            Control applications under immutable background-only authority. Available actions are `list`, `quit`,
            `hide`, and `launch`; background `launch` is only an exact already-running readiness probe and never cold
            starts an app. Focus, switch, open, relaunch, unhide, new-instance, and `foreground=true` are unavailable
            here because they can activate shared desktop UI. A human must start a foreground-capable Agent session or
            use the standalone CLI with explicit foreground consent for those operations.

            Process-generation chaining must use `target_identity.process_start_identity_decimal`; the numeric
            `process_start_identity` field remains compatibility-only and can lose precision above 2^53.

            Always include the `action` field in your JSON payload. Examples:
            - { "action": "list" }
            - Already-running readiness probe: { "action": "launch", "name": "Finder" }
            - { "action": "quit", "name": "Slack", "force": false }
            """
        }

        return """
        Control applications with explicit foreground-capable authority. Focus and switch activate shared desktop UI;
        cold launch, open, new-instance, relaunch, and unhide require `foreground=true` because macOS cannot guarantee
        those operations preserve the user's foreground work. Prefer background targeting after foreground setup.
        Process-generation chaining must use `target_identity.process_start_identity_decimal`; the numeric
        `process_start_identity` field remains compatibility-only and can lose precision above 2^53.

        Always include the `action` field in your JSON payload. Examples:
        - Already-running readiness probe: { "action": "launch", "name": "PID:1234" }
        - Cold launch with foreground consent: { "action": "launch", "name": "Calendar", "foreground": true }
        - { "action": "launch", "name": "TextEdit", "newInstance": true, "foreground": true }
        - { "action": "open", "name": "Safari", "openTargets": ["https://example.com"], "foreground": true }
        - { "action": "switch", "to": "Safari" }
        - { "action": "focus", "name": "Google Chrome" }
        - { "action": "quit", "name": "Slack", "force": false }
        """
    }

    public var inputSchema: Value {
        let foregroundCapable = self.context.executionPolicy != .backgroundOnly
        let actions = foregroundCapable
            ? ["launch", "open", "quit", "relaunch", "focus", "hide", "unhide", "switch", "list"]
            : ["launch", "quit", "hide", "list"]
        var properties: [String: Value] = [
            "action": SchemaBuilder.string(
                description: foregroundCapable
                    ? "Action to perform; focus and switch use the session's explicit foreground authority"
                    : "Background-only action; foreground lifecycle, focus, and switch actions are unavailable",
                enum: actions),
            "name": SchemaBuilder.string(
                description: "App name/bundle ID/PID (e.g., 'Safari', 'com.apple.Safari', 'PID:663')"),
            "bundleId": SchemaBuilder.string(
                description: "Bundle identifier when launching"),
            "force": SchemaBuilder.boolean(
                description: "Force quit application",
                default: false),
            "waitUntilReady": SchemaBuilder.boolean(
                description: "Wait until LaunchServices reports startup complete",
                default: false),
            "waitForWindow": SchemaBuilder.boolean(
                description: "Wait until the launched app exposes an exact WindowServer window",
                default: false),
            "all": SchemaBuilder.boolean(
                description: "Quit all applications",
                default: false),
            "except": SchemaBuilder.string(
                description: "Comma-separated list of apps to exclude when quitting all"),
        ]
        if foregroundCapable {
            properties["openTargets"] = SchemaBuilder.array(
                items: SchemaBuilder.string(),
                description: "URL or file paths to open; required for open, optional for launch")
            properties["foreground"] = SchemaBuilder.boolean(
                description: "Required for cold launch, open, new-instance, relaunch, and unhide",
                default: false)
            properties["wait"] = SchemaBuilder.number(
                description: "Wait time (seconds) between quit/launch for relaunch",
                default: 2.0)
            properties["newInstance"] = SchemaBuilder.boolean(
                description: "Launch a distinct process even if the app is already running",
                default: false)
            properties["to"] = SchemaBuilder.string(description: "Target application when switching")
            properties["cycle"] = SchemaBuilder.boolean(
                description: "Cycle to the next application (like Cmd+Tab)",
                default: false)
        }

        return SchemaBuilder.object(
            properties: properties,
            required: ["action"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        guard let action = arguments.getString("action") else {
            return ToolResponse.error("Missing required parameter: action")
        }

        let request = AppToolRequest(
            name: arguments.getString("name"),
            bundleId: arguments.getString("bundleId"),
            openTargets: arguments.getStringArray("openTargets") ?? [],
            foreground: arguments.getBool("foreground") ?? false,
            force: arguments.getBool("force") ?? false,
            wait: arguments.getNumber("wait") ?? 2.0,
            waitUntilReady: arguments.getBool("waitUntilReady") ?? false,
            waitForWindow: arguments.getBool("waitForWindow") ?? false,
            newInstance: arguments.getBool("newInstance") ?? false,
            all: arguments.getBool("all") ?? false,
            except: arguments.getString("except"),
            switchTarget: arguments.getString("to"),
            cycle: arguments.getBool("cycle") ?? false,
            startTime: Date())

        do {
            let actions = AppToolActions(
                service: self.context.applications,
                automation: self.context.automation,
                logger: self.logger,
                context: self.context)
            return try await actions.perform(action: action, request: request)
        } catch {
            self.logger.error("App control execution failed: \(error, privacy: .public)")
            if let failure = error as? DesktopActionFailure {
                return try MCPToolResponseMetadataProjector.errorResponse(
                    for: failure,
                    invalidatedSnapshotID: nil)
            }
            if let lifecycleFailure = error as? any ApplicationLifecycleFailureMetadataProviding,
               let metadata = lifecycleFailure.applicationLifecycleFailureMetadata
            {
                var meta: [String: Value] = [
                    "error_code": .string(metadata.errorCode.rawValue),
                ]
                if let hint = metadata.hint {
                    meta["hint"] = .string(hint)
                }
                if metadata.effect == "refused" {
                    let failure = DesktopActionFailure.preDispatchRefusal(
                        reason: .foregroundConsentRequired,
                        message: "Failed to \(action) application: \(error.localizedDescription)",
                        hint: metadata.hint)
                    return try MCPToolResponseMetadataProjector.errorResponse(
                        for: failure,
                        invalidatedSnapshotID: nil,
                        additionalFields: meta)
                }
                meta["effect"] = .string(metadata.effect)
                meta["mutation_dispatched"] = .bool(metadata.mutationDispatched)
                meta["retry_safe"] = .bool(metadata.retrySafe)
                return ToolResponse.error(
                    "Failed to \(action) application: \(error.localizedDescription)",
                    meta: .object(meta))
            }
            return ToolResponse.error("Failed to \(action) application: \(error.localizedDescription)")
        }
    }
}

// MARK: - Request & Helpers

struct AppToolRequest {
    let name: String?
    let bundleId: String?
    let openTargets: [String]
    let foreground: Bool
    let force: Bool
    let wait: Double
    let waitUntilReady: Bool
    let waitForWindow: Bool
    let newInstance: Bool
    let all: Bool
    let except: String?
    let switchTarget: String?
    let cycle: Bool
    let startTime: Date
}
