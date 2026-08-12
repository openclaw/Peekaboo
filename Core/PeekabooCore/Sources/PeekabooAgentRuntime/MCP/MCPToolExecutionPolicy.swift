import Foundation
import Tachikoma
import TachikomaMCP

/// Immutable execution authority applied before an MCP tool can validate or dispatch.
///
/// Standalone MCP and CLI tools use ``unrestricted``. Agent sessions default to
/// ``backgroundOnly``. A stored foreground choice is an immutable maximum; each resumed
/// process invocation still requires fresh human foreground authorization.
public enum MCPToolExecutionPolicy: String, Codable, Sendable {
    case unrestricted
    case backgroundOnly = "background_only"
    case foregroundAllowed = "foreground_allowed"

    static let refusalErrorCode = "AGENT_EXECUTION_POLICY_REFUSAL"

    func rejection(toolName: String, arguments: ToolArguments) -> ToolResponse? {
        let reason: String? = switch self {
        case .unrestricted:
            nil
        case .backgroundOnly:
            BackgroundOnlyToolPolicy.violation(toolName: toolName, arguments: arguments)?.reason
        case .foregroundAllowed:
            ForegroundAllowedAgentToolPolicy.refusalReason(toolName: toolName)
        }
        return reason.map { self.refusal(toolName: toolName, reason: $0) }
    }

    func systemSurfaceRejection(
        toolName: String,
        applicationBundleIdentifier: String?,
        applicationName: String?) -> ToolResponse?
    {
        guard self == .backgroundOnly else { return nil }
        let normalizedBundleIdentifier = applicationBundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedApplicationName = applicationName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedBundleIdentifier, !normalizedBundleIdentifier.isEmpty {
            guard Self.sharedSystemUIBundleIdentifiers.contains(normalizedBundleIdentifier) else { return nil }
        } else {
            guard let normalizedApplicationName,
                  Self.sharedSystemUIApplicationNames.contains(normalizedApplicationName)
            else { return nil }
        }
        return self.refusal(
            toolName: toolName,
            reason: "the selected target is shared system UI and cannot be mutated in background-only mode")
    }

    func unresolvedTargetRejection(toolName: String, detail: String) -> ToolResponse? {
        guard self == .backgroundOnly else {
            return nil
        }
        return self.refusal(
            toolName: toolName,
            reason: "the selected mutation target could not be proven background-safe: \(detail)")
    }

    private func refusal(toolName: String, reason: String) -> ToolResponse {
        ToolResponse.error(
            "Agent session policy refused '\(toolName)' before dispatch because \(reason). " +
                "Only a human can authorize a different Agent execution policy.",
            meta: .object([
                "effect": .string("refused"),
                "error_code": .string(Self.refusalErrorCode),
                "execution_policy": .string(self.rawValue),
                "mutation_dispatched": .bool(false),
                "retry_safe": .bool(true),
            ]))
    }

    private static let sharedSystemUIBundleIdentifiers: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.dock",
        "com.apple.notificationcenterui",
        "com.apple.passwords.menubarextra",
        "com.apple.siri",
        "com.apple.spotlight",
        "com.apple.systemuiserver",
    ]

    private static let sharedSystemUIApplicationNames: Set<String> = [
        "control center",
        "dock",
        "notification center",
        "passwords",
        "passwords menu bar extra",
        "siri",
        "spotlight",
        "systemuiserver",
    ]

    func rejection(toolName: String, agentArguments: [String: AnyAgentToolValue]) -> ToolResponse? {
        self.rejection(
            toolName: toolName,
            arguments: ToolArguments(from: AgentToolArguments(agentArguments)))
    }
}

private enum BackgroundOnlyToolPolicy {
    enum Violation {
        case foregroundRequest(String)
        case activation(String)
        case sharedDesktop(String)
        case unclassified

        var reason: String {
            switch self {
            case let .foregroundRequest(detail): detail
            case let .activation(detail): detail
            case let .sharedDesktop(detail): detail
            case .unclassified: "the tool or action is not classified as background-safe"
            }
        }
    }

