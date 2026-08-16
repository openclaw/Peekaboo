import Foundation

/// Audited mutation semantics for the pinned Chrome DevTools MCP tool catalog.
///
/// This transport-neutral partition is shared by local browser execution and Bridge clients. Unknown tools return
/// `nil` so callers that can dispatch arbitrary provider calls can fail closed, while validated raw-tool frontends
/// can reject them before dispatch.
public enum BrowserToolActionSemantics: Equatable, Sendable {
    case readOnly
    case mutating

    // A read-only browser call may inspect page/provider state or write an explicitly requested capture artifact,
    // but it does not change the page, browser, or user's visible UI.
    // chrome-devtools-mcp-contract:semantic-read-only-begin
    public static let readOnlyToolNames: Set<String> = [
        "close_heapsnapshot",
        "compare_heapsnapshots",
        "get_console_message",
        "get_heapsnapshot_class_nodes",
        "get_heapsnapshot_details",
        "get_heapsnapshot_dominators",
        "get_heapsnapshot_duplicate_strings",
        "get_heapsnapshot_edges",
        "get_heapsnapshot_retainers",
        "get_heapsnapshot_retaining_paths",
        "get_heapsnapshot_summary",
        "get_network_request",
        "get_tab_id",
        "list_3p_developer_tools",
        "list_console_messages",
        "list_extensions",
        "list_network_requests",
        "list_pages",
        "list_webmcp_tools",
        "performance_analyze_insight",
        "performance_stop_trace",
        "screencast_start",
        "screencast_stop",
        "take_heapsnapshot",
        "take_screenshot",
        "take_snapshot",
        "wait_for",
    ]
    // chrome-devtools-mcp-contract:semantic-read-only-end

    // chrome-devtools-mcp-contract:semantic-mutating-begin
    public static let mutatingToolNames: Set<String> = [
        "click",
        "click_at",
        "close_page",
        "drag",
        "emulate",
        "evaluate_script",
        "execute_3p_developer_tool",
        "execute_webmcp_tool",
        "fill",
        "fill_form",
        "handle_dialog",
        "hover",
        "install_extension",
        "lighthouse_audit",
        "navigate_page",
        "new_page",
        "press_key",
        "reload_extension",
        "resize_page",
        "trigger_extension_action",
        "type_text",
        "uninstall_extension",
        "upload_file",
    ]
    // chrome-devtools-mcp-contract:semantic-mutating-end

    // chrome-devtools-mcp-contract:semantic-argument-dependent-begin
    public static let argumentDependentToolNames: Set<String> = [
        "performance_start_trace",
        "select_page",
    ]
    // chrome-devtools-mcp-contract:semantic-argument-dependent-end

    public static let allToolNames = BrowserToolActionSemantics.readOnlyToolNames
        .union(BrowserToolActionSemantics.mutatingToolNames)
        .union(BrowserToolActionSemantics.argumentDependentToolNames)

    public static func classify(
        toolName: String,
        booleanArgument: (String) -> Bool?) -> Self?
    {
        if self.readOnlyToolNames.contains(toolName) {
            return .readOnly
        }
        if self.mutatingToolNames.contains(toolName) {
            return .mutating
        }
        switch toolName {
        case "select_page":
            return booleanArgument("bringToFront") == true ? .mutating : .readOnly
        case "performance_start_trace":
            // The provider default is reload=true, which navigates the target page before tracing.
            return booleanArgument("reload") == false ? .readOnly : .mutating
        default:
            return nil
        }
    }
}
