import Foundation
import MCP
import PeekabooCore
import PeekabooFoundation
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
        let tool = BrowserTool(client: client, executionPolicy: .unrestricted)

        let response = try await tool.execute(arguments: ToolArguments(raw: ["action": "status"]))

        #expect(response.isError == false)
        let text = Self.text(from: response)
        #expect(text.contains("Connected: no"))
        #expect(text.contains("chrome://inspect/#remote-debugging"))
        #expect(text.contains("remote debugging permission prompt"))
    }

    @Test
    func `Browser tool legacy client refuses connect and mapped mutation without outcomes`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: true,
            toolCount: 31,
            detectedBrowsers: []))
        let tool = BrowserTool(client: client, executionPolicy: .unrestricted)

        let connect = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "connect",
            "channel": "canary",
        ]))
        #expect(connect.isError)
        #expect(client.connectedChannels.isEmpty)
        #expect(Self.text(from: connect).contains(
            "Browser connect requires a provider that reports canonical action outcomes."))
        #expect(connect.meta?.objectValue?["refusal_reason"] == .string("operation_unsupported"))

        let click = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "click",
            "page_id": 4,
            "uid": "7_1",
        ]))
        #expect(click.isError)
        #expect(Self.text(from: click).contains(
            "Browser mutations require a provider that reports canonical action outcomes."))
        let meta = try #require(click.meta?.objectValue)
        #expect(meta["state"] == .string("refused"))
        #expect(meta["refusal_reason"] == .string("operation_unsupported"))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(client.executedTools.isEmpty)
    }

    @Test
    func `Browser tool sends targeted type as one client-owned sequence`() async throws {
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let client = OutcomeBrowserMCPClient(result: .init(
            payload: .text("typed"),
            outcome: outcome))
        let tool = BrowserTool(client: client, executionPolicy: .unrestricted)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "type",
            "page_id": 7,
            "uid": "7_9",
            "text": "typed",
        ]))

        #expect(!response.isError)
        let sequence = try #require(client.executedSequences.first)
        #expect(sequence.map(\.toolName) == ["click", "type_text"])
        #expect(sequence[0].arguments["uid"] as? String == "7_9")
    }

    @Test
    func `Browser tool namespaces provider metadata and strips reserved semantic claims`() async throws {
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let client = OutcomeBrowserMCPClient(result: .init(
            payload: .text("typed", meta: .object([
                "error_code": .string("provider-spoof"),
                "provider_field": .string("preserved"),
                "state": .string("confirmed_change"),
                "target_identity": .object(["kind": .string("provider-spoof")]),
                "target_receipt": .object(["window_id": .int(999)]),
                "turn_boundary": .object([
                    "stop_agent": .bool(true),
                    "reason": .string("provider-spoof"),
                ]),
            ])),
            outcome: outcome))
        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted)
            .execute(arguments: ToolArguments(raw: [
                "action": "type",
                "page_id": 7,
                "uid": "7_9",
                "text": "typed",
            ]))

        #expect(!response.isError)
        let meta = try #require(response.meta?.objectValue)
        let providerMeta = try #require(meta["provider_meta"]?.objectValue)
        #expect(providerMeta == ["provider_field": .string("preserved")])
        #expect(meta["error_code"] == nil)
        #expect(meta["target_identity"] == nil)
        #expect(meta["target_receipt"] == nil)
        #expect(meta["turn_boundary"] == nil)
        #expect(meta["state"] == .string("dispatched_unverified"))
        #expect(meta["dispatch_state"] == .string("dispatched"))
        #expect(meta["dispatched_unit_count"] == .int(2))
        #expect(meta["retry_safety"] == .string("unsafe"))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["mutation_dispatched"] == .bool(true))
    }

    @Test
    func `Browser tool rejects mutation result without canonical outcome`() async throws {
        let legacyMeta: Value = .object([
            "provider_field": .string("legacy"),
            "state": .string("provider-defined"),
        ])
        let client = OutcomeBrowserMCPClient(result: .init(
            payload: .text("legacy", meta: legacyMeta),
            outcome: nil))
        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted)
            .execute(arguments: ToolArguments(raw: [
                "action": "click",
                "page_id": 7,
                "uid": "7_9",
            ]))

        #expect(response.isError)
        #expect(Self.text(from: response).contains("Browser mutation returned without a canonical action outcome."))
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatch_state"] == .string("may_have_dispatched"))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["requires_fresh_observation"] == .bool(true))
        #expect(meta["provider_meta"] == nil)
    }

    @Test
    func `Browser tool allows outcome-free result from read-only provider call`() async throws {
        let legacyMeta: Value = .object([
            "provider_field": .string("legacy"),
            "state": .string("provider-defined"),
        ])
        let client = OutcomeBrowserMCPClient(result: .init(
            payload: .text("snapshot", meta: legacyMeta),
            outcome: nil))
        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted)
            .execute(arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": 7,
            ]))

        #expect(!response.isError)
        #expect(response.meta == .object([
            "provider_meta": .object(["provider_field": .string("legacy")]),
        ]))
    }

    @Test
    func `Browser tool rejects successful payload paired with non-success outcome`() async throws {
        let delivery = DesktopActionOutcome.Delivery(mechanism: .browserProtocol, mode: .background)
        let cases: [DesktopActionOutcome] = [
            .partial(delivery: delivery, unitCount: .one),
            .suspectedNoop(delivery: delivery, unitCount: .one),
            .refused(reason: .targetUnavailable),
            .indeterminate(delivery: delivery, evidence: .completionUnknown, unitCount: .one),
        ]

        for outcome in cases {
            let client = OutcomeBrowserMCPClient(result: .init(
                payload: .text("provider claimed success"),
                outcome: outcome))
            let response = try await BrowserTool(client: client, executionPolicy: .unrestricted)
                .execute(arguments: ToolArguments(raw: [
                    "action": "click",
                    "page_id": 7,
                    "uid": "7_9",
                ]))

            #expect(response.isError, "Expected \(outcome.state.rawValue) to reject a successful payload")
            #expect(Self.text(from: response).contains(
                "Browser mutation did not return a successful canonical outcome."))
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["state"] == .string(outcome.state.rawValue))
        }
    }

    @Test
    func `Browser tool rejects error payload paired with success-compatible outcome`() async throws {
        let delivery = DesktopActionOutcome.Delivery(mechanism: .browserProtocol, mode: .background)
        let cases: [DesktopActionOutcome] = [
            .confirmedChange(delivery: delivery, unitCount: .one),
            .confirmedNoChange(),
            .dispatchedUnverified(delivery: delivery, evidence: .deliveryAccepted, unitCount: .one),
        ]

        for outcome in cases {
            let client = OutcomeBrowserMCPClient(result: .init(
                payload: .error("provider claimed failure"),
                outcome: outcome))
            let response = try await BrowserTool(client: client, executionPolicy: .unrestricted)
                .execute(arguments: ToolArguments(raw: [
                    "action": "click",
                    "page_id": 7,
                    "uid": "7_9",
                ]))

            #expect(response.isError, "Expected \(outcome.state.rawValue) to reject an error payload")
            #expect(Self.text(from: response).contains(
                "Browser provider returned an error payload with a successful canonical outcome."))
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["state"] == .string("indeterminate"))
            #expect(meta["requires_fresh_observation"] == .bool(true))
        }
    }

    @Test
    func `Browser tool projects retry safe zero progress refusal`() async throws {
        let outcome = DesktopActionOutcome.refused(route: .bridge, reason: .targetUnavailable)
        let client = OutcomeBrowserMCPClient(result: .init(
            payload: .error("browser target changed"),
            outcome: outcome))
        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted)
            .execute(arguments: ToolArguments(raw: [
                "action": "click",
                "page_id": 7,
                "uid": "7_9",
            ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("refused"))
        #expect(meta["dispatch_state"] == .string("none"))
        #expect(meta["dispatched_unit_count"] == nil)
        #expect(meta["refusal_reason"] == .string("target_unavailable"))
        #expect(meta["retry_safety"] == .string("safe"))
        #expect(meta["retry_safe"] == .bool(true))
    }

    @Test
    func `Browser tool projects positive failed progress with exact unsafe unit count`() async throws {
        let outcome = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let client = OutcomeBrowserMCPClient(result: .init(
            payload: .error("second browser call completion unknown"),
            outcome: outcome))
        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted)
            .execute(arguments: ToolArguments(raw: [
                "action": "type",
                "page_id": 7,
                "uid": "7_9",
                "text": "typed",
            ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatch_state"] == .string("may_have_dispatched"))
        #expect(meta["dispatched_unit_count"] == .int(2))
        #expect(meta["retry_safety"] == .string("unsafe"))
        #expect(meta["requires_fresh_observation"] == .bool(true))
    }

    @Test
    func `Browser tool projects unknown progress without inventing a unit count`() async throws {
        let outcome = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown)
        let client = OutcomeBrowserMCPClient(result: .init(
            payload: .error("browser completion unknown"),
            outcome: outcome))
        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted)
            .execute(arguments: ToolArguments(raw: [
                "action": "click",
                "page_id": 7,
                "uid": "7_9",
            ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatch_state"] == .string("may_have_dispatched"))
        #expect(meta["dispatched_unit_count"] == nil)
        #expect(meta["retry_safety"] == .string("unsafe"))
        #expect(meta["requires_fresh_observation"] == .bool(true))
    }

    @Test
    func `Browser tool projects a thrown canonical refusal for result-aware clients`() async throws {
        let failure = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .operationUnsupported,
            message: "browser provider is unsupported")
        let client = OutcomeBrowserMCPClient(failure: failure)
        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted)
            .execute(arguments: ToolArguments(raw: [
                "action": "click",
                "page_id": 7,
                "uid": "7_9",
            ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("refused"))
        #expect(meta["refusal_reason"] == .string("operation_unsupported"))
        #expect(meta["retry_safe"] == .bool(true))
    }

    @Test
    func `Browser tool rejects endpoint on non-connect action`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: []))
        let tool = BrowserTool(client: client, executionPolicy: .unrestricted)

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
        let tool = BrowserTool(client: client, executionPolicy: .unrestricted)

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
        let tool = BrowserTool(client: client, executionPolicy: .unrestricted)

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
        let tool = BrowserTool(client: client, executionPolicy: .unrestricted)

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
        let tool = BrowserTool(client: client, executionPolicy: .unrestricted)

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
        let tool = BrowserTool(client: client, executionPolicy: .unrestricted)

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
        let tool = BrowserTool(client: client, executionPolicy: .unrestricted)

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
        let tool = BrowserTool(client: client, executionPolicy: .unrestricted)

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
        let tool = BrowserTool(client: client, executionPolicy: .unrestricted)

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
        let tool = BrowserTool(client: client, executionPolicy: .unrestricted)

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
        #expect(BrowserMCPPageRoutingContract.readOnlyToolNames.count == 27)
        #expect(BrowserMCPPageRoutingContract.mutatingToolNames.count == 23)
        #expect(BrowserMCPPageRoutingContract.argumentDependentToolNames == [
            "performance_start_trace",
            "select_page",
        ])
        #expect(BrowserMCPPageRoutingContract.allSemanticToolNames == BrowserMCPPageRoutingContract.allToolNames)
        #expect(BrowserMCPPageRoutingContract.readOnlyToolNames.isDisjoint(
            with: BrowserMCPPageRoutingContract.mutatingToolNames))
        #expect(BrowserMCPPageRoutingContract.readOnlyToolNames.isDisjoint(
            with: BrowserMCPPageRoutingContract.argumentDependentToolNames))
        #expect(BrowserMCPPageRoutingContract.mutatingToolNames.isDisjoint(
            with: BrowserMCPPageRoutingContract.argumentDependentToolNames))
    }

    @Test
    func `Audited browser semantics classify mapped and raw argument dependent calls`() {
        #expect(BrowserMCPPageRoutingContract.actionSemantics(
            for: "list_pages",
            arguments: [:]) == .readOnly)
        #expect(BrowserMCPPageRoutingContract.actionSemantics(
            for: "take_snapshot",
            arguments: ["filePath": "/tmp/page.txt"]) == .readOnly)
        #expect(BrowserMCPPageRoutingContract.actionSemantics(
            for: "click",
            arguments: ["uid": "7_1"]) == .mutating)
        #expect(BrowserMCPPageRoutingContract.actionSemantics(
            for: "select_page",
            arguments: ["bringToFront": false]) == .readOnly)
        #expect(BrowserMCPPageRoutingContract.actionSemantics(
            for: "select_page",
            arguments: ["bringToFront": true]) == .mutating)
        #expect(BrowserMCPPageRoutingContract.actionSemantics(
            for: "performance_start_trace",
            arguments: ["reload": false]) == .readOnly)
        #expect(BrowserMCPPageRoutingContract.actionSemantics(
            for: "performance_start_trace",
            arguments: [:]) == .mutating)
        #expect(BrowserMCPPageRoutingContract.actionSemantics(
            for: "unknown_future_tool",
            arguments: [:]) == nil)
    }

    @Test
    func `Browser snapshot mutation policy shares mapped and raw call semantics`() {
        func effect(_ raw: [String: Any]) -> MCPToolSnapshotEffect {
            MCPToolSnapshotMutationPolicy.effect(
                toolName: "browser",
                arguments: ToolArguments(raw: raw))
        }

        #expect(effect(["action": "list_pages"]) == .none)
        #expect(effect(["action": "status"]) == .none)
        #expect(effect(["action": "disconnect"]) == .none)
        #expect(effect(["action": "connect"]) == .mutation)
        #expect(effect([
            "action": "call",
            "mcp_tool": "take_snapshot",
            "page_id": 7,
        ]) == .none)
        #expect(effect([
            "action": "call",
            "mcp_tool": "list_pages",
        ]) == .none)
        #expect(effect([
            "action": "select_page",
            "page_id": 7,
            "bring_to_front": false,
        ]) == .none)
        #expect(effect([
            "action": "performance_trace",
            "page_id": 7,
            "trace_action": "start",
            "reload": false,
        ]) == .none)

        #expect(effect([
            "action": "click",
            "page_id": 7,
            "uid": "7_1",
        ]) == .mutation)
        #expect(effect([
            "action": "call",
            "mcp_tool": "click",
            "page_id": 7,
            "mcp_args_json": #"{"uid":"7_1"}"#,
        ]) == .mutation)
        #expect(effect([
            "action": "select_page",
            "page_id": 7,
            "bring_to_front": true,
        ]) == .mutation)
        #expect(effect([
            "action": "performance_trace",
            "page_id": 7,
            "trace_action": "start",
        ]) == .mutation)
        #expect(effect([
            "action": "call",
            "mcp_tool": "future_tool",
        ]) == .none)
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
            browser: client,
            executionPolicy: .unrestricted)
        let tool = BrowserTool(context: context)

        _ = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "list_pages",
        ]))

        #expect(client.executedTools.last?.toolName == "list_pages")
    }

    @Test
    func `Browser execution publishes exact connection and progress evidence`() async throws {
        let payload = BrowserMCPExecutionEvidence.attaching(
            to: .text("ok"),
            connectionReceipt: BrowserMCPConnectionReceipt(
                channel: .stable,
                processIdentifier: 42,
                processStartIdentity: 1001,
                bundleIdentifier: "com.google.Chrome",
                browserURL: "http://127.0.0.1:9222/",
                webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
                devToolsBrowserID: "browser-a"),
            completedCallCount: 1,
            dispatchedCallCount: 1)
        let client = OutcomeBrowserMCPClient(result: DesktopActionResult(payload: payload, outcome: nil))
        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted).execute(
            arguments: ToolArguments(raw: ["action": "list_pages"]))

        let meta = try #require(response.meta?.objectValue)
        let execution = try #require(meta[BrowserMCPExecutionEvidence.metadataKey]?.objectValue)
        #expect(execution["completed_call_count"] == .int(1))
        #expect(execution["dispatched_call_count"] == .int(1))
        let receipt = try #require(execution["connection_receipt"]?.objectValue)
        #expect(receipt["channel"] == .string("stable"))
        #expect(receipt["pid"] == .int(42))
        #expect(receipt["process_start_identity_decimal"] == .string("1001"))
        #expect(receipt["browser_id"] == .string("browser-a"))
    }

    private static func text(from response: ToolResponse) -> String {
        guard case let .text(text: text, annotations: _, _meta: _) = response.content.first else {
            return ""
        }
        return text
    }
}