    static func violation(toolName: String, arguments: ToolArguments) -> Violation? {
        switch toolName {
        case "see", "inspect_ui", "verify_state", "analyze", "permissions", "sleep", "set_value", "done", "need_info":
            nil
        case "clipboard":
            self.clipboardViolation(arguments)
        case "click":
            self.explicitForeground(arguments, inverseBackgroundKey: "background")
        case "type", "scroll", "paste":
            self.explicitForeground(arguments)
        case "press":
            self.rawPressViolation(arguments)
        case "action":
            self.actionViolation(arguments)
        case "image", "capture":
            self.captureViolation(arguments)
        case "app":
            self.appViolation(arguments)
        case "window":
            self.windowViolation(arguments)
        case "menu":
            self.menuViolation(arguments)
        case "dialog":
            self.dialogViolation(arguments)
        case "dock":
            self.listOnlyViolation(arguments, surface: "Dock")
        case "space":
            self.spaceViolation(arguments)
        case "browser":
            self.browserViolation(arguments)
        case "drag", "move":
            .sharedDesktop("it uses the shared physical pointer")
        case "shell":
            .sharedDesktop("shell execution can bypass the Agent's background-only tool boundary")
        case "agent":
            .unclassified
        default:
            .unclassified
        }
    }

    private static func explicitForeground(
        _ arguments: ToolArguments,
        inverseBackgroundKey: String? = nil) -> Violation?
    {
        if arguments.getBool("foreground") == true {
            return .foregroundRequest("foreground=true requests foreground or global delivery")
        }
        if let inverseBackgroundKey, arguments.getBool(inverseBackgroundKey) == false {
            return .foregroundRequest("\(inverseBackgroundKey)=false requests foreground or global delivery")
        }
        return nil
    }

    private static func actionViolation(_ arguments: ToolArguments) -> Violation? {
        guard let action = self.normalized(arguments.getString("action")) else { return nil }
        let canonicalAction = action.hasPrefix("ax") ? String(action.dropFirst(2)) : action
        if ["raise", "showmenu", "showalternateui", "showdefaultui"].contains(canonicalAction) {
            return .activation("the requested Accessibility action can raise or expose foreground UI")
        }
        return nil
    }

    private static func rawPressViolation(_ arguments: ToolArguments) -> Violation {
        self.explicitForeground(arguments) ?? .sharedDesktop(
            "public raw press cannot prove background intent or effect and requires foreground consent")
    }

    private static func captureViolation(_ arguments: ToolArguments) -> Violation? {
        switch self.normalized(arguments.getString("capture_focus")) {
        case "auto", "foreground":
            .foregroundRequest("capture_focus can activate the capture target")
        case nil, "background":
            // Image and capture both resolve an omitted value to background before dispatch.
            nil
        default:
            // The leaf argument validator refuses unknown values before dispatch.
            nil
        }
    }

    private static func appViolation(_ arguments: ToolArguments) -> Violation? {
        if let foreground = self.explicitForeground(arguments) {
            return foreground
        }
        switch self.normalized(arguments.getString("action")) {
        case nil:
            return nil
        case "focus", "switch":
            return .activation("the application action activates or switches the foreground application")
        case "launch", "open", "quit", "relaunch", "hide", "unhide", "list":
            return nil
        default:
            return .unclassified
        }
    }

    private static func windowViolation(_ arguments: ToolArguments) -> Violation? {
        if let foreground = self.explicitForeground(arguments) {
            return foreground
        }
        switch self.normalized(arguments.getString("action")) {
        case nil:
            return nil
        case "focus":
            return .activation("the window action activates and raises its application")
        case "list", "close", "minimize", "restore", "maximize", "move", "resize", "setbounds":
            return nil
        default:
            return .unclassified
        }
    }

    private static func menuViolation(_ arguments: ToolArguments) -> Violation? {
        if let foreground = self.explicitForeground(arguments) {
            return foreground
        }
        return switch self.normalized(arguments.getString("action")) {
        case nil, "list", "click": nil
        default: .unclassified
        }
    }

