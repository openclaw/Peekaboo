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
    func `browser free MCP catalog starts on a legacy remote provider`() async throws {
        let legacy = LegacyUnscopedRemoteBrowserClient()
        let server = try await PeekabooMCPServer(
            toolContext: Self.remoteContext(browser: legacy),
            toolFilters: Self.filters(allowing: ["permissions", "sleep"]))

        #expect(await server.registeredToolNamesForTesting() == ["permissions", "sleep"])
        #expect(await server.browserClientForTesting() === legacy)
        #expect(legacy.callCount == 0)

        await server.stopForTesting()
        #expect(legacy.callCount == 0)
    }

    @Test
    func `browser catalog fails closed on a legacy remote provider`() async {
        let legacy = LegacyUnscopedRemoteBrowserClient()

        await #expect(throws: BrowserMCPConnectionError.receiptBindingUnsupported) {
            _ = try await PeekabooMCPServer(
                toolContext: Self.remoteContext(browser: legacy),
                toolFilters: Self.filters(allowing: ["browser"]))
        }
        #expect(legacy.callCount == 0)
    }

    @Test
    func `explicit handoff bootstraps even when browser is filtered out`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let grant = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let server = try await PeekabooMCPServer(
            toolContext: Self.context(browser: Self.rootClient(transport: transport)),
            browserHandoff: grant,
            toolFilters: Self.filters(allowing: ["permissions"]))

        #expect(transport.openedHandoffs == [grant.payload])
        #expect(await server.registeredToolNamesForTesting() == ["permissions"])

        await server.stopForTesting()
        #expect(transport.endedSessionIDs.count == 1)
    }

    @Test
    func `server registers the exact filtered native tool selection`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let root = Self.rootClient(transport: transport)
        let server = try await PeekabooMCPServer(
            toolContext: Self.context(browser: root),
            toolFilters: Self.filters(allowing: ["browser", "permissions", "sleep"]))

        #expect(await server.registeredToolNamesForTesting() == ["browser", "permissions", "sleep"])
        #expect(await server.browserClientForTesting() !== root)
        #expect(transport.openedHandoffs == [nil])

        await server.stopForTesting()
    }

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
        transport.checkEndCancellation = true
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
        _ = await scoped.endBrowserMCPScopedSession()
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

    @Test
    func `indeterminate dispatch stays unresolved after local retry failure`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.openErrors = [URLError(.timedOut), RemoteBrowserMCPSessionError.invalidHandle]
        let root = Self.rootClient(transport: transport)
        let handoff = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let differentHandoff = BrowserMCPHandoffGrant(payload: Data("different-connect-receipt".utf8))

        await #expect(throws: (any Error).self) {
            _ = try await root.openBrowserMCPScopedSession(handoff: handoff)
        }
        await #expect(throws: RemoteBrowserMCPSessionError.openAttemptUnresolved) {
            _ = try await root.openBrowserMCPScopedSession(handoff: differentHandoff)
        }
        _ = try await root.openBrowserMCPScopedSession(handoff: handoff)

        #expect(transport.openedClaimIDs.count == 3)
        #expect(Set(transport.openedClaimIDs).count == 1)
    }

    @Test(arguments: RemoteBrowserMCPSessionTransportError.allCases)
    func `terminal transport response resolves prior indeterminate claim`(
        terminalError: RemoteBrowserMCPSessionTransportError) async throws
    {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.openErrors = [URLError(.timedOut), terminalError]
        let root = Self.rootClient(transport: transport)
        let firstHandoff = BrowserMCPHandoffGrant(payload: Data("first-signed-connect-receipt".utf8))
        let secondHandoff = BrowserMCPHandoffGrant(payload: Data("second-signed-connect-receipt".utf8))

        await #expect(throws: terminalError) {
            _ = try await root.openBrowserMCPScopedSession(handoff: firstHandoff)
        }
        _ = try await root.openBrowserMCPScopedSession(handoff: secondHandoff)

        #expect(transport.openedClaimIDs.count == 3)
        #expect(transport.openedClaimIDs[0] == transport.openedClaimIDs[1])
        #expect(transport.openedClaimIDs[2] != transport.openedClaimIDs[1])
    }

    @Test
    func `unclassified open failure retains claim without automatic retry`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.openErrors = [UnclassifiedOpenFailure()]
        let root = Self.rootClient(transport: transport)
        let handoff = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let differentHandoff = BrowserMCPHandoffGrant(payload: Data("different-connect-receipt".utf8))

        await #expect(throws: UnclassifiedOpenFailure.self) {
            _ = try await root.openBrowserMCPScopedSession(handoff: handoff)
        }
        await #expect(throws: RemoteBrowserMCPSessionError.openAttemptUnresolved) {
            _ = try await root.openBrowserMCPScopedSession(handoff: differentHandoff)
        }
        _ = try await root.openBrowserMCPScopedSession(handoff: handoff)

        #expect(transport.openedClaimIDs.count == 2)
        #expect(Set(transport.openedClaimIDs).count == 1)
    }

    @Test
    func `response side URL failure retains claim without automatic retry`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.openErrors = [URLError(.badServerResponse)]
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

        #expect(transport.openedClaimIDs.count == 2)
        #expect(Set(transport.openedClaimIDs).count == 1)
    }

    @Test
    func `pre dispatch URL failure releases claim for a different handoff`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.openErrors = [URLError(.cannotConnectToHost)]
        let root = Self.rootClient(transport: transport)
        let firstHandoff = BrowserMCPHandoffGrant(payload: Data("first-signed-connect-receipt".utf8))
        let secondHandoff = BrowserMCPHandoffGrant(payload: Data("second-signed-connect-receipt".utf8))

        await #expect(throws: URLError.self) {
            _ = try await root.openBrowserMCPScopedSession(handoff: firstHandoff)
        }
        _ = try await root.openBrowserMCPScopedSession(handoff: secondHandoff)

        #expect(transport.openedClaimIDs.count == 2)
        #expect(transport.openedClaimIDs[0] != transport.openedClaimIDs[1])
    }

    @Test(arguments: [false, true])
    func `invalid open handle retains claim until cleanup resolves`(canonicalHandle: Bool) async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let invalidHandle = RemoteBrowserMCPSessionHandle(
            sessionID: canonicalHandle ? UUID() : Self.zeroUUID,
            targetReceiptSHA256: canonicalHandle ? String(repeating: "a", count: 64) : nil)
        transport.openHandles = [invalidHandle]
        if canonicalHandle {
            transport.endErrors = [CancellationError()]
        }
        let root = Self.rootClient(transport: transport)
        let differentHandoff = BrowserMCPHandoffGrant(payload: Data("different-connect-receipt".utf8))

        await #expect(throws: RemoteBrowserMCPSessionError.invalidHandle) {
            _ = try await root.openBrowserMCPScopedSession(handoff: nil)
        }
        await #expect(throws: RemoteBrowserMCPSessionError.openAttemptUnresolved) {
            _ = try await root.openBrowserMCPScopedSession(handoff: differentHandoff)
        }
        _ = try await root.openBrowserMCPScopedSession(handoff: nil)

        #expect(transport.openedClaimIDs.count == 2)
        #expect(Set(transport.openedClaimIDs).count == 1)
    }

    @Test(arguments: [
        RemoteBrowserMCPSessionTransportError.wrongOwner,
        RemoteBrowserMCPSessionTransportError.hostGenerationChanged,
    ])
    func `terminal invalid handle cleanup refusal poisons claim without replay`(
        terminalError: RemoteBrowserMCPSessionTransportError) async throws
    {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.openHandles = [RemoteBrowserMCPSessionHandle(
            sessionID: UUID(),
            targetReceiptSHA256: String(repeating: "a", count: 64))]
        transport.endErrors = [terminalError]
        let root = Self.rootClient(transport: transport)
        let differentHandoff = BrowserMCPHandoffGrant(payload: Data("different-connect-receipt".utf8))

        await #expect(throws: RemoteBrowserMCPSessionError.invalidHandle) {
            _ = try await root.openBrowserMCPScopedSession(handoff: nil)
        }
        await #expect(throws: RemoteBrowserMCPSessionError.openAttemptUnresolved) {
            _ = try await root.openBrowserMCPScopedSession(handoff: nil)
        }
        await #expect(throws: RemoteBrowserMCPSessionError.openAttemptUnresolved) {
            _ = try await root.openBrowserMCPScopedSession(handoff: differentHandoff)
        }

        #expect(transport.openedClaimIDs.count == 1)
        #expect(transport.endCallCount == 1)
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

    @Test(arguments: [false, true])
    func `transport cancellation code retains unresolved claim without automatic retry`(usesPOSIX: Bool) async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.openErrors = [usesPOSIX ? POSIXError(.ECANCELED) : URLError(.cancelled)]
        let root = Self.rootClient(transport: transport)
        let handoff = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let differentHandoff = BrowserMCPHandoffGrant(payload: Data("different-connect-receipt".utf8))

        await #expect(throws: (any Error).self) {
            _ = try await root.openBrowserMCPScopedSession(handoff: handoff)
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

    @Test(arguments: ["click", "dom_click"])
    func `remote MCP mints opaque refs and refuses raw or copied refs before transport`(action: String) async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let root = Self.rootClient(transport: transport)
        let base = Self.context(browser: root, executionPolicy: .foregroundAllowed)
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
                "action": action,
                "page_id": pageReference,
                "uid": "1_0",
            ]))
        #expect(rawElement.isError)
        #expect(transport.executeCallCount == dispatchCount)

        let clicked = try await first.execute(
            tool: firstTool,
            arguments: ToolArguments(raw: [
                "action": action,
                "page_id": pageReference,
                "uid": elementReference,
            ]))
        #expect(!clicked.isError)
        #expect(transport.executeCallCount == dispatchCount + 1)
        #expect(transport.elementPreflights.last??.providerPageID == 7)
        #expect(transport.elementPreflights.last??.providerUIDs == ["1_0"])
        #expect(clicked.meta?.objectValue?["delivery_mode"] == .string("foreground"))
        let evidence = try #require(clicked.meta?.objectValue?[BrowserMCPExecutionEvidence.metadataKey]?.objectValue)
        #expect(evidence["completed_call_count"] == .int(1))
        #expect(evidence["dispatched_call_count"] == .int(1))
        #expect(evidence["connection_receipt"] != nil)
        #expect(evidence["provider_session_epoch"] != nil)
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
        let context = try await Self.context(browser: root, executionPolicy: .foregroundAllowed)
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

        #expect(await context.releaseSnapshotOwner())
        #expect(transport.endCallCount == 0)
    }

    @Test
    func `authoritative execution refusal terminates scope before another call`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let root = Self.rootClient(transport: transport)
        let grant = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let context = try await Self.context(browser: root, executionPolicy: .foregroundAllowed)
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
    func `indeterminate disconnect reports failure and keeps exact capabilities for later status`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let root = Self.rootClient(transport: transport)
        let grant = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let context = try await Self.context(browser: root, executionPolicy: .foregroundAllowed)
            .openingBrowserSession(named: "mcp:disconnect-indeterminate", handoff: grant)
        let tool = BrowserTool(context: context)
        let client = context.browser
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        let confirmed = await client.status(channel: nil)
        let receipt = try #require(confirmed.connectionReceipt)
        let epoch = try #require(confirmed.providerSessionEpoch)
        transport.disconnectFailure = CancellationError()

        let disconnect = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "disconnect"]))
        #expect(disconnect.isError)
        #expect(!Self.text(from: disconnect).contains("Disconnected Chrome DevTools MCP"))
        let metadata = try #require(disconnect.meta?.objectValue)
        #expect(metadata["state"] == .string("indeterminate"))
        #expect(metadata["evidence"] == .string("completion_unknown"))
        #expect(metadata["retry_safe"] == .bool(false))

        transport.statusFailure = CancellationError()
        let indeterminate = await client.status(channel: nil)

        #expect(indeterminate.observation == .indeterminate)
        #expect(indeterminate.connectionReceipt == receipt)
        #expect(indeterminate.providerSessionEpoch == epoch)

        transport.disconnectFailure = nil
        transport.statusFailure = nil
        let executionCount = transport.executeCallCount
        let resumed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        #expect(!resumed.isError)
        #expect(transport.executeCallCount == executionCount + 1)
    }

    @Test
    func `confirmed disconnect invalidates capabilities and reports success`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let root = Self.rootClient(transport: transport)
        let grant = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let context = try await Self.context(browser: root, executionPolicy: .foregroundAllowed)
            .openingBrowserSession(named: "mcp:disconnect-confirmed", handoff: grant)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)

        let disconnect = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "disconnect"]))

        #expect(!disconnect.isError)
        #expect(Self.text(from: disconnect) == "Disconnected Chrome DevTools MCP.")
        #expect(transport.disconnectCallCount == 1)
        let executionCount = transport.executeCallCount
        let stale = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        #expect(stale.isError)
        #expect(transport.executeCallCount == executionCount)
    }

    @Test
    func `terminal disconnect refusal settles scope and reports success`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        let root = Self.rootClient(transport: transport)
        let grant = BrowserMCPHandoffGrant(payload: Data("signed-connect-receipt".utf8))
        let context = try await Self.context(browser: root)
            .openingBrowserSession(named: "mcp:disconnect-terminal", handoff: grant)
        let tool = BrowserTool(context: context)
        transport.disconnectFailure = RemoteBrowserMCPSessionTransportError.sessionEnded

        let disconnect = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "disconnect"]))

        #expect(!disconnect.isError)
        #expect(Self.text(from: disconnect) == "Disconnected Chrome DevTools MCP.")
        #expect(transport.disconnectCallCount == 1)
        let statusCalls = transport.statusCallCount
        let terminal = await context.browser.status(channel: nil)
        #expect(terminal.observation == .confirmed)
        #expect(terminal.connectionReceipt == nil)
        #expect(terminal.providerSessionEpoch == nil)
        #expect(transport.statusCallCount == statusCalls)
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

        #expect(await !context.releaseSnapshotOwner())
        #expect(transport.endCallCount == 1)
        let statusCallsBefore = transport.statusCallCount
        let cleanupDebt = await client.status(channel: nil)
        #expect(cleanupDebt.observation == .confirmed)
        #expect(cleanupDebt.connectionReceipt == nil)
        #expect(transport.statusCallCount == statusCallsBefore)

        #expect(await !context.releaseSnapshotOwner())
        #expect(transport.endCallCount == 2)
        #expect(await context.releaseSnapshotOwner())
        #expect(transport.endCallCount == 3)
        #expect(transport.endedSessionIDs.count == 1)
        #expect(await context.releaseSnapshotOwner())
        #expect(transport.endCallCount == 3)
    }

    @Test
    func `concurrent end request retries an in flight transient cleanup failure`() async throws {
        let transport = RecordingRemoteBrowserSessionTransport()
        transport.pauseFirstEnd = true
        transport.endErrors = [URLError(.timedOut)]
        let root = Self.rootClient(transport: transport)
        let ending = try await root.openBrowserMCPScopedSession(handoff: nil)

        let firstEnd = Task { @MainActor in
            await ending.endBrowserMCPScopedSession()
        }
        await transport.waitUntilFirstEndIsPaused()
        let overlappingEnd = Task { @MainActor in
            await ending.endBrowserMCPScopedSession()
        }
        transport.resumeFirstEnd()
        #expect(await firstEnd.value)
        #expect(await overlappingEnd.value)

        #expect(transport.endCallCount == 2)
        #expect(transport.endedSessionIDs.count == 1)
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

        let listPages = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        #expect(listPages.isError)
        #expect(listPages.meta?.objectValue?["refusal_reason"] == .string("foreground_consent_required"))
        #expect(transport.executeCallCount == 0)
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

    private static func context(
        browser: any BrowserMCPClientProviding,
        executionPolicy: MCPToolExecutionPolicy = .backgroundOnly) -> MCPToolContext
    {
        let services = PeekabooServices(initializeAgentService: false)
        return MCPToolContext(
            services: services,
            browser: browser,
            executionPolicy: executionPolicy)
    }

    private static func remoteContext(browser: any BrowserMCPClientProviding) -> MCPToolContext {
        let services = RemotePeekabooServices(client: PeekabooBridgeClient(
            socketPath: "/private/tmp/peekaboo-legacy-remote-browser-session.sock"))
        return MCPToolContext(
            services: services,
            browser: browser,
            executionPolicy: .backgroundOnly)
    }

    private static func filters(allowing toolNames: Set<String>) -> ToolFilters {
        ToolFilters(
            allow: toolNames,
            deny: [],
            allowSource: .config,
            denySources: [:])
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

    private static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

private struct UnclassifiedOpenFailure: Error {}

@MainActor
private final class LegacyUnscopedRemoteBrowserClient: BrowserMCPClientProviding, @unchecked Sendable {
    private(set) var callCount = 0

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        self.callCount += 1
        return BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
    }

    func connect(channel _: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        self.callCount += 1
        return BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
    }

    func disconnect() async {
        self.callCount += 1
    }

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        self.callCount += 1
        return .text("unexpected legacy remote browser call")
    }
}

