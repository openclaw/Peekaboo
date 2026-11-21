import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct BrowserToolCapabilityContractTests {
    @Test
    func `raw global call rejects wrapper page reference`() {
        do {
            _ = try BrowserMCPCallMapper.mapRawCall(arguments: ToolArguments(raw: [
                "mcp_tool": "list_pages",
                "page_id": 7,
            ]))
            Issue.record("Expected global raw tool to reject page_id")
        } catch {
            #expect(error.localizedDescription.contains("does not accept page_id"))
        }
    }

    @Test
    func `audited contract owns exact raw reference paths and response sets`() {
        #expect(BrowserMCPPageRoutingContract.elementReferencePathMarkers == [
            "click.uid",
            "drag.from_uid",
            "drag.to_uid",
            "evaluate_script.args[]",
            "execute_3p_developer_tool.params{*}.uid",
            "fill.uid",
            "fill_form.elements[].uid",
            "get_css_styles.uid",
            "hover.uid",
            "reveal_in_devtools.uid",
            "take_screenshot.uid",
            "upload_file.uid",
        ])
        #expect(BrowserMCPPageRoutingContract.pageResponseToolNames == [
            "close_page", "handle_dialog", "launch_pwa", "list_pages", "navigate_page", "new_page", "resize_page",
            "select_page", "uninstall_pwa",
        ])
        #expect(BrowserMCPPageRoutingContract.snapshotResponseToolNames == [
            "click", "click_at", "drag", "execute_3p_developer_tool", "fill", "fill_form", "hover", "press_key",
            "take_snapshot", "upload_file", "wait_for",
        ])
    }

    @Test
    func `new upstream tools and script file sources do not gain caller authority`() throws {
        #expect(BrowserMCPPageRoutingContract.unavailableToolNames.count == 12)
        for name in BrowserMCPPageRoutingContract.unavailableToolNames {
            #expect(BrowserMCPPageRoutingContract.capabilityContract(for: name) == nil)
            #expect(!BrowserMCPUserActivationPolicy.registeredToolNames.contains(name))
        }
        #expect(BrowserMCPPageRoutingContract.capabilityContract(
            for: "evaluate_script", arguments: ["sourcePath": "/private/script.js"]) == nil)
        #expect(throws: (any Error).self) {
            try BrowserMCPCallMapper.mapRawCall(arguments: ToolArguments(raw: [
                "mcp_tool": "evaluate_script",
                "page_id": 7,
                "mcp_args_json": #"{"sourcePath":"/private/script.js"}"#,
            ]))
        }
        let inline = try BrowserMCPCallMapper.mapRawCall(arguments: ToolArguments(raw: [
            "mcp_tool": "evaluate_script",
            "page_id": 7,
            "mcp_args_json": #"{"function":"() => 42"}"#,
        ]))
        #expect(inline.arguments["pageId"] as? Int == 7)
    }
}