extension BrowserToolTests {
    @Test
    func `default Browser tool requires an existing connection and returns canonical refusal`() async throws {
        let client = ConnectionPolicyBrowserMCPClient()
        let response = try await BrowserTool(client: client).execute(arguments: ToolArguments(raw: [
            "action": "list_pages",
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("refused"))
        #expect(meta["refusal_reason"] == .string("target_unavailable"))
        #expect(meta["dispatch_state"] == .string("none"))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(client.connectionPolicies == [.requireExistingLiveReceipt])
        #expect(client.connectCount == 0)
        #expect(client.executedTools.isEmpty)
    }

    @Test
    func `default standalone Browser tool refuses connect before provider invocation`() async throws {
        let client = ConnectionPolicyBrowserMCPClient()
        let response = try await BrowserTool(client: client).execute(arguments: ToolArguments(raw: [
            "action": "connect",
            "channel": "stable",
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["execution_policy"] == .string("background_only"))
        #expect(meta["refusal_reason"] == .string("foreground_consent_required"))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(client.connectionPolicies.isEmpty)
        #expect(client.connectCount == 0)
        #expect(client.executedTools.isEmpty)
    }

    @Test
    func `background only Browser tool refuses legacy read provider before execution`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
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
            browser: client,
            executionPolicy: .backgroundOnly)

        let response = try await BrowserTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "list_pages",
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("refused"))
        #expect(meta["refusal_reason"] == .string("operation_unsupported"))
        #expect(meta["dispatch_state"] == .string("none"))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(client.connectedChannels.isEmpty)
        #expect(client.executedSequences.isEmpty)
        #expect(client.executedTools.isEmpty)
    }
}

@MainActor
private final class ConnectionPolicyBrowserMCPClient: BrowserMCPClientProviding, BrowserMCPActionResultProviding,
    @unchecked Sendable
{
    private(set) var connectionPolicies: [BrowserMCPExecutionConnectionPolicy] = []
    private(set) var connectCount = 0
    private(set) var executedTools: [String] = []

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
    }

