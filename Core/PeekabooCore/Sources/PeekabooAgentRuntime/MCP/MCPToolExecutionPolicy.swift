import Foundation
import PeekabooFoundation
import Tachikoma
import TachikomaMCP

/// Immutable execution authority applied before an MCP tool can dispatch.
///
/// Public MCP, CLI, and Agent entry points default to ``backgroundOnly``. Unrestricted or
/// foreground authority must be selected explicitly by a trusted caller. A stored Agent
/// foreground choice is an immutable maximum; each resumed process invocation still requires
/// fresh human foreground authorization.
public enum MCPToolExecutionPolicy: String, Codable, Sendable {
    case unrestricted
    case backgroundOnly = "background_only"
    case foregroundAllowed = "foreground_allowed"

    static let refusalErrorCode = "AGENT_EXECUTION_POLICY_REFUSAL"

    private static let nonUnrestrictedCatalogExclusions: Set<String> = ["shell"]
    private static let backgroundOnlyCatalogExclusions: Set<String> = ["drag", "move"]

    func exposesToolInCatalog(named toolName: String) -> Bool {
        switch self {
        case .unrestricted:
            true
        case .foregroundAllowed:
            !Self.nonUnrestrictedCatalogExclusions.contains(toolName)
        case .backgroundOnly:
            !Self.nonUnrestrictedCatalogExclusions.contains(toolName) &&
                !Self.backgroundOnlyCatalogExclusions.contains(toolName)
        }
    }

    func rejection(toolName: String, arguments: ToolArguments) -> ToolResponse? {
        let refusal: (message: String, reason: DesktopActionOutcome.RefusalReason)? = switch self {
        case .unrestricted:
            nil
        case .backgroundOnly:
            BackgroundOnlyToolPolicy.violation(toolName: toolName, arguments: arguments).map {
                ($0.message, $0.refusalReason)
            }
        case .foregroundAllowed:
            ForegroundAllowedAgentToolPolicy.refusalMessage(toolName: toolName).map {
                ($0, .operationUnsupported)
            }
        }
        return refusal.map {
            self.refusal(toolName: toolName, message: $0.message, reason: $0.reason)
        }
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
            message: "the selected target is shared system UI and cannot be mutated in background-only mode",
            reason: .foregroundConsentRequired)
    }

    func unresolvedTargetRejection(toolName: String, detail: String) -> ToolResponse? {
        guard self == .backgroundOnly else {
            return nil
        }
        return self.refusal(
            toolName: toolName,
            message: "the selected operation target could not be proven background-safe: \(detail)",
            reason: .targetUnavailable)
    }

    func nestedAgentAuthorityRejection() -> ToolResponse? {
        guard self != .backgroundOnly else { return nil }
        return self.refusal(
            toolName: "agent",
            message: "nested Agent execution must retain immutable background-only authority without Shell access " +
                "or foreground escalation",
            reason: .operationUnsupported)
    }

    private func refusal(
        toolName: String,
        message: String,
        reason: DesktopActionOutcome.RefusalReason) -> ToolResponse
    {
        MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
            message: "Execution policy refused '\(toolName)' before dispatch because \(message). " +
                "A trusted caller must explicitly authorize foreground execution; standalone CLI commands that " +
                "support it use --foreground.",
            reason: reason,
            additionalFields: [
                "error_code": .string(Self.refusalErrorCode),
                "execution_policy": .string(self.rawValue),
            ])
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

    static func browserRequiresForegroundAuthority(_ arguments: ToolArguments) -> Bool {
        BackgroundOnlyToolPolicy.browserRequiresForegroundAuthority(arguments)
    }
}

private enum BackgroundOnlyToolPolicy {
    enum Violation {
        case foregroundRequest(String)
        case activation(String)
        case sharedDesktop(String)
        case invalidRequest(String)
        case unclassified

        var message: String {
            switch self {
            case let .foregroundRequest(detail): detail
            case let .activation(detail): detail
            case let .sharedDesktop(detail), let .invalidRequest(detail): detail
            case .unclassified: "the tool or action is not classified as background-safe"
            }
        }

