import Foundation
import PeekabooFoundation

/// Audited routing contract for the exactly pinned chrome-devtools-mcp dependency.
///
/// Keep this catalog synchronized with `scripts/test-chrome-devtools-mcp-contract.mjs`. Unknown raw tools fail
/// closed so a dependency/schema change cannot silently reintroduce selected-page routing.
enum BrowserMCPPageRoutingContract {
    enum Routing: Equatable {
        case pageTargeted
        case global
        case blockedSelectedPage
    }

    typealias ActionSemantics = BrowserToolActionSemantics

    static let dependencyVersion = "1.6.0"

    // chrome-devtools-mcp-contract:page-scoped-begin
    static let pageScopedToolNames: Set<String> = [
        "click",
        "click_at",
        "drag",
        "emulate",
        "execute_3p_developer_tool",
        "execute_webmcp_tool",
        "fill",
        "fill_form",
        "get_console_message",
        "get_network_request",
        "get_tab_id",
        "handle_dialog",
        "hover",
        "lighthouse_audit",
        "list_3p_developer_tools",
        "list_console_messages",
        "list_network_requests",
        "list_webmcp_tools",
        "navigate_page",
        "performance_analyze_insight",
        "performance_start_trace",
        "performance_stop_trace",
        "press_key",
        "resize_page",
        "screencast_start",
        "screencast_stop",
        "take_heapsnapshot",
        "take_screenshot",
        "take_snapshot",
        "type_text",
        "upload_file",
        "wait_for",
    ]
    // chrome-devtools-mcp-contract:page-scoped-end

    // These upstream tools are not marked `pageScoped`, but their v1.6.0 schemas still require `pageId`.
    // chrome-devtools-mcp-contract:explicit-page-target-begin
    static let explicitPageTargetToolNames: Set<String> = [
        "close_page",
        "evaluate_script",
        "select_page",
    ]
    // chrome-devtools-mcp-contract:explicit-page-target-end

    // chrome-devtools-mcp-contract:global-begin
    static let globalToolNames: Set<String> = [
        "close_heapsnapshot",
        "compare_heapsnapshots",
        "get_heapsnapshot_class_nodes",
        "get_heapsnapshot_details",
        "get_heapsnapshot_dominators",
        "get_heapsnapshot_duplicate_strings",
        "get_heapsnapshot_edges",
        "get_heapsnapshot_retainers",
        "get_heapsnapshot_retaining_paths",
        "get_heapsnapshot_summary",
        "install_extension",
        "list_extensions",
        "list_pages",
        "new_page",
        "reload_extension",
        "uninstall_extension",
    ]
    // chrome-devtools-mcp-contract:global-end

    // These schema-global tools still read upstream's shared selected page internally and cannot be routed safely.
    // chrome-devtools-mcp-contract:blocked-selected-page-begin
    static let blockedSelectedPageToolNames: Set<String> = [
        "trigger_extension_action",
    ]
    // chrome-devtools-mcp-contract:blocked-selected-page-end

    static let pageTargetedToolNames = pageScopedToolNames.union(explicitPageTargetToolNames)
    static let allToolNames = pageTargetedToolNames
        .union(globalToolNames)
        .union(blockedSelectedPageToolNames)
    static let readOnlyToolNames = BrowserToolActionSemantics.readOnlyToolNames
    static let mutatingToolNames = BrowserToolActionSemantics.mutatingToolNames
    static let argumentDependentToolNames = BrowserToolActionSemantics.argumentDependentToolNames
    static let allSemanticToolNames = BrowserToolActionSemantics.allToolNames

    static func routing(for toolName: String) -> Routing? {
        if self.pageTargetedToolNames.contains(toolName) {
            return .pageTargeted
        }
        if self.globalToolNames.contains(toolName) {
            return .global
        }
        if self.blockedSelectedPageToolNames.contains(toolName) {
            return .blockedSelectedPage
        }
        return nil
    }

    static func actionSemantics(
        for toolName: String,
        arguments: [String: Any]) -> ActionSemantics?
    {
        BrowserToolActionSemantics.classify(toolName: toolName) { name in
            arguments[name] as? Bool
        }
    }
}
