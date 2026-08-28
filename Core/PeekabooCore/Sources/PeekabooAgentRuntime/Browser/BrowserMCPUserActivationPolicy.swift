import Foundation

/// Fail-closed user-activation policy for the exactly pinned Chrome DevTools MCP provider.
///
/// Puppeteer 25.3.0 sends every `evaluate` and `evaluateHandle` call with CDP `userGesture: true`. The provider can
/// therefore grant transient browser user activation without visibly fronting a page. Background execution is limited
/// to routes whose complete successful call path is source-proven not to reach those Puppeteer APIs.
enum BrowserMCPUserActivationPolicy {
    enum Decision: Equatable {
        case sourceProvenBackground
        case foregroundRequired(String)

        var requiresForegroundAuthority: Bool {
            if case .foregroundRequired = self {
                return true
            }
            return false
        }
    }

    // Keep these three sections synchronized with scripts/test-chrome-devtools-mcp-contract.mjs.
    // chrome-devtools-mcp-contract:user-activation-always-foreground-begin
    static let alwaysForegroundToolNames: Set<String> = [
        "click",
        "close_page",
        "drag",
        "evaluate_script",
        "fill",
        "handle_dialog",
        "hover",
        "list_pages",
        "navigate_page",
        "new_page",
        "press_key",
        "resize_page",
        "select_page",
        "type_text",
        "upload_file",
        "wait_for",
    ]
    // chrome-devtools-mcp-contract:user-activation-always-foreground-end

    // chrome-devtools-mcp-contract:user-activation-conditional-begin
    static let conditionalToolNames: Set<String> = [
        "fill_form",
        "get_console_message",
        "get_network_request",
        "list_network_requests",
        "take_screenshot",
        "take_snapshot",
    ]
    // chrome-devtools-mcp-contract:user-activation-conditional-end

    // chrome-devtools-mcp-contract:user-activation-source-proven-background-begin
    static let sourceProvenBackgroundToolNames: Set<String> = [
        "emulate",
        "lighthouse_audit",
        "list_console_messages",
        "performance_analyze_insight",
        "performance_start_trace",
        "performance_stop_trace",
        "take_heapsnapshot",
    ]
    // chrome-devtools-mcp-contract:user-activation-source-proven-background-end

    /// Raw names advertised to background callers. Runtime-state-dependent routes stay hidden because their safe
    /// branch cannot be proven from request arguments before provider entry.
    static let backgroundCatalogToolNames = Self.sourceProvenBackgroundToolNames.union([
        "fill_form",
        "get_network_request",
        "take_screenshot",
    ])

    /// Typed wrapper actions that retain at least one source-proven background route.
    static let backgroundCatalogActions: Set<BrowserAction> = [
        .status,
        .disconnect,
        .console,
        .network,
        .screenshot,
        .performanceTrace,
        .call,
    ]

    static func catalogToolNames(foregroundCapable: Bool) -> [String] {
        let names = foregroundCapable
            ? BrowserMCPPageRoutingContract.pageTargetedToolNames.union(BrowserMCPPageRoutingContract.globalToolNames)
            : self.backgroundCatalogToolNames
        return names.sorted()
    }

    static func decision(for call: BrowserMCPMappedCall) -> Decision {
        let toolName = call.toolName
        if self.sourceProvenBackgroundToolNames.contains(toolName) {
            return .sourceProvenBackground
        }
        if self.alwaysForegroundToolNames.contains(toolName) {
            return .foregroundRequired("\(toolName) can grant browser user activation")
        }

        switch toolName {
        case "fill_form":
            guard let elements = call.arguments["elements"] as? [Any],
                  elements.isEmpty,
                  call.arguments["includeSnapshot"] as? Bool != true
            else {
                return .foregroundRequired(
                    "fill_form can evaluate page elements or an included snapshot with browser user activation")
            }
            return .sourceProvenBackground
        case "get_network_request":
            guard let requestID = call.arguments["reqid"] as? Int, requestID > 0 else {
                return .foregroundRequired(
                    "get_network_request without a positive reqid evaluates DevTools page state with browser user " +
                        "activation")
            }
            return .sourceProvenBackground
        case "get_console_message":
            return .foregroundRequired(
                "get_console_message can serialize a page object through browser user activation")
        case "list_network_requests", "take_snapshot":
            return .foregroundRequired(
                "\(toolName) can evaluate an open DevTools page with browser user activation")
        case "take_screenshot":
            guard call.arguments["uid"] == nil else {
                return .foregroundRequired(
                    "take_screenshot with uid evaluates element geometry with browser user activation")
            }
            return .sourceProvenBackground
        default:
            return .foregroundRequired(
                "\(toolName) has no source-proven no-evaluation path in the pinned browser provider")
        }
    }

    static func foregroundRequirement(
        for calls: [BrowserMCPMappedCall]) -> Decision
    {
        for call in calls {
            let decision = self.decision(for: call)
            if decision.requiresForegroundAuthority {
                return decision
            }
        }
        return .sourceProvenBackground
    }
}