    private static func dialogViolation(_ arguments: ToolArguments) -> Violation? {
        if let foreground = self.explicitForeground(arguments) {
            return foreground
        }
        switch self.normalized(arguments.getString("action")) {
        case nil, "list", "click":
            return nil
        case "dismiss":
            return arguments.getBool("force") == true
                ? .sharedDesktop("forced dialog dismissal sends global keyboard input")
                : nil
        case "input", "file":
            return .sharedDesktop("the dialog action requires global keyboard or coordinate input")
        default:
            return .unclassified
        }
    }

    private static func listOnlyViolation(_ arguments: ToolArguments, surface: String) -> Violation? {
        switch self.normalized(arguments.getString("action")) {
        case nil, "list": nil
        default: .sharedDesktop("the \(surface) action mutates shared desktop UI")
        }
    }

    private static func spaceViolation(_ arguments: ToolArguments) -> Violation? {
        if let foreground = self.explicitForeground(arguments) {
            return foreground
        }
        switch self.normalized(arguments.getString("action")) {
        case nil, "list":
            return nil
        case "movewindow":
            return arguments.getBool("follow") == true
                ? .activation("follow=true switches the visible Space after moving the window")
                : nil
        case "switch":
            return .activation("switch changes the user's visible Space")
        default:
            return .unclassified
        }
    }

    private static func browserViolation(_ arguments: ToolArguments) -> Violation? {
        if arguments.getBool("bring_to_front") == true {
            return .activation("bring_to_front=true raises the selected browser page")
        }
        if arguments.getBool("background") == false {
            return .activation("background=false requests a foreground browser page")
        }
        let action = self.normalized(arguments.getString("action"))
        if action == "connect" {
            return .activation("connecting can surface Chrome's remote-debugging setup or permission UI")
        }
        if action == "newpage" {
            // The typed wrapper maps an omitted background value to true before delegating upstream.
            return nil
        }
        guard action == "call" else { return nil }
        guard let rawTool = self.normalized(arguments.getString("mcp_tool")) else { return nil }

        switch rawTool {
        case "selectpage":
            guard self.rawBrowserBool(arguments, keys: ["bringToFront", "bring_to_front"]) == false else {
                return .activation("raw select_page does not prove bringToFront=false")
            }
        case "newpage":
            guard self.rawBrowserBool(arguments, keys: ["background"]) == true else {
                return .activation("raw new_page does not prove background=true")
            }
        default:
            break
        }
        return nil
    }

    private static func clipboardViolation(_ arguments: ToolArguments) -> Violation? {
        switch self.normalized(arguments.getString("action")) {
        case nil, "get", "save":
            nil
        case "set", "clear", "restore":
            .sharedDesktop(
                "the action persistently changes the user's shared clipboard; use transactional paste instead")
        default:
            .unclassified
        }
    }

    private static func rawBrowserBool(_ arguments: ToolArguments, keys: [String]) -> Bool? {
        guard let raw = arguments.getString("mcp_args_json"),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        for key in keys {
            if let value = object[key] as? Bool {
                return value
            }
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return normalized.isEmpty ? nil : normalized
    }
}

private enum ForegroundAllowedAgentToolPolicy {
    private static let allowedToolNames: Set<String> = [
        "action", "analyze", "app", "browser", "capture", "click", "clipboard", "dialog", "dock", "done", "drag",
        "image", "inspect_ui", "menu", "move", "need_info", "paste", "permissions", "press", "scroll", "see",
        "set_value", "sleep", "space", "type", "verify_state", "window",
    ]

    static func refusalReason(toolName: String) -> String? {
        if toolName == "shell" {
            return "shell execution is a separate privilege and can bypass native UI automation, including through " +
                "AppleScript, JXA, OSA, or arbitrary subprocesses"
        }
        guard self.allowedToolNames.contains(toolName) else {
            return "the tool is not classified for Agent execution"
        }
        return nil
    }
}
