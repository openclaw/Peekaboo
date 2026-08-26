import Foundation
import MCP
import PeekabooCore
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserToolCapabilityIntegrationTests {
    @Test
    func `BrowserTool projects opaque refs and rejects another context before provider dispatch`() async throws {
        let client = CapabilityBrowserMCPClient()
        let firstContext = Self.context(client: client)
        let secondContext = Self.context(client: client)
        let first = BrowserTool(context: firstContext)
        let second = BrowserTool(context: secondContext)

        let listed = try await firstContext.execute(
            tool: first,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        #expect(pageReference.hasPrefix("bp1_"))
        #expect(!Self.text(from: listed).contains("\n7:"))

        let snapshotted = try await firstContext.execute(
            tool: first,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try Self.elementReference(from: snapshotted)
        #expect(elementReference.hasPrefix("be1_"))
        #expect(!Self.text(from: snapshotted).contains("uid=1_0"))
        #expect(client.sequences.count == 2)
        #expect(client.sequences.last?.first?.arguments["pageId"] as? Int == 7)

        let rejected = try await secondContext.execute(
            tool: second,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        #expect(rejected.isError)
        #expect(Self.text(from: rejected).contains("another or expired provider session"))
        #expect(!Self.text(from: rejected).contains("remote debugging"))
        #expect(client.sequences.count == 2)

        let rawUID = try await firstContext.execute(
            tool: first,
            arguments: ToolArguments(raw: [
                "action": "click",
                "page_id": pageReference,
                "uid": "1_0",
            ]))
        #expect(rawUID.isError)
        #expect(Self.text(from: rawUID).contains("opaque element reference"))
        #expect(!Self.text(from: rawUID).contains("remote debugging"))
        #expect(client.sequences.count == 2)
    }

    @Test
    func `text only daemon responses still mint opaque page and element refs`() async throws {
        let client = CapabilityBrowserMCPClient(structuredResponses: false)
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)

        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try #require(
            Self.text(from: listed).split(separator: "\n").first(where: { $0.hasPrefix("bp1_") })?.split(
                separator: ":").first.map(String.init))
        let snapshot = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let text = Self.text(from: snapshot)

        #expect(text.contains("uid=be1_"))
        #expect(!text.contains("uid=1_0"))
    }

    @Test
    func `raw snapshot and evaluate script resolve only schema owned element positions`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "list_pages",
            ]))
        let pageReference = try Self.pageReference(from: listed)
        let snapshot = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "take_snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try Self.elementReference(from: snapshot)
        let evaluateArguments = #"{"function":"(el) => el.textContent","args":["\#(elementReference)"],"# +
            #""uid":"domain-value"}"#

        _ = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "evaluate_script",
                "page_id": pageReference,
                "mcp_args_json": evaluateArguments,
            ]))

        let call = try #require(client.sequences.last?.last)
        #expect(call.toolName == "evaluate_script")
        #expect(call.arguments["pageId"] as? Int == 7)
        #expect(call.arguments["args"] as? [String] == ["1_0"])
        #expect(call.arguments["uid"] as? String == "domain-value")
    }

    @Test
    func `capability snapshot file output refuses before provider dispatch`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        let before = client.sequences.count

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "take_snapshot",
                "page_id": pageReference,
                "mcp_args_json": #"{"filePath":"/tmp/provider-uids.txt"}"#,
            ]))

        #expect(response.isError)
        #expect(Self.text(from: response).contains("cannot write provider UIDs"))
        #expect(client.sequences.count == before)
    }

    @Test
    func `capability action refuses a receipt without provider child epoch`() async throws {
        let client = CapabilityBrowserMCPClient(providesEpoch: false)
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))

        #expect(response.isError)
        #expect(Self.text(from: response).contains("provider child epoch"))
        #expect(client.sequences.isEmpty)
    }

    @Test
    func `dialog handling does not require a provider snapshot preflight`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)

        _ = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "handle_dialog",
                "page_id": pageReference,
                "dialog_action": "accept",
            ]))

        #expect(client.sequences.last?.map(\.toolName) == ["handle_dialog"])
        #expect(client.elementPreflights.count == 2)
        #expect(client.elementPreflights[1] == nil)
    }

    @Test
    func `capability FIFO keeps snapshot dispatch and projection in issue order`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        let barrier = CapabilitySequenceBarrier()
        var invocation = 0
        client.executeHandler = { toolName in
            guard toolName == "take_snapshot" else { return .text("ok") }
            invocation += 1
            if invocation == 1 {
                await barrier.block()
            }
            return Self.snapshotResponse(uid: "\(invocation)_0")
        }

        let first = Task { @MainActor in
            try await context.execute(
                tool: tool,
                arguments: ToolArguments(raw: [
                    "action": "snapshot",
                    "page_id": pageReference,
                ]))
        }
        await barrier.waitUntilBlocked()
        let second = Task { @MainActor in
            try await context.execute(
                tool: tool,
                arguments: ToolArguments(raw: [
                    "action": "snapshot",
                    "page_id": pageReference,
                ]))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(invocation == 1)
        await barrier.release()
        let firstResponse = try await first.value
        _ = try await second.value
        let staleElement = try Self.elementReference(from: firstResponse)
        let beforeRefusal = client.sequences.count

        let refused = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "click",
                "page_id": pageReference,
                "uid": staleElement,
            ]))
        #expect(refused.isError)
        #expect(client.sequences.count == beforeRefusal)
    }

    @Test
    func `third party raw params and returned DOM refs use exact singleton object paths`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        let snapshot = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try Self.elementReference(from: snapshot)
        let parameters = #"{"target":{"uid":"\#(elementReference)"},"# +
            #""metadata":{"uid":"domain-value","extra":true}}"#
        let encodedArguments = try JSONSerialization.data(
            withJSONObject: ["toolName": "fixture", "params": parameters],
            options: [.sortedKeys])
        let rawArguments = try #require(String(data: encodedArguments, encoding: .utf8))
        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "execute_3p_developer_tool",
                "page_id": pageReference,
                "mcp_args_json": rawArguments,
            ]))

        let call = try #require(client.sequences.last?.last)
        let params = try #require(call.arguments["params"] as? String)
        let data = try #require(params.data(using: .utf8))
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((decoded["target"] as? [String: Any])?["uid"] as? String == "1_0")
        #expect((decoded["metadata"] as? [String: Any])?["uid"] as? String == "domain-value")
        let text = Self.text(from: response)
        #expect(text.contains(#""label" : "uid=1_0""#))
        #expect(text.contains(#""uid" : "customer-42""#))
        #expect(!text.contains("\nuid=1_0"))
        #expect(!text.contains(#""uid" : "1_0""#))
        #expect(text.contains("be1_"))
    }

    @Test
    func `third party domain uid text without a snapshot remains unchanged`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        let providerText = #"{"label":"uid=customer-42"}"#
        client.executeHandler = { toolName in
            toolName == "execute_3p_developer_tool" ? .text(providerText) : .text("ok")
        }

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "execute_3p_developer_tool",
                "page_id": pageReference,
                "mcp_args_json": #"{"toolName":"fixture"}"#,
            ]))

        #expect(Self.text(from: response) == providerText)
        #expect(response.meta?.objectValue?["browser_snapshot_ref"] == nil)
    }

    private static func context(client: any BrowserMCPClientProviding) -> MCPToolContext {
        let services = PeekabooServices()
        return MCPToolContext(
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
    }

    private static func pageReference(from response: ToolResponse) throws -> String {
        let root = try #require(response.structuredContent?.objectValue)
        let pages = try #require(root["pages"]?.arrayValue)
        return try #require(pages.first?.objectValue?["id"]?.stringValue)
    }

    private static func elementReference(from response: ToolResponse) throws -> String {
        let root = try #require(response.structuredContent?.objectValue)
        return try #require(root["snapshot"]?.objectValue?["id"]?.stringValue)
    }

    private static func text(from response: ToolResponse) -> String {
        guard case let .text(text, _, _)? = response.content.first else { return "" }
        return text
    }

    private static func snapshotResponse(uid: String) -> ToolResponse {
        ToolResponse(
            content: [.text(text: "uid=\(uid) button \"Continue\"", annotations: nil, _meta: nil)],
            structuredContent: .object([
                "snapshot": .object([
                    "id": .string(uid),
                    "role": .string("button"),
                    "name": .string("Continue"),
                ]),
            ]))
    }
}

