import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@MainActor
struct RemoteBrowserMCPSessionTests {
    @Test
    func `MCP opens an empty remote scope and tears it down`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let root = Self.rootClient(transport: transport)
        let context = Self.context(browser: root)

        let server = try await PeekabooMCPServer(toolContext: context)
        let scoped = await server.browserClientForTesting()

        #expect(scoped !== root)
        #expect(transport.openedHandoffs == [nil])
        let status = await scoped.status(channel: nil)
        #expect(!status.isConnected)
        #expect(status.error == nil)
        #expect(transport.statusCallCount == 1)

        await server.stopForTesting()
        #expect(transport.endedSessionIDs.count == 1)
    }

    @Test
    func `MCP closes remote scope when serving fails before transport startup`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let context = Self.context(browser: Self.rootClient(transport: transport))
        let server = try await PeekabooMCPServer(toolContext: context)

        await #expect(throws: PeekabooAgentRuntime.MCPError.self) {
            try await server.serve(transport: .http)
        }

        #expect(transport.endedSessionIDs.count == 1)
    }

    @Test
    func `cancelled MCP teardown still closes remote scope`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let context = Self.context(browser: Self.rootClient(transport: transport))
        let server = try await PeekabooMCPServer(toolContext: context)

        let teardown = Task { await server.stopForTesting() }
        teardown.cancel()
        _ = await teardown.value

        #expect(transport.endedSessionIDs.count == 1)
    }

    @Test
    func `handoff opens a targeted scope and invalid response is rolled back`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let root = Self.rootClient(transport: transport)
        let context = Self.context(browser: root)
        let grant = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))

        let scoped = try await context.openingBrowserSession(named: "mcp:handoff", handoff: grant)
        #expect(transport.openedHandoffs == [grant.payload])
        await scoped.releaseSnapshotOwner()
        #expect(transport.endedSessionIDs.count == 1)

        transport.omitTargetDigest = true
        await #expect(throws: RemoteBrowserMCPSessionError.self) {
            _ = try await context.openingBrowserSession(named: "mcp:invalid", handoff: grant)
        }
        #expect(transport.endedSessionIDs.count == 2)
    }

    @Test(arguments: [false, true])
    func `indeterminate open retry reuses one claim`(usesHandoff: Bool) async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.openErrors = [URLError(.timedOut)]
        let root = Self.rootClient(transport: transport)
        let handoff = usesHandoff
            ? BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
            : nil

        let scoped = try await root.openBrowserMCPScopedSession(handoff: handoff)

        #expect(transport.openedClaimIDs.count == 2)
        #expect(transport.openedClaimIDs[0] == transport.openedClaimIDs[1])
        #expect(transport.openedHandoffs[0] == transport.openedHandoffs[1])

        _ = try await root.openBrowserMCPScopedSession(handoff: handoff)
        #expect(transport.openedClaimIDs.count == 3)
        #expect(transport.openedClaimIDs[2] != transport.openedClaimIDs[1])
        await (scoped as? any BrowserMCPScopedSessionEnding)?.endBrowserMCPScopedSession()
    }

    @Test
    func `indeterminate handoff open refuses a different retry without dispatch`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.openErrors = [URLError(.networkConnectionLost), URLError(.timedOut)]
        let root = Self.rootClient(transport: transport)
        let handoff = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))

        await #expect(throws: URLError.self) {
            _ = try await root.openBrowserMCPScopedSession(handoff: handoff)
        }
        await #expect(throws: RemoteBrowserMCPSessionError.openAttemptUnresolved) {
            _ = try await root.openBrowserMCPScopedSession(handoff: nil)
        }

        #expect(transport.openedClaimIDs.count == 2)
        #expect(transport.openedClaimIDs[0] == transport.openedClaimIDs[1])
    }

    @Test
    func `exhausted response loss retry preserves claim for same payload`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.openErrors = [URLError(.networkConnectionLost), URLError(.timedOut)]
        let root = Self.rootClient(transport: transport)
        let handoff = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))

        await #expect(throws: URLError.self) {
            _ = try await root.openBrowserMCPScopedSession(handoff: handoff)
        }
        _ = try await root.openBrowserMCPScopedSession(handoff: handoff)

        #expect(transport.openedClaimIDs.count == 3)
        #expect(Set(transport.openedClaimIDs).count == 1)
    }

    @Test
    func `indeterminate dispatch stays unresolved after determinate retry failure`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.openErrors = [URLError(.timedOut), URLError(.cannotConnectToHost)]
        let root = Self.rootClient(transport: transport)
        let handoff = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let differentHandoff = BrowserMCPHandoffGrant(payload: Data("different-connect-receipt".utf8))

        await #expect(throws: URLError.self) {
            _ = try await root.openBrowserMCPScopedSession(handoff: handoff)
        }
        await #expect(throws: RemoteBrowserMCPSessionError.openAttemptUnresolved) {
            _ = try await root.openBrowserMCPScopedSession(handoff: differentHandoff)
        }
        _ = try await root.openBrowserMCPScopedSession(handoff: handoff)

        #expect(transport.openedClaimIDs.count == 3)
        #expect(Set(transport.openedClaimIDs).count == 1)
    }

    @Test(arguments: [false, true])
    func `cancellation retains unresolved claim without automatic retry`(throwsCancellation: Bool) async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.openErrors = [throwsCancellation ? CancellationError() : URLError(.timedOut)]
        let root = Self.rootClient(transport: transport)
        let handoff = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let differentHandoff = BrowserMCPHandoffGrant(payload: Data("different-connect-receipt".utf8))

        let firstOpen = Task { @MainActor in
            if !throwsCancellation {
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            }
            return try await root.openBrowserMCPScopedSession(handoff: handoff)
        }
        await #expect(throws: (any Error).self) {
            _ = try await firstOpen.value
        }
        await #expect(throws: RemoteBrowserMCPSessionError.openAttemptUnresolved) {
            _ = try await root.openBrowserMCPScopedSession(handoff: differentHandoff)
        }
        _ = try await root.openBrowserMCPScopedSession(handoff: handoff)

        #expect(transport.openedClaimIDs.count == 2)
        #expect(Set(transport.openedClaimIDs).count == 1)
    }

    @Test
    func `canonical response lost failure retries once with same claim`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.openErrors = [DesktopActionFailure.indeterminate(
            route: .bridge,
            evidence: .responseLost,
            message: "bootstrap response lost",
            hint: "retry the same claim")]
        let root = Self.rootClient(transport: transport)

        _ = try await root.openBrowserMCPScopedSession(handoff: nil)

        #expect(transport.openedClaimIDs.count == 2)
        #expect(transport.openedClaimIDs[0] == transport.openedClaimIDs[1])
    }

    @Test
    func `determinate open failure releases claim for a different handoff`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.openErrors = [PeekabooBridgeErrorEnvelope(
            code: .invalidRequest,
            message: "request was rejected before opening")]
        let root = Self.rootClient(transport: transport)
        let firstHandoff = BrowserMCPHandoffGrant(payload: Data("first-signed-connect-receipt".utf8))
        let secondHandoff = BrowserMCPHandoffGrant(payload: Data("second-signed-connect-receipt".utf8))

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await root.openBrowserMCPScopedSession(handoff: firstHandoff)
        }
        _ = try await root.openBrowserMCPScopedSession(handoff: secondHandoff)

        #expect(transport.openedClaimIDs.count == 2)
        #expect(transport.openedClaimIDs[0] != transport.openedClaimIDs[1])
        #expect(transport.openedHandoffs == [firstHandoff.payload, secondHandoff.payload])
    }

    @Test
    func `remote MCP mints opaque refs and refuses raw or copied refs before transport`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let root = Self.rootClient(transport: transport)
        let base = Self.context(browser: root)
        let grant = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let first = try await base.openingBrowserSession(named: "mcp:first", handoff: grant)
        let second = try await base.openingBrowserSession(named: "mcp:second", handoff: grant)
        let firstTool = BrowserTool(context: first)
        let secondTool = BrowserTool(context: second)

        let listed = try await first.execute(
            tool: firstTool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        #expect(pageReference.hasPrefix("bp1_"))
        #expect(!Self.text(from: listed).contains("\n7:"))

        let snapshot = try await first.execute(
            tool: firstTool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try Self.elementReference(from: snapshot)
        #expect(elementReference.hasPrefix("be1_"))
        #expect(!Self.text(from: snapshot).contains("uid=1_0"))
        let dispatchCount = transport.executeCallCount

        let copied = try await second.execute(
            tool: secondTool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        #expect(copied.isError)
        #expect(transport.executeCallCount == dispatchCount)

        let rawPage = try await first.execute(
            tool: firstTool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": 7,
            ]))
        #expect(rawPage.isError)
        #expect(transport.executeCallCount == dispatchCount)

        let rawElement = try await first.execute(
            tool: firstTool,
            arguments: ToolArguments(raw: [
                "action": "click",
                "page_id": pageReference,
                "uid": "1_0",
            ]))
        #expect(rawElement.isError)
        #expect(transport.executeCallCount == dispatchCount)

        let clicked = try await first.execute(
            tool: firstTool,
            arguments: ToolArguments(raw: [
                "action": "click",
                "page_id": pageReference,
                "uid": elementReference,
            ]))
        #expect(!clicked.isError)
        #expect(transport.executeCallCount == dispatchCount + 1)
        #expect(transport.elementPreflights.last??.providerPageID == 7)
        #expect(transport.elementPreflights.last??.providerUIDs == ["1_0"])
    }

    @Test
    func `scoped status preserves binding when transport observation is indeterminate`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let root = Self.rootClient(transport: transport)
        let grant = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let context = try await Self.context(browser: root)
            .openingBrowserSession(named: "mcp:status", handoff: grant)
        let client = context.browser

        let confirmed = await client.status(channel: nil)
        let receipt = try #require(confirmed.connectionReceipt)
        let epoch = try #require(confirmed.providerSessionEpoch)
        transport.statusFailure = CancellationError()

        let indeterminate = await client.status(channel: nil)
        #expect(indeterminate.observation == .indeterminate)
        #expect(indeterminate.connectionReceipt == receipt)
        #expect(indeterminate.providerSessionEpoch == epoch)
        #expect(!indeterminate.isConnected)
        #expect(indeterminate.toolCount == 0)
    }

    @Test(arguments: RemoteBrowserMCPSessionTransportError.allCases)
    func `authoritative scope refusal clears refs and blocks later transport`(
        terminalError: RemoteBrowserMCPSessionTransportError) async throws
    {
        let transport = RecordingRemoteBrowserSessionTransport()
        let root = Self.rootClient(transport: transport)
        let grant = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let context = try await Self.context(browser: root)
            .openingBrowserSession(named: "mcp:terminal", handoff: grant)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        let dispatchedBeforeTerminal = transport.executeCallCount
        transport.statusFailure = terminalError

        let terminal = await context.browser.status(channel: nil)
        #expect(terminal.observation == .confirmed)
        #expect(!terminal.isConnected)
        #expect(terminal.connectionReceipt == nil)
        #expect(terminal.providerSessionEpoch == nil)
        let statusCallsAtTerminal = transport.statusCallCount

        _ = await context.browser.status(channel: nil)
        let refused = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        #expect(refused.isError)
        #expect(transport.statusCallCount == statusCallsAtTerminal)
        #expect(transport.executeCallCount == dispatchedBeforeTerminal)

        await context.releaseSnapshotOwner()
        #expect(transport.endCallCount == 0)
    }

    @Test
    func `authoritative execution refusal terminates scope before another call`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let root = Self.rootClient(transport: transport)
        let grant = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let context = try await Self.context(browser: root)
            .openingBrowserSession(named: "mcp:execution-terminal", handoff: grant)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        let dispatchedBeforeTerminal = transport.executeCallCount
        transport.executeFailure = RemoteBrowserMCPSessionTransportError.sessionEnded

        let refused = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        #expect(refused.isError)
        #expect(transport.executeCallCount == dispatchedBeforeTerminal)
        let statusCallsAtTerminal = transport.statusCallCount

        let terminal = await context.browser.status(channel: nil)
        #expect(transport.statusCallCount == statusCallsAtTerminal)
        #expect(terminal.observation == .confirmed)
        #expect(terminal.connectionReceipt == nil)
    }

    @Test
    func `indeterminate disconnect keeps exact binding for later status`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let root = Self.rootClient(transport: transport)
        let grant = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let context = try await Self.context(browser: root)
            .openingBrowserSession(named: "mcp:disconnect-indeterminate", handoff: grant)
        let client = context.browser
        let confirmed = await client.status(channel: nil)
        let receipt = try #require(confirmed.connectionReceipt)
        let epoch = try #require(confirmed.providerSessionEpoch)
        transport.disconnectFailure = CancellationError()

        await client.disconnect()
        transport.statusFailure = CancellationError()
        let indeterminate = await client.status(channel: nil)

        #expect(indeterminate.observation == .indeterminate)
        #expect(indeterminate.connectionReceipt == receipt)
        #expect(indeterminate.providerSessionEpoch == epoch)
    }

    @Test
    func `failed end stays terminal and retries cleanup debt until confirmed`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let root = Self.rootClient(transport: transport)
        let context = try await Self.context(browser: root)
            .openingBrowserSession(named: "mcp:end-once", handoff: nil)
        let client = context.browser
        transport.endErrors = [
            PeekabooBridgeErrorEnvelope(code: .serverBusy, message: "cleanup not confirmed"),
            CancellationError(),
        ]

        await context.releaseSnapshotOwner()
        #expect(transport.endCallCount == 1)
        let statusCallsBefore = transport.statusCallCount
        let cleanupDebt = await client.status(channel: nil)
        #expect(cleanupDebt.observation == .confirmed)
        #expect(cleanupDebt.connectionReceipt == nil)
        #expect(transport.statusCallCount == statusCallsBefore)

        await context.releaseSnapshotOwner()
        #expect(transport.endCallCount == 2)
        await context.releaseSnapshotOwner()
        #expect(transport.endCallCount == 3)
        #expect(transport.endedSessionIDs.count == 1)
        await context.releaseSnapshotOwner()
        #expect(transport.endCallCount == 3)
    }

    @Test
    func `scoped connection without provider epoch terminates before transport execution`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.omitProviderEpoch = true
        let root = Self.rootClient(transport: transport)
        let grant = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let context = try await Self.context(browser: root)
            .openingBrowserSession(named: "mcp:missing-epoch", handoff: grant)
        let tool = BrowserTool(context: context)

        let status = await context.browser.status(channel: nil)
        #expect(status.observation == .confirmed)
        #expect(status.connectionReceipt == nil)
        #expect(status.providerSessionEpoch == nil)
        let statusCallsAtTerminal = transport.statusCallCount

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        #expect(response.isError)
        #expect(transport.statusCallCount == statusCallsAtTerminal)
        #expect(transport.executeCallCount == 0)
        #expect(transport.endCallCount == 1)
    }

    @Test
    func `background scoped browser never exposes or dispatches connect`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let root = Self.rootClient(transport: transport)
        let context = try await Self.context(browser: root)
            .openingBrowserSession(named: "mcp:background", handoff: nil)
        let tool = BrowserTool(context: context)

        guard case let .object(schema) = tool.inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .object(action)? = properties["action"],
              case let .array(actions)? = action["enum"]
        else {
            Issue.record("browser action schema is unavailable")
            return
        }
        #expect(!actions.contains(.string("connect")))

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "connect"]))
        #expect(response.isError)
        #expect(transport.connectCallCount == 0)
    }

    private static func rootClient(
        transport: RecordingRemoteBrowserSessionTransport) -> RemoteBrowserMCPClient
    {
        RemoteBrowserMCPClient(
            client: PeekabooBridgeClient(
                socketPath: "/private/tmp/peekaboo-remote-browser-session-no-root.sock",
                requestTimeoutSec: 0.1),
            sessionTransport: transport)
    }

    private static func context(browser: any BrowserMCPClientProviding) -> MCPToolContext {
        let services = PeekabooServices(initializeAgentService: false)
        return MCPToolContext(
            services: services,
            browser: browser,
            executionPolicy: .backgroundOnly)
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
private final class RecordingRemoteBrowserSessionTransport: RemoteBrowserMCPSessionTransport, @unchecked Sendable {
    private(set) var openedHandoffs: [Data?] = []
    private(set) var openedClaimIDs: [UUID] = []
    private(set) var statusCallCount = 0
    private(set) var connectCallCount = 0
    private(set) var executeCallCount = 0
    private(set) var endedSessionIDs: [UUID] = []
    private(set) var elementPreflights: [BrowserMCPElementPreflight?] = []
    var omitTargetDigest = false
    var omitProviderEpoch = false
    var statusFailure: (any Error)?
    var executeFailure: (any Error)?
    var disconnectFailure: (any Error)?
    var openErrors: [any Error] = []
    var endErrors: [any Error] = []
    private(set) var endCallCount = 0
    private var epochs: [UUID: BrowserMCPProviderSessionEpoch] = [:]

    func openSession(
        handoff: BrowserMCPHandoffGrant?,
        claimID: UUID) async throws -> RemoteBrowserMCPSessionHandle
    {
        self.openedHandoffs.append(handoff?.payload)
        self.openedClaimIDs.append(claimID)
        if !self.openErrors.isEmpty {
            throw self.openErrors.removeFirst()
        }
        let sessionID = UUID()
        self.epochs[sessionID] = BrowserMCPProviderSessionEpoch(transportID: UUID())
        return RemoteBrowserMCPSessionHandle(
            sessionID: sessionID,
            targetReceiptSHA256: handoff == nil || self.omitTargetDigest ? nil : String(repeating: "a", count: 64))
    }

    func status(
        session: RemoteBrowserMCPSessionHandle,
        channel _: BrowserMCPChannel?) async throws -> BrowserMCPStatus
    {
        self.statusCallCount += 1
        if let statusFailure {
            throw statusFailure
        }
        guard session.targetReceiptSHA256 != nil else {
            return BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
        }
        return self.connectedStatus(session: session)
    }

    func connectWithOutcome(
        session: RemoteBrowserMCPSessionHandle,
        channel _: BrowserMCPChannel?,
        browserURL _: String?) async throws -> DesktopActionResult<BrowserMCPStatus>
    {
        self.connectCallCount += 1
        return DesktopActionResult(
            payload: self.connectedStatus(session: session),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .browserProtocol, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one))
    }

    func executeSequenceWithOutcome(
        session: RemoteBrowserMCPSessionHandle,
        calls: [BrowserMCPMappedCall],
        channel _: BrowserMCPChannel?,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding,
        elementPreflight: BrowserMCPElementPreflight?) async throws -> DesktopActionResult<ToolResponse>
    {
        if let executeFailure {
            throw executeFailure
        }
        let current = self.connectedStatus(session: session)
        guard current.connectionReceipt == expectedSessionBinding.connectionReceipt,
              current.providerSessionEpoch == expectedSessionBinding.providerSessionEpoch
        else {
            throw BrowserMCPConnectionError.expectedProviderSessionEpochMismatch
        }
        self.executeCallCount += 1
        self.elementPreflights.append(elementPreflight)
        let response = self.response(for: calls.last?.toolName)
        let mutationCount = calls.count { call in
            BrowserMCPPageRoutingContract.actionSemantics(
                for: call.toolName,
                arguments: call.arguments) != .readOnly
        }
        let payload = BrowserMCPExecutionEvidence.attaching(
            to: response,
            connectionReceipt: expectedSessionBinding.connectionReceipt,
            providerSessionEpoch: expectedSessionBinding.providerSessionEpoch,
            completedCallCount: calls.count,
            dispatchedCallCount: calls.count)
        let outcome = DesktopActionOutcome.DispatchUnitCount(mutationCount).map { unitCount in
            DesktopActionOutcome.dispatchedUnverified(
                delivery: .init(mechanism: .browserProtocol, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: unitCount)
        }
        return DesktopActionResult(payload: payload, outcome: outcome)
    }

    func disconnect(session _: RemoteBrowserMCPSessionHandle) async throws {
        if let disconnectFailure {
            throw disconnectFailure
        }
    }

    func endSession(_ session: RemoteBrowserMCPSessionHandle) async throws {
        self.endCallCount += 1
        if !self.endErrors.isEmpty {
            throw self.endErrors.removeFirst()
        }
        self.endedSessionIDs.append(session.sessionID)
    }

    private func connectedStatus(session: RemoteBrowserMCPSessionHandle) -> BrowserMCPStatus {
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
            providerSessionEpoch: self.omitProviderEpoch ? nil : self.epochs[session.sessionID])
    }

    private func response(for toolName: String?) -> ToolResponse {
        switch toolName {
        case "list_pages":
            ToolResponse(
                content: [.text(
                    text: "## Pages\n7: Example (https://example.test/) [selected]",
                    annotations: nil,
                    _meta: nil)],
                structuredContent: .object([
                    "pages": .array([.object([
                        "id": .int(7),
                        "url": .string("https://example.test/"),
                        "title": .string("Example"),
                        "selected": .bool(true),
                    ])]),
                ]))
        case "take_snapshot":
            ToolResponse(
                content: [.text(text: "uid=1_0 button \"Continue\"", annotations: nil, _meta: nil)],
                structuredContent: .object([
                    "snapshot": .object([
                        "id": .string("1_0"),
                        "role": .string("button"),
                        "name": .string("Continue"),
                    ]),
                ]))
        default:
            .text("ok")
        }
    }
}