@MainActor
private final class RecordingRemoteBrowserSessionTransport: RemoteBrowserMCPSessionTransport, @unchecked Sendable {
    private(set) var openedHandoffs: [Data?] = []
    private(set) var openedClaimIDs: [UUID] = []
    private(set) var statusCallCount = 0
    private(set) var connectCallCount = 0
    private(set) var executeCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var endedSessionIDs: [UUID] = []
    private(set) var elementPreflights: [BrowserMCPElementPreflight?] = []
    var omitTargetDigest = false
    var omitProviderEpoch = false
    var statusFailure: (any Error)?
    var executeFailure: (any Error)?
    var disconnectFailure: (any Error)?
    var openErrors: [any Error] = []
    var openHandles: [RemoteBrowserMCPSessionHandle] = []
    var endErrors: [any Error] = []
    var checkEndCancellation = false
    var pauseFirstEnd = false
    private(set) var endCallCount = 0
    private var firstEndContinuation: CheckedContinuation<Void, Never>?
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
        if !self.openHandles.isEmpty {
            return self.openHandles.removeFirst()
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
        self.disconnectCallCount += 1
        if let disconnectFailure {
            throw disconnectFailure
        }
    }

    func endSession(_ session: RemoteBrowserMCPSessionHandle) async throws {
        if self.checkEndCancellation {
            try Task.checkCancellation()
        }
        self.endCallCount += 1
        if self.pauseFirstEnd, self.endCallCount == 1 {
            await withCheckedContinuation { continuation in
                self.firstEndContinuation = continuation
            }
        }
        if !self.endErrors.isEmpty {
            throw self.endErrors.removeFirst()
        }
        self.endedSessionIDs.append(session.sessionID)
    }

    func waitUntilFirstEndIsPaused() async {
        while self.firstEndContinuation == nil {
            await Task.yield()
        }
    }

    func resumeFirstEnd() {
        self.firstEndContinuation?.resume()
        self.firstEndContinuation = nil
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
