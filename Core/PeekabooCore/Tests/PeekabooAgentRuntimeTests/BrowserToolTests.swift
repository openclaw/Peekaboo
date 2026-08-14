import Foundation
import MCP
import PeekabooCore
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserToolTests {
    @Test
    func `Chrome DevTools config uses auto connect and privacy flags`() {
        let config = BrowserMCPService.chromeDevToolsConfig(channel: .beta)

        #expect(config.command == "npx")
        #expect(config.args.contains("chrome-devtools-mcp@1.6.0"))
        #expect(config.args.contains("--experimentalPageIdRouting"))
        #expect(config.args.contains("--auto-connect"))
        #expect(config.args.contains("--channel=beta"))
        #expect(config.args.contains("--no-usage-statistics"))
        #expect(config.args.contains("--no-performance-crux"))
    }

    @Test
    func `Chrome DevTools config can launch isolated headless browser for deterministic tests`() {
        let config = BrowserMCPService.chromeDevToolsConfig(
            channel: .stable,
            environment: [
                "PEEKABOO_BROWSER_MCP_ISOLATED": "1",
                "PEEKABOO_BROWSER_MCP_HEADLESS": "true",
            ])

        #expect(!config.args.contains("--auto-connect"))
        #expect(config.args.contains("--isolated"))
        #expect(config.args.contains("--headless"))
        #expect(config.args.contains("--channel=stable"))
        #expect(config.args.contains("--experimentalPageIdRouting"))
        #expect(config.args.contains("--no-usage-statistics"))
        #expect(config.args.contains("--no-performance-crux"))
    }

    @Test
    func `Chrome DevTools config can target explicit browser URL`() {
        let config = BrowserMCPService.chromeDevToolsConfig(
            channel: .canary,
            environment: [
                "PEEKABOO_BROWSER_MCP_BROWSER_URL": "http://127.0.0.1:9222",
            ])

        #expect(!config.args.contains("--auto-connect"))
        #expect(!config.args.contains("--channel=canary"))
        #expect(config.args.contains("--browserUrl=http://127.0.0.1:9222"))
        #expect(config.args.contains("--experimentalPageIdRouting"))
        #expect(config.args.contains("--no-usage-statistics"))
        #expect(config.args.contains("--no-performance-crux"))
    }

    @Test
    func `Browser call mapper maps common actions`() throws {
        let click = try BrowserMCPCallMapper.map(
            action: .click,
            arguments: ToolArguments(raw: [
                "page_id": 7,
                "uid": "1_2",
                "double": true,
                "include_snapshot": true,
            ]))
        #expect(click.toolName == "click")
        #expect(click.arguments["pageId"] as? Int == 7)
        #expect(click.arguments["uid"] as? String == "1_2")
        #expect(click.arguments["dblClick"] as? Bool == true)
        #expect(click.arguments["includeSnapshot"] as? Bool == true)

        let navigate = try BrowserMCPCallMapper.map(
            action: .navigate,
            arguments: ToolArguments(raw: ["page_id": 8, "url": "https://example.com", "timeout": 10000]))
        #expect(navigate.toolName == "navigate_page")
        #expect(navigate.arguments["pageId"] as? Int == 8)
        #expect(navigate.arguments["type"] as? String == "url")
        #expect(navigate.arguments["url"] as? String == "https://example.com")
        #expect(navigate.arguments["timeout"] as? Int == 10000)

        let network = try BrowserMCPCallMapper.map(
            action: .network,
            arguments: ToolArguments(raw: ["page_id": 9, "request_id": 42]))
        #expect(network.toolName == "get_network_request")
        #expect(network.arguments["pageId"] as? Int == 9)
        #expect(network.arguments["reqid"] as? Int == 42)

        let trace = try BrowserMCPCallMapper.map(
            action: .performanceTrace,
            arguments: ToolArguments(raw: [
                "page_id": 10,
                "trace_action": "start",
                "reload": false,
                "auto_stop": true,
            ]))
        #expect(trace.toolName == "performance_start_trace")
        #expect(trace.arguments["pageId"] as? Int == 10)
        #expect(trace.arguments["reload"] as? Bool == false)
        #expect(trace.arguments["autoStop"] as? Bool == true)
    }

    @Test
    func `Browser call mapper defaults page lifecycle actions to background`() throws {
        let select = try BrowserMCPCallMapper.map(
            action: .selectPage,
            arguments: ToolArguments(raw: ["page_id": 3]))
        #expect(select.arguments["bringToFront"] as? Bool == false)

        let newPage = try BrowserMCPCallMapper.map(
            action: .newPage,
            arguments: ToolArguments(raw: ["url": "https://example.com"]))
        #expect(newPage.arguments["background"] as? Bool == true)

        let foregroundPage = try BrowserMCPCallMapper.map(
            action: .newPage,
            arguments: ToolArguments(raw: ["url": "https://example.com", "background": false]))
        #expect(foregroundPage.arguments["background"] as? Bool == false)
    }

    @Test(arguments: [
        BrowserAction.click,
        .fill,
        .drag,
        .hover,
        .uploadFile,
        .screenshot,
    ])
    func `Browser mapper forwards every declared page selector`(action: BrowserAction) throws {
        let raw: [String: Any] = switch action {
        case .click:
            ["page_id": 17, "uid": "17_1", "double": true, "include_snapshot": true]
        case .fill:
            ["page_id": 17, "uid": "17_2", "value": "value", "include_snapshot": true]
        case .drag:
            ["page_id": 17, "uid": "17_3", "to_uid": "17_4", "include_snapshot": true]
        case .hover:
            ["page_id": 17, "uid": "17_5", "include_snapshot": true]
        case .uploadFile:
            ["page_id": 17, "uid": "17_6", "path": "/tmp/fixture", "include_snapshot": true]
        case .screenshot:
            ["page_id": 17, "uid": "17_7", "path": "/tmp/fixture.png"]
        default:
            [:]
        }

        let call = try BrowserMCPCallMapper.map(action: action, arguments: ToolArguments(raw: raw))
        #expect(call.arguments["pageId"] as? Int == 17)
        #expect(call.arguments["uid"] as? String == raw["uid"] as? String || action == .drag)
        if action == .drag {
            #expect(call.arguments["from_uid"] as? String == "17_3")
            #expect(call.arguments["to_uid"] as? String == "17_4")
        }
        if action == .fill {
            #expect(call.arguments["value"] as? String == "value")
        }
        if action == .uploadFile {
            #expect(call.arguments["filePath"] as? String == "/tmp/fixture")
        }
    }

    @Test(arguments: [BrowserAction.type, .pressKey])
    func `Browser keyboard actions require exact uid and map atomic focus sequence`(action: BrowserAction) throws {
        let raw: [String: Any] = action == .type
            ? ["page_id": 21, "uid": "21_8", "text": "typed", "submit_key": "Tab"]
            : ["page_id": 21, "uid": "21_8", "key": "Enter", "include_snapshot": true]
        let calls = try BrowserMCPCallMapper.mapSequence(action: action, arguments: ToolArguments(raw: raw))

        #expect(calls.count == 2)
        #expect(calls[0].toolName == "click")
        #expect(calls[0].arguments["uid"] as? String == "21_8")
        #expect(calls[0].arguments["pageId"] as? Int == 21)
        #expect(calls[1].toolName == (action == .type ? "type_text" : "press_key"))
        #expect(calls[1].arguments["pageId"] as? Int == 21)

        #expect(throws: (any Error).self) {
            _ = try BrowserMCPCallMapper.mapSequence(
                action: action,
                arguments: ToolArguments(raw: action == .type
                    ? ["page_id": 21, "text": "typed"]
                    : ["page_id": 21, "key": "Enter"]))
        }
    }

    @Test
    func `Browser call mapper preserves MCP-decoded data URLs`() throws {
        let encodedURL: Value = .data(mimeType: "text/html", Data("ALPHA_CONTENT".utf8))
        let newPage = try BrowserMCPCallMapper.map(
            action: .newPage,
            arguments: ToolArguments(value: .object(["url": encodedURL])))

        #expect(newPage.arguments["url"] as? String == encodedURL.description)
        #expect((newPage.arguments["url"] as? String)?.hasPrefix("data:text/html;base64,") == true)
    }

    @Test
    func `Browser call mapper rejects unscoped page actions`() {
        #expect(throws: (any Error).self) {
            _ = try BrowserMCPCallMapper.map(
                action: .snapshot,
                arguments: ToolArguments(raw: [:]))
        }
    }

    @Test
    func `Browser call mapper rejects fractional page IDs instead of truncating`() {
        #expect(throws: (any Error).self) {
            _ = try BrowserMCPCallMapper.map(
                action: .snapshot,
                arguments: ToolArguments(raw: ["page_id": 2.9]))
        }
    }

    @Test
    func `Browser tool status includes permission instructions when disconnected`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: []))
        let tool = BrowserTool(client: client)

        let response = try await tool.execute(arguments: ToolArguments(raw: ["action": "status"]))

        #expect(response.isError == false)
        let text = Self.text(from: response)
        #expect(text.contains("Connected: no"))
        #expect(text.contains("chrome://inspect/#remote-debugging"))
        #expect(text.contains("remote debugging permission prompt"))
    }

    @Test
    func `Browser tool connect and mapped execute use client`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: true,
            toolCount: 31,
            detectedBrowsers: []))
        let tool = BrowserTool(client: client)

        let connect = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "connect",
            "channel": "canary",
        ]))
        #expect(connect.isError == false)
        #expect(client.connectedChannels == [.canary])

        let click = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "click",
            "page_id": 4,
            "uid": "7_1",
        ]))
        #expect(click.isError == false)
        #expect(client.executedTools.last?.toolName == "click")
        #expect(client.executedTools.last?.arguments["pageId"] as? Int == 4)
        #expect(client.executedTools.last?.arguments["uid"] as? String == "7_1")
        #expect(client.executedTools.last?.channel == nil)
    }

    @Test
    func `Browser tool sends targeted type as one client-owned sequence`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: true,
            toolCount: 29,
            detectedBrowsers: []))
        let tool = BrowserTool(client: client)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "type",
            "page_id": 7,
            "uid": "7_9",
            "text": "typed",
        ]))

        #expect(!response.isError)
        #expect(client.executedSequences.count == 1)
        #expect(client.executedSequences[0].map(\.toolName) == ["click", "type_text"])
        #expect(client.executedSequences[0][0].arguments["uid"] as? String == "7_9")
    }

    @Test
    func `Browser tool forwards exact endpoint and reports connection receipt`() async throws {
        let receipt = BrowserMCPConnectionReceipt(
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: true,
            toolCount: 29,
            detectedBrowsers: [],
            connectionReceipt: receipt))
        let tool = BrowserTool(client: client)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "connect",
            "browser_url": "http://127.0.0.1:9222",
        ]))

        #expect(!response.isError)
        #expect(client.connectedBrowserURLs == ["http://127.0.0.1:9222"])
        #expect(Self.text(from: response).contains("browser_id=browser-a"))
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected browser status metadata")
            return
        }
        guard case let .object(receiptMeta) = meta["connection_receipt"] else {
            Issue.record("Expected exact connection receipt")
            return
        }
        #expect(receiptMeta["browser_id"] == .string("browser-a"))
    }

    @Test
    func `Browser tool rejects endpoint on non-connect action`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: []))
        let tool = BrowserTool(client: client)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "list_pages",
            "browser_url": "http://127.0.0.1:9222",
        ]))

        #expect(response.isError)
        #expect(Self.text(from: response) == "browser_url is accepted only by the connect action")
        #expect(client.executedTools.isEmpty)
    }

    @Test
    func `Browser tool forwards channel for first mapped execute`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: true,
            toolCount: 31,
            detectedBrowsers: []))
        let tool = BrowserTool(client: client)

        let snapshot = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "snapshot",
            "channel": "canary",
            "page_id": 5,
        ]))

        #expect(snapshot.isError == false)
        #expect(client.executedTools.last?.toolName == "take_snapshot")
        #expect(client.executedTools.last?.channel == .canary)
    }

    @Test
    func `Browser tool rejects invalid channel instead of silently using default`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: true,
            toolCount: 31,
            detectedBrowsers: []))
        let tool = BrowserTool(client: client)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "list_pages",
            "channel": "chrome",
        ]))

        #expect(response.isError == true)
        #expect(Self.text(from: response).contains("Invalid browser channel: chrome"))
        #expect(client.executedTools.isEmpty)
    }

    @Test
    func `Browser tool reports local validation errors without permission instructions`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: true,
            toolCount: 31,
            detectedBrowsers: []))
        let tool = BrowserTool(client: client)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "snapshot",
        ]))
        let text = Self.text(from: response)

        #expect(response.isError == true)
        #expect(text == "page_id must be a non-negative integer from list_pages")
        #expect(!text.contains("remote debugging"))
        #expect(client.executedTools.isEmpty)
    }

    @Test
    func `Browser raw call forwards wrapper page ID`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: true,
            toolCount: 31,
            detectedBrowsers: []))
        let tool = BrowserTool(client: client)

        _ = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "call",
            "mcp_tool": "take_snapshot",
            "mcp_args_json": #"{"pageId":99}"#,
            "page_id": 12,
        ]))

        #expect(client.executedTools.last?.toolName == "take_snapshot")
        #expect(client.executedTools.last?.arguments["pageId"] as? Int == 12)
    }

    @Test
    func `Browser raw page-scoped call rejects missing wrapper page ID`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: true,
            toolCount: 31,
            detectedBrowsers: []))
        let tool = BrowserTool(client: client)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "call",
            "mcp_tool": "take_snapshot",
            "mcp_args_json": #"{"pageId":12}"#,
        ]))

        #expect(response.isError == true)
        #expect(Self.text(from: response) == "page_id must be a non-negative integer from list_pages")
        #expect(client.executedTools.isEmpty)
    }

    @Test
    func `Browser raw call rejects fractional wrapper page ID`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: true,
            toolCount: 31,
            detectedBrowsers: []))
        let tool = BrowserTool(client: client)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "call",
            "mcp_tool": "take_snapshot",
            "page_id": 2.9,
        ]))

        #expect(response.isError == true)
        #expect(Self.text(from: response) == "page_id must be a non-negative integer from list_pages")
        #expect(client.executedTools.isEmpty)
    }

    @Test
    func `Browser raw call allows audited global tool without page ID`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: true,
            toolCount: 31,
            detectedBrowsers: []))
        let tool = BrowserTool(client: client)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "call",
            "mcp_tool": "list_pages",
        ]))

        #expect(response.isError == false)
        #expect(client.executedTools.last?.toolName == "list_pages")
        #expect(client.executedTools.last?.arguments["pageId"] == nil)
    }

    @Test
    func `Browser raw selected-page tool fails closed before client execution`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: true,
            toolCount: 31,
            detectedBrowsers: []))
        let tool = BrowserTool(client: client)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "call",
            "mcp_tool": "trigger_extension_action",
            "page_id": 12,
        ]))
        let text = Self.text(from: response)

        #expect(response.isError == true)
        #expect(text.contains("shared selected-page state"))
        #expect(text.contains("until upstream adds explicit pageId routing"))
        #expect(client.executedTools.isEmpty)
    }

    @Test
    func `Browser raw call rejects tools outside audited routing contract`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: true,
            toolCount: 31,
            detectedBrowsers: []))
        let tool = BrowserTool(client: client)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "call",
            "mcp_tool": "future_selected_page_escape_hatch",
        ]))

        #expect(response.isError == true)
        #expect(Self.text(from: response).contains("Unsupported raw Chrome DevTools MCP tool"))
        #expect(client.executedTools.isEmpty)
    }

    @Test
    func `Audited browser routing contract partitions pinned tool catalog`() {
        #expect(BrowserMCPPageRoutingContract.dependencyVersion == "1.6.0")
        #expect(BrowserMCPPageRoutingContract.pageScopedToolNames.count == 32)
        #expect(BrowserMCPPageRoutingContract.explicitPageTargetToolNames.count == 3)
        #expect(BrowserMCPPageRoutingContract.globalToolNames.count == 16)
        #expect(BrowserMCPPageRoutingContract.blockedSelectedPageToolNames == ["trigger_extension_action"])
        #expect(BrowserMCPPageRoutingContract.allToolNames.count == 52)
        #expect(BrowserMCPPageRoutingContract.pageTargetedToolNames.isDisjoint(
            with: BrowserMCPPageRoutingContract.globalToolNames))
        #expect(BrowserMCPPageRoutingContract.pageTargetedToolNames.isDisjoint(
            with: BrowserMCPPageRoutingContract.blockedSelectedPageToolNames))
        #expect(BrowserMCPPageRoutingContract.globalToolNames.isDisjoint(
            with: BrowserMCPPageRoutingContract.blockedSelectedPageToolNames))
        #expect(BrowserMCPPageRoutingContract.routing(for: "trigger_extension_action") == .blockedSelectedPage)
    }

    @Test
    func `Browser tool uses browser client from context`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: true,
            toolCount: 1,
            detectedBrowsers: []))
        let services = PeekabooServices()
        let context = MCPToolContext(
            automation: services.automation,
            menu: services.menu,
            windows: services.windows,
            applications: services.applications,
            dialogs: services.dialogs,
            dock: services.dock,
            screenCapture: services.screenCapture,
            desktopObservation: services.desktopObservation,
            snapshots: services.snapshots,
            screens: services.screens,
            agent: nil,
            permissions: services.permissions,
            clipboard: services.clipboard,
            browser: client)
        let tool = BrowserTool(context: context)

        _ = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "list_pages",
        ]))

        #expect(client.executedTools.last?.toolName == "list_pages")
    }

    private static func text(from response: ToolResponse) -> String {
        guard case let .text(text: text, annotations: _, _meta: _) = response.content.first else {
            return ""
        }
        return text
    }
}