    func connect(channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        self.connectCount += 1
        return await self.status(channel: channel)
    }

    func disconnect() async {}

    func execute(
        toolName: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        self.executedTools.append(toolName)
        return .text("unexpected dispatch")
    }

    func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel _: BrowserMCPChannel?) async throws -> DesktopActionResult<ToolResponse>
    {
        self.executedTools.append(contentsOf: calls.map(\.toolName))
        return DesktopActionResult(payload: .text("unexpected dispatch"), outcome: nil)
    }

    func executeSequenceWithOutcome(
        _: [BrowserMCPMappedCall],
        channel _: BrowserMCPChannel?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy) async throws -> DesktopActionResult<ToolResponse>
    {
        self.connectionPolicies.append(connectionPolicy)
        guard connectionPolicy == .allowAutoConnect else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Browser execution requires an existing live exact connection receipt.",
                hint: "Connect the intended browser explicitly and retry.")
        }
        return DesktopActionResult(payload: .text("allowed"), outcome: nil)
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

@MainActor
private final class OutcomeBrowserMCPClient: BrowserMCPClientProviding, BrowserMCPActionResultProviding,
    @unchecked Sendable
{
    private let result: DesktopActionResult<ToolResponse>?
    private let failure: DesktopActionFailure?
    private(set) var executedSequences: [[BrowserMCPMappedCall]] = []

    init(result: DesktopActionResult<ToolResponse>) {
        self.result = result
        self.failure = nil
    }

    init(failure: DesktopActionFailure) {
        self.result = nil
        self.failure = failure
    }

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        BrowserMCPStatus(isConnected: true, toolCount: 1, detectedBrowsers: [])
    }

    func connect(channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        await self.status(channel: channel)
    }

    func disconnect() async {}

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        try self.resolvedResult().payload
    }

    func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel _: BrowserMCPChannel?) async throws -> DesktopActionResult<ToolResponse>
    {
        self.executedSequences.append(calls)
        return try self.resolvedResult()
    }

    private func resolvedResult() throws -> DesktopActionResult<ToolResponse> {
        if let failure {
            throw failure
        }
        return try #require(self.result)
    }
}
