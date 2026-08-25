import MCP
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserToolConnectOutcomeTests {
    @Test
    func `permission bearing connect failure projects foreground indeterminate metadata`() async throws {
        let failure = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .browserProtocol, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "approval completion unknown",
            hint: "check status")
        let client = ConnectOutcomeBrowserClient(error: failure)

        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted).execute(
            arguments: ToolArguments(raw: ["action": "connect", "channel": "stable"]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatch_state"] == .string("may_have_dispatched"))
        #expect(meta["dispatched_unit_count"] == .int(1))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["delivery_mode"] == .string("foreground"))
        #expect(client.connectCount == 1)
    }

    @Test
    func `pre permission connect refusal projects safe zero dispatch metadata`() async throws {
        let failure = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "authority unavailable")
        let client = ConnectOutcomeBrowserClient(error: failure)

        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted).execute(
            arguments: ToolArguments(raw: ["action": "connect", "channel": "stable"]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("refused"))
        #expect(meta["dispatch_state"] == .string("none"))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(client.connectCount == 1)
    }

    @Test
    func `Browser tool does not swallow caller cancellation`() async {
        let client = ConnectOutcomeBrowserClient(error: CancellationError())

        await #expect(throws: CancellationError.self) {
            _ = try await BrowserTool(client: client, executionPolicy: .unrestricted).execute(
                arguments: ToolArguments(raw: ["action": "connect", "channel": "stable"]))
        }
    }
}

@MainActor
private final class ConnectOutcomeBrowserClient: BrowserMCPConnectionResultProviding, @unchecked Sendable {
    private let error: any Error
    private(set) var connectCount = 0

    init(error: any Error) {
        self.error = error
    }

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
    }

    func connect(channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        self.connectCount += 1
        throw self.error
    }

    func connect(channel _: BrowserMCPChannel?, browserURL _: String?) async throws -> BrowserMCPStatus {
        self.connectCount += 1
        throw self.error
    }

    func connectWithOutcome(
        channel _: BrowserMCPChannel?,
        browserURL _: String?) async throws -> DesktopActionResult<BrowserMCPStatus>
    {
        self.connectCount += 1
        throw self.error
    }

    func disconnect() async {}

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        .error("unexpected")
    }
}
