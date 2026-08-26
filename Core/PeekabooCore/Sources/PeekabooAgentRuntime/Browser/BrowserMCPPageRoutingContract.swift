import Foundation
import PeekabooFoundation

struct BrowserMCPToolCapabilityContract: Sendable, Equatable {
    enum ElementInput: Sendable, Equatable {
        case direct(String)
        case objectArray(arrayKey: String, elementKey: String)
        case stringArray(String)
        case decodedSingletonObjectValues(String)
    }

    enum ResponseProjection: Sendable, Equatable {
        case none
        case pages
        case snapshotAlways
        case snapshotWhen(Bool)
        case thirdPartySnapshot
    }

    enum Effect: Sendable, Equatable {
        case preserve
        case invalidateSnapshot
        case navigate
        case removePage
        case invalidateAllPages
    }

    let elementInputs: [ElementInput]
    let responseProjection: ResponseProjection
    let effect: Effect
}

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

    // chrome-devtools-mcp-contract:element-reference-path-begin
    static let elementReferencePathMarkers: Set<String> = [
        "click.uid",
        "drag.from_uid",
        "drag.to_uid",
        "evaluate_script.args[]",
        "execute_3p_developer_tool.params{*}.uid",
        "fill.uid",
        "fill_form.elements[].uid",
        "hover.uid",
        "take_screenshot.uid",
        "upload_file.uid",
    ]
    // chrome-devtools-mcp-contract:element-reference-path-end

    // chrome-devtools-mcp-contract:page-response-begin
    static let pageResponseToolNames: Set<String> = [
        "close_page",
        "handle_dialog",
        "list_pages",
        "navigate_page",
        "new_page",
        "resize_page",
        "select_page",
    ]
    // chrome-devtools-mcp-contract:page-response-end

    // chrome-devtools-mcp-contract:snapshot-response-begin
    static let snapshotResponseToolNames: Set<String> = [
        "click",
        "click_at",
        "drag",
        "execute_3p_developer_tool",
        "fill",
        "fill_form",
        "hover",
        "press_key",
        "take_snapshot",
        "upload_file",
        "wait_for",
    ]
    // chrome-devtools-mcp-contract:snapshot-response-end

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

    static func capabilityContract(
        for toolName: String,
        arguments: [String: Any] = [:]) -> BrowserMCPToolCapabilityContract?
    {
        guard self.routing(for: toolName) != nil else { return nil }
        let elementInputs: [BrowserMCPToolCapabilityContract.ElementInput] = switch toolName {
        case "click", "fill", "hover", "take_screenshot", "upload_file":
            [.direct("uid")]
        case "drag":
            [.direct("from_uid"), .direct("to_uid")]
        case "fill_form":
            [.objectArray(arrayKey: "elements", elementKey: "uid")]
        case "evaluate_script":
            [.stringArray("args")]
        case "execute_3p_developer_tool":
            [.decodedSingletonObjectValues("params")]
        default:
            []
        }

        let responseProjection: BrowserMCPToolCapabilityContract.ResponseProjection = switch toolName {
        case "list_pages", "select_page", "close_page", "new_page", "navigate_page", "resize_page",
             "handle_dialog":
            .pages
        case "take_snapshot", "wait_for":
            .snapshotAlways
        case "click", "click_at", "drag", "fill", "fill_form", "hover", "press_key", "upload_file":
            .snapshotWhen(arguments["includeSnapshot"] as? Bool == true)
        case "execute_3p_developer_tool":
            .thirdPartySnapshot
        default:
            .none
        }

        let effect: BrowserMCPToolCapabilityContract.Effect = switch toolName {
        case "close_page":
            .removePage
        case "navigate_page":
            .navigate
        case "performance_start_trace" where arguments["reload"] as? Bool != false:
            .navigate
        case "lighthouse_audit" where arguments["mode"] as? String != "snapshot":
            .navigate
        case "install_extension", "reload_extension", "uninstall_extension":
            .invalidateAllPages
        default:
            self.actionSemantics(for: toolName, arguments: arguments) == .mutating &&
                self.routing(for: toolName) == .pageTargeted
                ? .invalidateSnapshot
                : .preserve
        }
        return BrowserMCPToolCapabilityContract(
            elementInputs: elementInputs,
            responseProjection: responseProjection,
            effect: effect)
    }
}