        var refusalReason: DesktopActionOutcome.RefusalReason {
            switch self {
            case .foregroundRequest, .activation, .sharedDesktop:
                .foregroundConsentRequired
            case .invalidRequest:
                .invalidRequest
            case .unclassified:
                .operationUnsupported
            }
        }
    }

    static func violation(toolName: String, arguments: ToolArguments) -> Violation? {
        switch toolName {
        case "see", "inspect_ui":
            arguments.getBool("web_focus") == true
                ? .activation("web_focus=true can focus embedded foreground UI")
                : nil
        case "verify_state", "analyze", "sleep", "set_value", "done", "need_info":
            nil
        case "permissions":
            self.normalized(arguments.getString("action")) == "request"
                ? .sharedDesktop("requesting permissions can present shared system UI")
                : nil
        case "clipboard":
            self.clipboardViolation(arguments)
        case "click":
            self.explicitForeground(arguments, inverseBackgroundKey: "background")
        case "type":
            self.backgroundTypeViolation(arguments)
        case "scroll":
            self.explicitForeground(arguments)
        case "press":
            self.rawPressViolation(arguments)
        case "action":
            self.actionViolation(arguments)
        default:
            self.extendedViolation(toolName: toolName, arguments: arguments)
        }
    }

    private static func extendedViolation(toolName: String, arguments: ToolArguments) -> Violation? {
        switch toolName {
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
        case "paste":
            self.pasteViolation(arguments)
        case "drag", "move":
            self.sharedInputViolation(toolName: toolName)
        case "shell":
            .sharedDesktop("shell execution can bypass the Agent's background-only tool boundary")
        case "agent":
            nil
        default:
            .unclassified
        }
    }

    private static func sharedInputViolation(toolName _: String) -> Violation {
        .sharedDesktop("it uses the shared physical pointer")
    }

    private static func pasteViolation(_ arguments: ToolArguments) -> Violation? {
        if let foreground = self.explicitForeground(arguments) {
            return foreground
        }
        guard arguments.getValue(for: "text") != nil else {
            return .sharedDesktop(
                "clipboard-backed paste changes shared clipboard state or sends Cmd+V without an exact text result")
        }
        let disallowedPayloadKeys = ["filePath", "imagePath", "dataBase64", "uti", "alsoText"]
        guard !disallowedPayloadKeys.contains(where: { arguments.getValue(for: $0) != nil }) else {
            return .sharedDesktop(
                "background-only paste accepts one direct text payload and never shared clipboard data")
        }
        let hasTarget = ["app", "pid", "window_id", "window_title", "window_index"].contains {
            arguments.getValue(for: $0) != nil
        }
        guard hasTarget else {
            return .sharedDesktop("targetless paste would send input to the user's shared foreground keyboard focus")
        }
        return nil
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
        guard let action = arguments.getString("action"),
              AccessibilityActionPolicy.requiresForegroundConsent(action)
        else { return nil }
        return .activation("the requested Accessibility action can raise or expose foreground UI")
    }

    private static func rawPressViolation(_ arguments: ToolArguments) -> Violation? {
        if let violation = self.explicitForeground(arguments) {
            return violation
        }
        let snapshot = arguments.getString("snapshot")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if snapshot?.isEmpty == false {
            return nil
        }
        if self.hasExactWindowSelector(arguments) {
            return .sharedDesktop(
                "a window selector alone cannot prove that raw press targets non-dialog, non-system UI")
        }
        return .sharedDesktop(
            "public raw press requires foreground consent or a fresh exact non-dialog snapshot receipt")
    }

    private static func backgroundTypeViolation(_ arguments: ToolArguments) -> Violation? {
        if let violation = self.explicitForeground(arguments) {
            return violation
        }
        let snapshot = arguments.getString("snapshot")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot?.isEmpty == false else {
            return .sharedDesktop(
                "public background type requires a fresh exact non-dialog snapshot receipt")
        }
        return nil
    }

