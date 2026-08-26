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
        #expect(Self.text(from: rejected).contains("another or expired connection"))
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
}

@MainActor
private final class CapabilityBrowserMCPClient: BrowserMCPClientProviding, BrowserMCPActionResultProviding,
    @unchecked Sendable
{
    let structuredResponses: Bool
    private(set) var sequences: [[BrowserMCPMappedCall]] = []

    init(structuredResponses: Bool = true) {
        self.structuredResponses = structuredResponses
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
                protocolVersion: "1.3"))
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
        let response = self.response(for: calls.last?.toolName)
        return DesktopActionResult(payload: response, outcome: nil)
    }

    private func response(for toolName: String?) -> ToolResponse {
        switch toolName {
        case "list_pages": self.pageResponse()
        case "take_snapshot": self.snapshotResponse()
        default: .text("ok")
        }
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
}
