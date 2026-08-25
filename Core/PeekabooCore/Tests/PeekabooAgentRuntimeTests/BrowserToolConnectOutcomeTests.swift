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

    @Test
    func `Browser tool preserves real session cancellation before WebSocket resume`() async {
        let manager = CancellationBrowserMCPManager()
        let browser = DetectedBrowser(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            processIdentifier: 50,
            processStartIdentity: 2050,
            version: "151.0",
            channel: .stable)
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [browser] },
            processStartIdentity: { _ in 2050 },
            processBundleIdentifier: { _ in "com.google.Chrome" },
            channelEndpointResolver: BrowserMCPChannelEndpointResolver(
                resolveInitial: { _, _ in throw CancellationError() },
                revalidate: { _, _ in }),
            environment: [:])

        await #expect(throws: CancellationError.self) {
            _ = try await BrowserTool(
                client: BrowserMCPService(sessionManager: session),
                executionPolicy: .unrestricted).execute(
                arguments: ToolArguments(raw: ["action": "connect", "channel": "stable"]))
        }
        #expect(manager.addServerCount == 0)
        #expect(manager.removeServerCount == 0)
    }

    @Test
    func `Browser tool reports post dispatch isolated cancellation as indeterminate`() async throws {
        let manager = PostDispatchCancellationBrowserMCPManager()
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            environment: ["PEEKABOO_BROWSER_MCP_ISOLATED": "1"])
        let task = Task { @MainActor in
            try await BrowserTool(
                client: BrowserMCPService(sessionManager: session),
                executionPolicy: .unrestricted).execute(
                arguments: ToolArguments(raw: ["action": "connect", "channel": "stable"]))
        }
        await manager.waitUntilAddServerStarts()

        task.cancel()
        let response = try await task.value

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatch_state"] == .string("may_have_dispatched"))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(manager.addServerCount == 1)
        #expect(manager.removeServerCount == 1)
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

@MainActor
private final class CancellationBrowserMCPManager: BrowserMCPManaging {
    var addServerCount = 0
    var removeServerCount = 0

    func hasServer(name _: String) -> Bool {
        false
    }

    func isServerConnected(name _: String) async -> Bool {
        false
    }

    func serverToolCount(name _: String) async -> Int {
        0
    }

    func addServer(name _: String, config _: MCPServerConfig) async throws {
        self.addServerCount += 1
    }

    func removeServer(name _: String) async {
        self.removeServerCount += 1
    }

    func executeTool(
        serverName _: String,
        toolName _: String,
        arguments _: [String: Any]) async throws -> ToolResponse
    {
        .error("unexpected")
    }
}

@MainActor
private final class PostDispatchCancellationBrowserMCPManager: BrowserMCPManaging {
    var addServerCount = 0
    var removeServerCount = 0
    private var addServerStarted = false
    private var addServerStartedContinuation: CheckedContinuation<Void, Never>?

    func hasServer(name _: String) -> Bool {
        self.addServerCount > self.removeServerCount
    }

    func isServerConnected(name _: String) async -> Bool {
        self.hasServer(name: "")
    }

    func serverToolCount(name _: String) async -> Int {
        0
    }

    func addServer(name _: String, config _: MCPServerConfig) async throws {
        self.addServerCount += 1
        self.addServerStarted = true
        self.addServerStartedContinuation?.resume()
        self.addServerStartedContinuation = nil
        try await Task.sleep(for: .seconds(30))
    }

    func removeServer(name _: String) async {
        self.removeServerCount += 1
    }

    func executeTool(
        serverName _: String,
        toolName _: String,
        arguments _: [String: Any]) async throws -> ToolResponse
    {
        .error("unexpected")
    }

    func waitUntilAddServerStarts() async {
        guard !self.addServerStarted else { return }
        await withCheckedContinuation { continuation in
            self.addServerStartedContinuation = continuation
        }
    }
}