@MainActor
private final class CapabilityBrowserMCPClient: BrowserMCPClientProviding, BrowserMCPActionResultProviding,
    BrowserMCPAtomicSessionActionProviding,
    @unchecked Sendable
{
    let structuredResponses: Bool
    let providesEpoch: Bool
    let providerSessionEpoch = BrowserMCPProviderSessionEpoch()
    private(set) var sequences: [[BrowserMCPMappedCall]] = []
    private(set) var elementPreflights: [BrowserMCPElementPreflight?] = []
    var executeHandler: (@MainActor (String) async -> ToolResponse)?

    init(structuredResponses: Bool = true, providesEpoch: Bool = true) {
        self.structuredResponses = structuredResponses
        self.providesEpoch = providesEpoch
    }

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        BrowserMCPStatus(
            isConnected: true,
            toolCount: 52,
            detectedBrowsers: [],
            connectionReceipt: BrowserMCPConnectionReceipt(
                browserURL: "http://127.0.0.1:9222/",
                webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
                devToolsBrowserID: "browser-a",
                browserVersion: "Chrome/151.0",
                protocolVersion: "1.3"),
            providerSessionEpoch: self.providesEpoch ? self.providerSessionEpoch : nil)
    }

    func connect(channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        await self.status(channel: channel)
    }

    func disconnect() async {}

    func execute(
        toolName: String,
        arguments: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        let call = BrowserMCPMappedCall(toolName: toolName, arguments: arguments)
        self.sequences.append([call])
        return self.response(for: toolName)
    }

    func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel _: BrowserMCPChannel?) async throws -> DesktopActionResult<ToolResponse>
    {
        self.sequences.append(calls)
        if let executeHandler {
            let response = await executeHandler(calls.last?.toolName ?? "")
            return DesktopActionResult(payload: response, outcome: self.outcome(for: calls))
        }
        let response = self.response(for: calls.last?.toolName)
        return DesktopActionResult(payload: response, outcome: self.outcome(for: calls))
    }

    func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding,
        elementPreflight: BrowserMCPElementPreflight?) async throws -> DesktopActionResult<ToolResponse>
    {
        let current = await self.status(channel: channel)
        guard current.connectionReceipt == expectedSessionBinding.connectionReceipt,
              current.providerSessionEpoch == expectedSessionBinding.providerSessionEpoch
        else {
            throw BrowserMCPConnectionError.expectedProviderSessionEpochMismatch
        }
        self.elementPreflights.append(elementPreflight)
        return try await self.executeSequenceWithOutcome(calls, channel: channel)
    }

    private func response(for toolName: String?) -> ToolResponse {
        switch toolName {
        case "list_pages": self.pageResponse()
        case "take_snapshot": self.snapshotResponse()
        case "execute_3p_developer_tool": self.thirdPartyResponse()
        default: .text("ok")
        }
    }

    private func outcome(for calls: [BrowserMCPMappedCall]) -> DesktopActionOutcome? {
        let mutationCount = calls.count { call in
            BrowserMCPPageRoutingContract.actionSemantics(
                for: call.toolName,
                arguments: call.arguments) != .readOnly
        }
        guard let unitCount = DesktopActionOutcome.DispatchUnitCount(mutationCount) else { return nil }
        return .dispatchedUnverified(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: unitCount)
    }

    private func pageResponse() -> ToolResponse {
        let content: [MCP.Tool.Content] = [
            .text(
                text: "## Pages\n7: Example (https://example.test/) [selected]",
                annotations: nil,
                _meta: nil),
        ]
        guard self.structuredResponses else { return ToolResponse(content: content) }
        return ToolResponse(
            content: content,
            structuredContent: .object([
                "pages": .array([.object([
                    "id": .int(7),
                    "url": .string("https://example.test/"),
                    "title": .string("Example"),
                    "selected": .bool(true),
                ])]),
            ]))
    }

    private func snapshotResponse() -> ToolResponse {
        let content: [MCP.Tool.Content] = [
            .text(text: "uid=1_0 button \"Continue\"", annotations: nil, _meta: nil),
        ]
        guard self.structuredResponses else { return ToolResponse(content: content) }
        return ToolResponse(
            content: content,
            structuredContent: .object([
                "snapshot": .object([
                    "id": .string("1_0"),
                    "role": .string("button"),
                    "name": .string("Continue"),
                ]),
            ]))
    }

    private func thirdPartyResponse() -> ToolResponse {
        ToolResponse(
            content: [.text(
                text: """
                {
                  "result": {
                    "uid": "1_0"
                  },
                  "account": {
                    "uid": "customer-42"
                  },
                  "label": "uid=1_0"
                }
                ## Latest page snapshot
                uid=1_0 button "Continue"
                """,
                annotations: nil,
                _meta: nil)],
            structuredContent: .object([
                "snapshot": .object([
                    "id": .string("1_0"),
                    "role": .string("button"),
                    "name": .string("Continue"),
                ]),
            ]))
    }
}

private actor CapabilitySequenceBarrier {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        self.blocked = true
        self.blockedWaiters.forEach { $0.resume() }
        self.blockedWaiters.removeAll()
        guard !self.released else { return }
        await withCheckedContinuation { self.releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !self.blocked else { return }
        await withCheckedContinuation { self.blockedWaiters.append($0) }
    }

    func release() {
        self.released = true
        self.releaseWaiters.forEach { $0.resume() }
        self.releaseWaiters.removeAll()
    }
}