@MainActor
private final class MockBrowserMCPClient: BrowserMCPClientProviding, @unchecked Sendable {
    struct ExecutedTool {
        let toolName: String
        let arguments: [String: Any]
        let channel: BrowserMCPChannel?
    }

    var status: BrowserMCPStatus
    var connectedChannels: [BrowserMCPChannel?] = []
    var connectedBrowserURLs: [String?] = []
    var disconnected = false
    var executedTools: [ExecutedTool] = []
    var executedSequences: [[ExecutedTool]] = []

    init(status: BrowserMCPStatus) {
        self.status = status
    }

    func status(channel: BrowserMCPChannel?) async -> BrowserMCPStatus {
        self.status
    }

    func connect(channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        self.connectedChannels.append(channel)
        return self.status
    }

    func connect(channel: BrowserMCPChannel?, browserURL: String?) async throws -> BrowserMCPStatus {
        self.connectedChannels.append(channel)
        self.connectedBrowserURLs.append(browserURL)
        return self.status
    }

    func disconnect() async {
        self.disconnected = true
    }

    func execute(
        toolName: String,
        arguments: [String: Any],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        self.executedTools.append(ExecutedTool(toolName: toolName, arguments: arguments, channel: channel))
        return ToolResponse.text("called \(toolName)")
    }

    func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        let sequence = calls.map { call in
            ExecutedTool(toolName: call.toolName, arguments: call.arguments, channel: channel)
        }
        self.executedSequences.append(sequence)
        self.executedTools.append(contentsOf: sequence)
        return ToolResponse.text("called \(calls.last?.toolName ?? "none")")
    }
}
