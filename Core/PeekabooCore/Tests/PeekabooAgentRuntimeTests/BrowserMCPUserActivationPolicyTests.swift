import Testing
@testable import PeekabooAgentRuntime

struct BrowserMCPUserActivationPolicyTests {
    @Test
    func `exact pinned registered catalog has a complete user activation classification`() {
        let registered: Set = [
            "click", "close_page", "drag", "emulate", "evaluate_script", "fill", "fill_form",
            "get_console_message", "get_network_request", "handle_dialog", "hover", "lighthouse_audit",
            "list_console_messages", "list_network_requests", "list_pages", "navigate_page", "new_page",
            "performance_analyze_insight", "performance_start_trace", "performance_stop_trace", "press_key",
            "resize_page", "select_page", "take_heapsnapshot", "take_screenshot", "take_snapshot", "type_text",
            "upload_file", "wait_for",
        ]
        let classified = BrowserMCPUserActivationPolicy.alwaysForegroundToolNames
            .union(BrowserMCPUserActivationPolicy.conditionalToolNames)
            .union(BrowserMCPUserActivationPolicy.sourceProvenBackgroundToolNames)

        #expect(classified == registered)
        #expect(BrowserMCPUserActivationPolicy.alwaysForegroundToolNames.count == 16)
        #expect(BrowserMCPUserActivationPolicy.conditionalToolNames.count == 6)
        #expect(BrowserMCPUserActivationPolicy.sourceProvenBackgroundToolNames.count == 7)
    }

    @Test
    func `always foreground and source proven background sets drive decisions`() {
        for toolName in BrowserMCPUserActivationPolicy.alwaysForegroundToolNames {
            #expect(Self.decision(toolName).requiresForegroundAuthority, "Expected foreground: \(toolName)")
        }
        for toolName in BrowserMCPUserActivationPolicy.sourceProvenBackgroundToolNames {
            #expect(!Self.decision(toolName).requiresForegroundAuthority, "Expected background: \(toolName)")
        }
        #expect(Self.decision("future_provider_tool").requiresForegroundAuthority)
    }

    @Test
    func `conditional routes admit only request proven no user activation variants`() {
        let cases: [(String, [String: Any], Bool)] = [
            ("fill_form", ["elements": []], false),
            ("fill_form", ["elements": [], "includeSnapshot": false], false),
            ("fill_form", ["elements": [["uid": "1_0", "value": "x"]]], true),
            ("fill_form", ["elements": [], "includeSnapshot": true], true),
            ("fill_form", [:], true),
            ("get_network_request", ["reqid": 1], false),
            ("get_network_request", ["reqid": 0], true),
            ("get_network_request", [:], true),
            ("take_screenshot", [:], false),
            ("take_screenshot", ["fullPage": true], false),
            ("take_screenshot", ["uid": "1_0"], true),
            ("get_console_message", ["msgid": 1], true),
            ("list_network_requests", [:], true),
            ("take_snapshot", [:], true),
        ]

        for (toolName, arguments, expectedForeground) in cases {
            #expect(
                Self.decision(toolName, arguments).requiresForegroundAuthority == expectedForeground,
                "Unexpected decision for \(toolName) \(arguments)")
        }
    }

    @Test
    func `background schemas expose only actions and raw names with a request proven safe variant`() {
        #expect(BrowserMCPUserActivationPolicy.backgroundCatalogActions == Set([
            .status, .disconnect, .console, .network, .screenshot, .performanceTrace, .call,
        ]))
        #expect(BrowserMCPUserActivationPolicy.backgroundCatalogToolNames == Set([
            "emulate", "fill_form", "get_network_request", "lighthouse_audit", "list_console_messages",
            "performance_analyze_insight", "performance_start_trace", "performance_stop_trace", "take_heapsnapshot",
            "take_screenshot",
        ]))
    }

    private static func decision(
        _ toolName: String,
        _ arguments: [String: Any] = [:]) -> BrowserMCPUserActivationPolicy.Decision
    {
        BrowserMCPUserActivationPolicy.decision(for: BrowserMCPMappedCall(
            toolName: toolName,
            arguments: arguments))
    }
}
