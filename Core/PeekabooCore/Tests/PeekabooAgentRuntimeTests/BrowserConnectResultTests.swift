import MCP
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserConnectResultTests {
    @Test
    func `Browser connect publishes one foreground dispatch with its exact receipt`() async throws {
        let receipt = BrowserMCPConnectionReceipt(
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let client = ConnectResultBrowserMCPClient(
            status: BrowserMCPStatus(
                isConnected: true,
                toolCount: 29,
                detectedBrowsers: [],
                connectionReceipt: receipt),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .browserProtocol, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one))

        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted)
            .execute(arguments: ToolArguments(raw: [
                "action": "connect",
                "browser_url": "http://127.0.0.1:9222",
            ]))

        #expect(!response.isError)
        #expect(client.connectedBrowserURLs == ["http://127.0.0.1:9222"])
        let meta = try #require(response.meta?.objectValue)
        let receiptMeta = try #require(meta["connection_receipt"]?.objectValue)
        #expect(receiptMeta["browser_id"] == .string("browser-a"))
        #expect(meta["state"] == .string("dispatched_unverified"))
        #expect(meta["delivery_mechanism"] == .string("browser_protocol"))
        #expect(meta["delivery_mode"] == .string("foreground"))
        #expect(meta["dispatched_unit_count"] == .int(1))
        #expect(meta["requires_fresh_observation"] == .bool(true))
    }

    @Test
    func `Browser connect reports an existing target as confirmed no change`() async throws {
        let client = ConnectResultBrowserMCPClient(
            status: BrowserMCPStatus(
                isConnected: true,
                toolCount: 29,
                detectedBrowsers: [],
                connectionReceipt: BrowserMCPConnectionReceipt(
                    channel: .stable,
                    processIdentifier: 4242,
                    processStartIdentity: 9001,
                    bundleIdentifier: "com.google.Chrome")),
            outcome: .confirmedNoChange())

        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted)
            .execute(arguments: ToolArguments(raw: [
                "action": "connect",
                "channel": "stable",
            ]))

        #expect(!response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("confirmed_no_change"))
        #expect(meta["dispatch_state"] == .string("none"))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["requires_fresh_observation"] == .bool(false))
    }
}

@MainActor
private final class ConnectResultBrowserMCPClient: BrowserMCPClientProviding,
    BrowserMCPConnectionResultProviding, @unchecked Sendable
{
    let statusValue: BrowserMCPStatus
    let outcome: DesktopActionOutcome
    private(set) var connectedBrowserURLs: [String?] = []

    init(status: BrowserMCPStatus, outcome: DesktopActionOutcome) {
        self.statusValue = status
        self.outcome = outcome
    }

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        self.statusValue
    }

    func connect(channel _: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        self.statusValue
    }

    func connect(channel _: BrowserMCPChannel?, browserURL: String?) async throws -> BrowserMCPStatus {
        self.connectedBrowserURLs.append(browserURL)
        return self.statusValue
    }

    func connectWithOutcome(
        channel: BrowserMCPChannel?,
        browserURL: String?) async throws -> DesktopActionResult<BrowserMCPStatus>
    {
        try await DesktopActionResult(
            payload: self.connect(channel: channel, browserURL: browserURL),
            outcome: self.outcome)
    }

    func disconnect() async {}

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        .error("unexpected browser tool execution")
    }
}