    private static func hasExactWindowSelector(_ arguments: ToolArguments) -> Bool {
        arguments.getValue(for: "window_id") != nil ||
            arguments.getValue(for: "window_title") != nil ||
            arguments.getValue(for: "window_index") != nil
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
        let action: DialogToolAction
        let inputs: DialogToolInputs
        do {
            action = try DialogToolAction(arguments: arguments)
            inputs = try DialogToolInputs(arguments: arguments)
            _ = try MCPInteractionTarget(
                app: inputs.app,
                pid: inputs.pid,
                windowTitle: inputs.windowTitle,
                windowIndex: inputs.windowIndex,
                windowId: inputs.windowId)
            if action == .click {
                _ = try inputs.requireButton()
            }
        } catch {
            return .invalidRequest(error.localizedDescription)
        }
        switch action {
        case .list:
            return nil
        case .click:
            return self.hasDialogTarget(arguments)
                ? nil
                : .invalidRequest("dialog click requires an explicit app, PID, or window target")
        case .dismiss:
            if arguments.getBool("force") == true {
                return .sharedDesktop("forced dialog dismissal sends shared global Escape input")
            }
            return self.hasDialogTarget(arguments)
                ? nil
                : .invalidRequest("dialog dismiss requires an explicit app, PID, or window target")
        case .input:
            return self.hasDialogTarget(arguments)
                ? nil
                : .sharedDesktop("targetless dialog keyboard input requires foreground consent")
        case .file:
            return .sharedDesktop("dialog keyboard/file interaction requires foreground consent")
        }
    }

    private static func hasDialogTarget(_ arguments: ToolArguments) -> Bool {
        ["app", "pid", "window_id", "window_title", "window_index"].contains {
            arguments.getValue(for: $0) != nil
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
        guard let rawAction = arguments.getString("action"),
              let action = BrowserAction(rawValue: rawAction)
        else { return nil }
        if action == .connect {
            return .activation("connecting can surface Chrome's remote-debugging setup or permission UI")
        }
        if action == .status || action == .disconnect {
            return nil
        }
        guard let calls = self.browserCallsForUserActivationPolicy(action: action, arguments: arguments) else {
            if !BrowserMCPUserActivationPolicy.backgroundCatalogActions.contains(action) {
                return .activation("\(action.rawValue) can grant browser user activation")
            }
            // Argument validation runs before policy at public MCP and Agent boundaries. Let malformed direct calls
            // reach the same typed validation error instead of disguising them as authority refusals.
            return nil
        }
        return switch BrowserMCPUserActivationPolicy.foregroundRequirement(for: calls) {
        case .sourceProvenBackground:
            nil
        case let .foregroundRequired(detail):
            .activation(detail)
        }
    }

    static func browserRequiresForegroundAuthority(_ arguments: ToolArguments) -> Bool {
        guard let violation = self.browserViolation(arguments) else { return false }
        if case .activation = violation {
            return true
        }
        return false
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

    private static func browserCallsForUserActivationPolicy(
        action: BrowserAction,
        arguments: ToolArguments) -> [BrowserMCPMappedCall]?
    {
        var policyArguments = arguments.rawDictionary
        if policyArguments["page_id"] is String {
            policyArguments["page_id"] = 0
        }
        let normalizedArguments = ToolArguments(raw: policyArguments)
        if action == .call {
            guard let toolName = normalizedArguments.getString("mcp_tool"), !toolName.isEmpty else { return nil }
            let raw = normalizedArguments.getString("mcp_args_json") ?? "{}"
            guard let data = raw.data(using: .utf8),
                  let rawArguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return [BrowserMCPMappedCall(toolName: toolName, arguments: rawArguments)]
        }
        return try? BrowserMCPCallMapper.mapSequence(action: action, arguments: normalizedArguments)
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

    static func refusalMessage(toolName: String) -> String? {
        if toolName == "shell" {
            return "shell execution is a separate privilege and can bypass native UI automation, including through " +
                "AppleScript, JXA, OSA, or arbitrary subprocesses"
        }
        if toolName == "agent" {
            return "nested Agent execution is classified only for immutable background-only authority"
        }
        guard self.allowedToolNames.contains(toolName) else {
            return "the tool is not classified for Agent execution"
        }
        return nil
    }
}
