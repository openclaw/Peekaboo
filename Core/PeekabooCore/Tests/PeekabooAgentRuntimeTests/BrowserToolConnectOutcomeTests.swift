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
    func `Target lock projects exact session recovery without permission guidance`() async throws {
        let cases: [(BrowserToolInstructionAudience, String)] = [
            (.mcp, "Run browser { \"action\": \"disconnect\" }"),
            (.commandLine, "Run `peekaboo browser disconnect`"),
        ]

        for (audience, expectedHint) in cases {
            let client = ConnectOutcomeBrowserClient(error: BrowserMCPConnectionError.targetLocked)
            let response = try await BrowserTool(
                client: client,
                executionPolicy: .unrestricted,
                instructionAudience: audience).execute(
                arguments: ToolArguments(raw: ["action": "connect", "channel": "canary"]))

            #expect(response.isError)
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["state"] == .string("refused"))
            #expect(meta["dispatch_state"] == .string("none"))
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
            #expect(meta["refusal_reason"] == .string("transport_session_unavailable"))
            #expect(meta["escalation"] == .string("reconnect_session"))

            guard case let .text(text: text, annotations: _, _meta: _) = response.content.first else {
                Issue.record("Expected a text error response")
                continue
            }
            #expect(text.contains(BrowserMCPConnectionError.targetLocked.localizedDescription))
            #expect(text.contains(expectedHint))
            #expect(!text.contains("enable remote debugging"))
            #expect(!text.contains("Run browser { \"action\": \"connect\" }"))
            #expect(client.connectCount == 1)
        }
    }

    @Test
    func `Browser tool keeps uncancelled raw provider cancellation indeterminate`() async throws {
        let client = ConnectOutcomeBrowserClient(error: CancellationError())

        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted).execute(
            arguments: ToolArguments(raw: ["action": "connect", "channel": "stable"]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatch_state"] == .string("may_have_dispatched"))
        #expect(meta["retry_safe"] == .bool(false))
    }

    @Test
    func `Browser tool keeps raw cancellation after provider entry indeterminate`() async throws {
        let client = ConnectOutcomeBrowserClient(
            error: CancellationError(),
            waitForCancellation: true)
        let task = Task { @MainActor in
            try await BrowserTool(client: client, executionPolicy: .unrestricted).execute(
                arguments: ToolArguments(raw: ["action": "connect", "channel": "stable"]))
        }
        await client.waitUntilConnectStarts()

        task.cancel()

        let response = try await task.value
        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatch_state"] == .string("may_have_dispatched"))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(client.connectCount == 1)
    }

    @Test
    func `Browser tool returns read cancellation without mutation outcome metadata`() async throws {
        let client = ReadCancellationBrowserClient()

        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted).execute(
            arguments: ToolArguments(raw: ["action": "console", "page_id": 1, "channel": "stable"]))

        #expect(response.isError)
        #expect(response.meta == nil)
        #expect(client.executeCount == 1)
    }

    @Test
    func `Browser tool rejects an already cancelled caller before provider entry`() async {
        let client = ConnectOutcomeBrowserClient(error: CancellationError())
        let gate = BrowserToolStartGate()
        let task = Task { @MainActor in
            await gate.block()
            return try await BrowserTool(client: client, executionPolicy: .unrestricted).execute(
                arguments: ToolArguments(raw: ["action": "connect", "channel": "stable"]))
        }
        await gate.waitUntilBlocked()

        task.cancel()
        await gate.release()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(client.connectCount == 0)
    }

    @Test
    func `Browser tool rejects an already cancelled read before provider entry`() async {
        let client = ReadCancellationBrowserClient()
        let gate = BrowserToolStartGate()
        let task = Task { @MainActor in
            await gate.block()
            return try await BrowserTool(client: client, executionPolicy: .unrestricted).execute(
                arguments: ToolArguments(raw: ["action": "list_pages", "channel": "stable"]))
        }
        await gate.waitUntilBlocked()

        task.cancel()
        await gate.release()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(client.executeCount == 0)
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
            processCodeSignatureValidator: { _, _, channel in .browserTestIdentity(channel: channel) },
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
private final class ReadCancellationBrowserClient: BrowserMCPActionResultProviding, @unchecked Sendable {
    private(set) var executeCount = 0

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
        throw CancellationError()
    }

    func executeSequenceWithOutcome(
        _: [BrowserMCPMappedCall],
        channel _: BrowserMCPChannel?) async throws -> DesktopActionResult<ToolResponse>
    {
        self.executeCount += 1
        throw CancellationError()
    }
}

@MainActor
private final class ConnectOutcomeBrowserClient: BrowserMCPConnectionResultProviding, @unchecked Sendable {
    private let error: any Error
    private let waitForCancellation: Bool
    private(set) var connectCount = 0
    private var connectStarted = false
    private var connectStartedContinuation: CheckedContinuation<Void, Never>?

    init(error: any Error, waitForCancellation: Bool = false) {
        self.error = error
        self.waitForCancellation = waitForCancellation
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
        self.connectStarted = true
        self.connectStartedContinuation?.resume()
        self.connectStartedContinuation = nil
        if self.waitForCancellation {
            try await Task.sleep(for: .seconds(30))
        }
        throw self.error
    }

    func waitUntilConnectStarts() async {
        guard !self.connectStarted else { return }
        await withCheckedContinuation { continuation in
            self.connectStartedContinuation = continuation
        }
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

private actor BrowserToolStartGate {
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func block() async {
        self.blockedContinuation?.resume()
        self.blockedContinuation = nil
        await withCheckedContinuation { continuation in
            self.releaseContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        guard self.releaseContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            self.blockedContinuation = continuation
        }
    }

    func release() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }
}
