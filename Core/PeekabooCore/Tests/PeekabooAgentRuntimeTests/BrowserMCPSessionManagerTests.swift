import Darwin
import Foundation
import MCP
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserMCPSessionManagerTests {
    @Test
    func `channel connect refuses ambiguous same-channel processes before spawning MCP`() async {
        let manager = MockBrowserMCPManager()
        let browsers = [
            Self.browser(pid: 41, generation: 1041),
            Self.browser(pid: 42, generation: 1042),
        ]
        let session = Self.session(manager: manager, browsers: browsers)

        await #expect(throws: BrowserMCPConnectionError.ambiguousBrowsers(.stable, [41, 42])) {
            _ = try await session.connect(channel: .stable)
        }
        #expect(manager.addedConfigs.isEmpty)
        #expect(manager.executedTools.isEmpty)
    }

    @Test
    func `connect probes list pages and publishes exact process receipt`() async throws {
        let manager = MockBrowserMCPManager()
        let browser = Self.browser(pid: 51, generation: 2051)
        let session = Self.session(manager: manager, browsers: [browser])

        let result = try await session.connectWithOutcome(channel: .stable)
        let status = result.payload

        #expect(status.isConnected)
        #expect(status.toolCount == 29)
        #expect(status.connectionReceipt?.processIdentifier == 51)
        #expect(status.connectionReceipt?.processStartIdentity == 2051)
        #expect(manager.executedTools == ["list_pages"])
        #expect(manager.addedConfigs.count == 1)
        #expect(manager.addedConfigs[0].autoReconnect == false)
        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.delivery == .init(mechanism: .browserProtocol, mode: .foreground))
        #expect(result.outcome?.dispatchState.unitCount == .one)
    }

    @Test
    func `repeated connect confirms no change without another connection dispatch`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(manager: manager, browsers: [Self.browser(pid: 52, generation: 2052)])
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()

        let result = try await session.connectWithOutcome(channel: .stable)

        #expect(result.payload.isConnected)
        #expect(result.outcome?.state == .confirmedNoChange)
        #expect(result.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(manager.addedConfigs.count == 1)
        #expect(manager.executedTools.isEmpty)
    }

    @Test
    func `status waits for an in flight connection lifecycle`() async throws {
        let manager = MockBrowserMCPManager()
        let barrier = SequenceBarrier()
        manager.executeHandler = { toolName, _ in
            if toolName == "list_pages" {
                await barrier.block()
            }
            return ToolResponse.text("ok")
        }
        let session = Self.exactSession(manager: manager)

        let connection = Task { @MainActor in
            try await session.connect(channel: .stable)
        }
        await barrier.waitUntilBlocked()
        let concurrentStatus = Task { @MainActor in
            await session.status(channel: .stable)
        }
        await Task.yield()
        await Task.yield()

        #expect(manager.executedTools == ["list_pages"])
        #expect(manager.removeCount == 0)
        #expect(manager.connected)

        await barrier.release()
        let connected = try await connection.value
        let observed = await concurrentStatus.value
        #expect(connected.isConnected)
        #expect(observed.isConnected)
        #expect(observed.connectionReceipt == connected.connectionReceipt)
        #expect(manager.removeCount == 0)
    }

    @Test
    func `failed connection probe reports indeterminate foreground dispatch and clears child`() async {
        let manager = MockBrowserMCPManager()
        manager.executeError = MockBrowserError.probe
        let session = Self.session(manager: manager, browsers: [Self.browser(pid: 61, generation: 3061)])

        do {
            _ = try await session.connectWithOutcome(channel: .stable)
            Issue.record("Expected the accepted browser connection attempt to fail indeterminately")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .browserProtocol, mode: .foreground))
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Expected a canonical indeterminate connection failure, got \(error)")
        }
        #expect(manager.removeCount == 1)
        #expect(!manager.connected)
        let failedWorkspace = manager.addedConfigs.first?.env["TMPDIR"]
        #expect(failedWorkspace.map { !FileManager.default.fileExists(atPath: $0) } == true)
        let status = await session.status(channel: .stable)
        #expect(!status.isConnected)
        #expect(status.connectionReceipt == nil)
    }

    @Test
    func `lost MCP child refuses without implicit reconnect`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(manager: manager, browsers: [Self.browser(pid: 71, generation: 4071)])
        _ = try await session.connect(channel: .stable)
        manager.connected = false
        manager.executedTools.removeAll()

        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await session.execute(toolName: "take_snapshot", arguments: [:], channel: nil)
        }
        #expect(manager.addedConfigs.count == 1)
        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeCount == 1)
    }

    @Test
    func `unbound process generation drift clears stale connection and preserves error`() async throws {
        let manager = MockBrowserMCPManager()
        let currentGeneration = GenerationBox(5081)
        let browser = Self.browser(pid: 81, generation: 5081)
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [browser] },
            processStartIdentity: { _ in currentGeneration.get() },
            endpointResolver: Self.endpointResolver())
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        currentGeneration.set(5082)

        await #expect(throws: BrowserMCPConnectionError.connectionLost(
            "Chrome PID 81 changed process generation"))
        {
            _ = try await session.execute(toolName: "take_snapshot", arguments: [:], channel: nil)
        }
        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeCount == 1)
        #expect(!manager.connected)
        #expect(await (session.status(channel: .stable)).connectionReceipt == nil)
    }

    @Test
    func `receipt bound execution returns the exact dispatch connection`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        let connected = try await session.connect(channel: .stable)
        let receipt = try #require(connected.connectionReceipt)
        manager.executedTools.removeAll()

        let result = try await session.executeSequence(
            [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: [:])],
            channel: nil,
            expectedConnectionReceipt: receipt)

        #expect(result.connectionReceipt == receipt)
        #expect(result.completedCallCount == 1)
        #expect(result.dispatchedCallCount == 1)
        #expect(result.actionFailure == nil)
        #expect(manager.executedTools == ["take_snapshot"])
    }

    @Test
    func `action result service maps exact connection drift to zero dispatch refusal`() async throws {
        let manager = MockBrowserMCPManager()
        let endpoints = EndpointMap()
        await endpoints.set("browser-a", port: 9222)
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                try await endpoints.resolve(url)
            },
            environment: [:])
        _ = try await session.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        manager.executedTools.removeAll()
        manager.isConnectedHandler = {
            await endpoints.set("browser-b", port: 9222)
            return true
        }
        let service = BrowserMCPService(sessionManager: session)

        do {
            _ = try await service.executeSequenceWithOutcome(
                [BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "71_1"])],
                channel: nil)
            Issue.record("Expected exact browser connection drift to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.hint == "Refresh browser status and retry against its new connection receipt.")
        }
        #expect(manager.executedTools.isEmpty)
    }

    @Test
    func `Browser tool projects receipt binding incompatibility as canonical refusal`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(manager: manager, browsers: [Self.browser(pid: 822, generation: 5822)])
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        let service = BrowserMCPService(sessionManager: session)

        let response = try await BrowserTool(client: service, executionPolicy: .unrestricted)
            .execute(arguments: ToolArguments(raw: [
                "action": "click",
                "channel": "stable",
                "page_id": 7,
                "uid": "7_1",
            ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("refused"))
        #expect(meta["refusal_reason"] == .string("operation_unsupported"))
        #expect(meta["dispatch_state"] == .string("none"))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(manager.executedTools.isEmpty)
    }

    @Test
    func `action result service preserves unrelated connection errors`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        let service = BrowserMCPService(sessionManager: session)

        await #expect(throws: BrowserMCPConnectionError.connectionLost(
            "the browser action sequence was empty"))
        {
            _ = try await service.executeSequenceWithOutcome([], channel: .stable)
        }
        #expect(manager.executedTools.isEmpty)
    }
}

extension BrowserMCPSessionManagerTests {
    @Test
    func `existing receipt policy refuses a disconnected read without connecting or dispatching`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(manager: manager, browsers: [Self.browser(pid: 821, generation: 5821)])

        do {
            _ = try await session.executeSequenceResult(
                [BrowserMCPMappedCall(toolName: "list_pages", arguments: [:])],
                channel: .stable,
                connectionPolicy: .requireExistingLiveReceipt)
            Issue.record("Expected existing-receipt browser execution to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.message == "Browser execution requires an existing live exact connection receipt.")
        }

        #expect(manager.addedConfigs.isEmpty)
        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeCount == 0)
    }

    @Test
    func `existing receipt policy allows a preconnected read without reconnecting`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(manager: manager, browsers: [Self.browser(pid: 822, generation: 5822)])
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()

        let result = try await session.executeSequenceResult(
            [BrowserMCPMappedCall(toolName: "list_pages", arguments: [:])],
            channel: .stable,
            connectionPolicy: .requireExistingLiveReceipt)

        #expect(!result.response.isError)
        #expect(manager.addedConfigs.count == 1)
        #expect(manager.executedTools == ["list_pages"])
        #expect(manager.removeCount == 0)
    }

    @Test
    func `existing receipt policy clears a lost child without reconnecting`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(manager: manager, browsers: [Self.browser(pid: 824, generation: 5824)])
        _ = try await session.connect(channel: .stable)
        manager.connected = false
        manager.executedTools.removeAll()

        do {
            _ = try await session.executeSequenceResult(
                [BrowserMCPMappedCall(toolName: "list_pages", arguments: [:])],
                channel: .stable,
                connectionPolicy: .requireExistingLiveReceipt)
            Issue.record("Expected a lost existing browser connection to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }

        #expect(manager.addedConfigs.count == 1)
        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeCount == 1)
    }

    @Test
    func `action result service omits mutation outcome for successful read sequence`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        let service = BrowserMCPService(sessionManager: session)

        let result = try await service.executeSequenceWithOutcome(
            [
                BrowserMCPMappedCall(toolName: "list_pages", arguments: [:]),
                BrowserMCPMappedCall(toolName: "take_snapshot", arguments: ["pageId": 7]),
            ],
            channel: .stable)

        #expect(!result.payload.isError)
        #expect(result.outcome == nil)
        #expect(manager.executedTools == ["list_pages", "take_snapshot"])
        let evidence = try #require(
            result.payload.meta?.objectValue?[BrowserMCPExecutionEvidence.metadataKey]?.objectValue)
        #expect(evidence["completed_call_count"] == .int(2))
        #expect(evidence["dispatched_call_count"] == .int(2))
        let receipt = try #require(evidence["connection_receipt"]?.objectValue)
        #expect(receipt["browser_url"] == .string("http://127.0.0.1:9222/"))
        #expect(receipt["browser_id"] == .string("browser-a"))
    }

    @Test(arguments: ["list_pages", "take_snapshot"])
    func `successful existing connection read publishes exact execution evidence`(toolName: String) async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        let service = BrowserMCPService(sessionManager: session)
        let arguments: [String: Any] = toolName == "take_snapshot" ? ["pageId": 7] : [:]

        let result = try await service.executeSequenceWithOutcome(
            [BrowserMCPMappedCall(toolName: toolName, arguments: arguments)],
            channel: .stable)

        #expect(!result.payload.isError)
        #expect(result.outcome == nil)
        #expect(manager.executedTools == [toolName])
        let evidence = try #require(
            result.payload.meta?.objectValue?[BrowserMCPExecutionEvidence.metadataKey]?.objectValue)
        #expect(evidence["completed_call_count"] == .int(1))
        #expect(evidence["dispatched_call_count"] == .int(1))
        let receipt = try #require(evidence["connection_receipt"]?.objectValue)
        #expect(receipt["browser_url"] == .string("http://127.0.0.1:9222/"))
        #expect(receipt["websocket_debugger_url"] ==
            .string("ws://127.0.0.1:9222/devtools/browser/browser-a"))
        #expect(receipt["browser_id"] == .string("browser-a"))
    }

    @Test
    func `action result service omits mutation outcome for failed read sequence`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        manager.executeHandler = { toolName, _ in
            toolName == "take_snapshot" ? .error("fixture snapshot failed") : .text("ok")
        }
        let service = BrowserMCPService(sessionManager: session)

        let result = try await service.executeSequenceWithOutcome(
            [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: ["pageId": 7])],
            channel: .stable)

        #expect(result.payload.isError)
        #expect(result.outcome == nil)
        #expect(result.payload.meta?.objectValue?[BrowserMCPExecutionEvidence.metadataKey] == nil)
        #expect(manager.executedTools == ["take_snapshot"])
    }

    @Test
    func `action result service omits mutation outcome for uncertain read transport failure`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        manager.executeHandler = { _, _ in throw MockBrowserError.probe }
        let service = BrowserMCPService(sessionManager: session)

        let result = try await service.executeSequenceWithOutcome(
            [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: ["pageId": 7])],
            channel: .stable)

        #expect(result.payload.isError)
        #expect(result.outcome == nil)
        #expect(result.payload.meta?.objectValue?[BrowserMCPExecutionEvidence.metadataKey] == nil)
        #expect(manager.executedTools == ["take_snapshot"])
        #expect(!manager.connected)
    }

    @Test
    func `action result service retains exact units for mutating sequence`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        let service = BrowserMCPService(sessionManager: session)

        let result = try await service.executeSequenceWithOutcome(
            [
                BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "7_1"]),
                BrowserMCPMappedCall(toolName: "type_text", arguments: ["text": "value"]),
            ],
            channel: .stable)

        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 2)
        #expect(manager.executedTools == ["click", "type_text"])
    }

    @Test
    func `action result service auto connects a mutating sequence when allowed`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 824, generation: 5824)])
        let service = BrowserMCPService(sessionManager: session)

        let result = try await service.executeSequenceWithOutcome(
            [BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "7_1"])],
            channel: .stable,
            connectionPolicy: .allowAutoConnect)

        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.delivery == .init(mechanism: .browserProtocol, mode: .foreground))
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 2)
        #expect(manager.addedConfigs.count == 1)
        #expect(manager.executedTools == ["list_pages", "click"])
        let evidence = try #require(
            result.payload.meta?.objectValue?[BrowserMCPExecutionEvidence.metadataKey]?.objectValue)
        #expect(evidence["completed_call_count"] == .int(1))
        #expect(evidence["dispatched_call_count"] == .int(1))
    }

    @Test
    func `action result service exposes implicit foreground connect before a read`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 826, generation: 5826)])
        let service = BrowserMCPService(sessionManager: session)

        let result = try await service.executeSequenceWithOutcome(
            [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: ["pageId": 7])],
            channel: .stable,
            connectionPolicy: .allowAutoConnect)

        #expect(!result.payload.isError)
        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.delivery == .init(mechanism: .browserProtocol, mode: .foreground))
        #expect(result.outcome?.dispatchState.unitCount == .one)
        #expect(manager.executedTools == ["list_pages", "take_snapshot"])
    }

    @Test
    func `already connected auto policy reports only the requested background mutation`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        let service = BrowserMCPService(sessionManager: session)

        let result = try await service.executeSequenceWithOutcome(
            [BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "7_1"])],
            channel: .stable,
            connectionPolicy: .allowAutoConnect)

        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.delivery == .init(mechanism: .browserProtocol, mode: .background))
        #expect(result.outcome?.dispatchState.unitCount == .one)
        #expect(manager.addedConfigs.count == 1)
        #expect(manager.executedTools == ["click"])
    }

    @Test
    func `read failure after implicit connect preserves the foreground setup unit`() async throws {
        let manager = MockBrowserMCPManager()
        manager.executeHandler = { toolName, _ in
            toolName == "take_snapshot" ? .error("fixture read failed") : .text("ok")
        }
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 828, generation: 5828)])
        let service = BrowserMCPService(sessionManager: session)

        let result = try await service.executeSequenceWithOutcome(
            [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: ["pageId": 7])],
            channel: .stable,
            connectionPolicy: .allowAutoConnect)

        #expect(result.payload.isError)
        #expect(result.outcome?.state == .indeterminate)
        #expect(result.outcome?.delivery == .init(mechanism: .browserProtocol, mode: .foreground))
        #expect(result.outcome?.dispatchState.unitCount == .one)
        #expect(result.outcome?.retrySafety == .unsafe)
        #expect(manager.executedTools == ["list_pages", "take_snapshot"])
    }

    @Test
    func `cancellation after implicit connect preserves setup and uncertain mutation units`() async throws {
        let manager = MockBrowserMCPManager()
        manager.executeHandler = { toolName, _ in
            if toolName == "click" {
                throw CancellationError()
            }
            return .text("ok")
        }
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 829, generation: 5829)])
        let service = BrowserMCPService(sessionManager: session)

        let result = try await service.executeSequenceWithOutcome(
            [BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "7_1"])],
            channel: .stable,
            connectionPolicy: .allowAutoConnect)

        #expect(result.payload.isError)
        #expect(result.outcome?.state == .indeterminate)
        #expect(result.outcome?.delivery == .init(mechanism: .browserProtocol, mode: .foreground))
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 2)
        #expect(result.outcome?.retrySafety == .unsafe)
        #expect(manager.executedTools == ["list_pages", "click"])
    }

    @Test
    func `cancellation after implicit connect but before leaf dispatch preserves only setup`() async throws {
        let manager = MockBrowserMCPManager()
        manager.executeHandler = { toolName, _ in
            if toolName == "list_pages" {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return .text("ok")
        }
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 830, generation: 5830)])
        let service = BrowserMCPService(sessionManager: session)

        let result = try await Task { @MainActor in
            try await service.executeSequenceWithOutcome(
                [BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "7_1"])],
                channel: .stable,
                connectionPolicy: .allowAutoConnect)
        }.value

        #expect(result.payload.isError)
        #expect(result.outcome?.state == .indeterminate)
        #expect(result.outcome?.delivery == .init(mechanism: .browserProtocol, mode: .foreground))
        #expect(result.outcome?.dispatchState.unitCount == .one)
        #expect(result.outcome?.retrySafety == .unsafe)
        #expect(manager.executedTools == ["list_pages"])
    }

    @Test
    func `auto connected unbound session refuses a repeated mutation`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 825, generation: 5825)])
        let service = BrowserMCPService(sessionManager: session)

        let first = try await service.executeSequenceWithOutcome(
            [BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "7_1"])],
            channel: .stable,
            connectionPolicy: .allowAutoConnect)
        #expect(first.outcome?.state == .dispatchedUnverified)
        #expect(manager.executedTools == ["list_pages", "click"])

        do {
            _ = try await service.executeSequenceWithOutcome(
                [BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "7_2"])],
                channel: .stable,
                connectionPolicy: .allowAutoConnect)
            Issue.record("Expected the repeated unbound mutation to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .operationUnsupported)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(manager.executedTools == ["list_pages", "click"])
    }

    @Test
    func `mixed successful sequence counts only mutating calls`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        let service = BrowserMCPService(sessionManager: session)

        let result = try await service.executeSequenceWithOutcome(
            [
                BrowserMCPMappedCall(toolName: "take_snapshot", arguments: ["pageId": 7]),
                BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "7_1"]),
                BrowserMCPMappedCall(toolName: "list_console_messages", arguments: ["pageId": 7]),
            ],
            channel: .stable)

        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.dispatchState.unitCount == .one)
        #expect(manager.executedTools == ["take_snapshot", "click", "list_console_messages"])
    }

    @Test
    func `read failure before mutation is a retry safe no-dispatch refusal`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        manager.executeHandler = { toolName, _ in
            toolName == "take_snapshot" ? .error("fixture read failed") : .text("ok")
        }
        let service = BrowserMCPService(sessionManager: session)

        let result = try await service.executeSequenceWithOutcome(
            [
                BrowserMCPMappedCall(toolName: "take_snapshot", arguments: ["pageId": 7]),
                BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "7_1"]),
            ],
            channel: .stable)

        #expect(result.payload.isError)
        #expect(result.outcome?.state == .refused)
        #expect(result.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(result.outcome?.retrySafety == .safe)
        #expect(result.outcome?.refusalReason == .targetUnavailable)
        #expect(manager.executedTools == ["take_snapshot"])
    }

    @Test
    func `read then mutate failure projects only uncertain mutation unit`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        manager.executeHandler = { toolName, _ in
            toolName == "click" ? .error("fixture click failed") : .text("ok")
        }
        let service = BrowserMCPService(sessionManager: session)

        let result = try await service.executeSequenceWithOutcome(
            [
                BrowserMCPMappedCall(toolName: "take_snapshot", arguments: ["pageId": 7]),
                BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "7_1"]),
            ],
            channel: .stable)

        #expect(result.payload.isError)
        #expect(result.outcome?.state == .indeterminate)
        #expect(result.outcome?.dispatchState.unitCount == .one)
        #expect(manager.executedTools == ["take_snapshot", "click"])
    }

    @Test
    func `mutate then read failure preserves only accepted mutation prefix`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        manager.executeHandler = { toolName, _ in
            toolName == "take_snapshot" ? .error("fixture read failed") : .text("ok")
        }
        let service = BrowserMCPService(sessionManager: session)

        let result = try await service.executeSequenceWithOutcome(
            [
                BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "7_1"]),
                BrowserMCPMappedCall(toolName: "take_snapshot", arguments: ["pageId": 7]),
            ],
            channel: .stable)

        #expect(result.payload.isError)
        #expect(result.outcome?.state == .partial)
        #expect(result.outcome?.dispatchState.unitCount == .one)
        #expect(result.outcome?.retrySafety == .unsafe)
        #expect(manager.executedTools == ["click", "take_snapshot"])
    }

    @Test
    func `auto connect receipt incompatible session allows read outcome path`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(manager: manager, browsers: [Self.browser(pid: 823, generation: 5823)])
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        let service = BrowserMCPService(sessionManager: session)

        let result = try await service.executeSequenceWithOutcome(
            [BrowserMCPMappedCall(toolName: "list_pages", arguments: [:])],
            channel: .stable)

        #expect(!result.payload.isError)
        #expect(result.outcome == nil)
        let evidence = try #require(
            result.payload.meta?.objectValue?[BrowserMCPExecutionEvidence.metadataKey]?.objectValue)
        #expect(evidence["completed_call_count"] == .int(1))
        #expect(evidence["dispatched_call_count"] == .int(1))
        #expect(manager.executedTools == ["list_pages"])
    }

    @Test
    func `isolated receipt incompatible session allows raw snapshot read`() async throws {
        let manager = MockBrowserMCPManager()
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            endpointResolver: Self.endpointResolver(),
            environment: ["PEEKABOO_BROWSER_MCP_ISOLATED": "1"])
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        let service = BrowserMCPService(sessionManager: session)

        let response = try await BrowserTool(client: service, executionPolicy: .unrestricted)
            .execute(arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "take_snapshot",
                "page_id": 7,
            ]))

        #expect(!response.isError)
        let evidence = try #require(
            response.meta?.objectValue?[BrowserMCPExecutionEvidence.metadataKey]?.objectValue)
        #expect(evidence["completed_call_count"] == .int(1))
        #expect(evidence["dispatched_call_count"] == .int(1))
        #expect(evidence["connection_receipt"]?.objectValue?["channel"] == .string("stable"))
        #expect(MCPToolResponseMetadataProjector.actionOutcomeKeys.allSatisfy {
            response.meta?.objectValue?[$0] == nil
        })
        #expect(manager.executedTools == ["take_snapshot"])
    }

    @Test
    func `raw list pages read publishes execution evidence without mutation metadata`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(manager: manager, browsers: [Self.browser(pid: 824, generation: 5824)])
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        let service = BrowserMCPService(sessionManager: session)

        let response = try await BrowserTool(client: service, executionPolicy: .unrestricted)
            .execute(arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "list_pages",
            ]))

        #expect(!response.isError)
        let evidence = try #require(
            response.meta?.objectValue?[BrowserMCPExecutionEvidence.metadataKey]?.objectValue)
        #expect(evidence["completed_call_count"] == .int(1))
        #expect(evidence["dispatched_call_count"] == .int(1))
        #expect(evidence["connection_receipt"]?.objectValue?["pid"] == .int(824))
        #expect(MCPToolResponseMetadataProjector.actionOutcomeKeys.allSatisfy {
            response.meta?.objectValue?[$0] == nil
        })
        #expect(manager.executedTools == ["list_pages"])
    }

    @Test
    func `action result cancellation while waiting for execution gate is retry safe`() async throws {
        let manager = MockBrowserMCPManager()
        let barrier = SequenceBarrier()
        manager.executeHandler = { toolName, _ in
            if toolName == "take_snapshot" {
                await barrier.block()
            }
            return ToolResponse.text("ok")
        }
        let session = Self.exactSession(manager: manager)
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        let service = BrowserMCPService(sessionManager: session)
        let occupyingExecution = Task { @MainActor in
            try await session.executeSequence(
                [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: [:])],
                channel: .stable)
        }
        await barrier.waitUntilBlocked()

        let waitingExecution = Task { @MainActor () -> DesktopActionFailure? in
            do {
                _ = try await service.executeSequenceWithOutcome(
                    [BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "81_1"])],
                    channel: .stable)
                Issue.record("Expected gate-waiting browser execution to be cancelled")
                return nil
            } catch let failure as DesktopActionFailure {
                return failure
            } catch {
                Issue.record("Expected canonical cancellation failure, got \(error)")
                return nil
            }
        }
        await Task.yield()
        await Task.yield()
        waitingExecution.cancel()
        let failure = try #require(await waitingExecution.value)

        #expect(failure.outcome.state == .refused)
        #expect(failure.outcome.refusalReason == .requestCancelled)
        #expect(failure.outcome.escalation == .none)
        #expect(failure.outcome.dispatchState == .none)
        #expect(failure.outcome.retrySafety == .safe)
        #expect(manager.executedTools == ["take_snapshot"])

        await barrier.release()
        _ = try await occupyingExecution.value
    }

    @Test
    func `action result cancellation during endpoint status probe is retry safe`() async throws {
        let manager = MockBrowserMCPManager()
        let endpoints = EndpointMap()
        await endpoints.set("browser-a", port: 9222)
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                try await endpoints.resolve(url)
            },
            environment: [:])
        _ = try await session.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        manager.executedTools.removeAll()
        await endpoints.cancelResolution()
        let service = BrowserMCPService(sessionManager: session)

        do {
            _ = try await service.executeSequenceWithOutcome(
                [BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "7_1"])],
                channel: nil)
            Issue.record("Expected endpoint-probe cancellation to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.escalation == .none)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeCount == 0)
    }

    @Test
    func `ordinary disconnected action result remains target unavailable`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        let service = BrowserMCPService(sessionManager: session)

        do {
            _ = try await service.executeSequenceWithOutcome(
                [BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "7_1"])],
                channel: .stable)
            Issue.record("Expected disconnected browser execution to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(manager.executedTools.isEmpty)
    }
}

extension BrowserMCPSessionManagerTests {
    @Test
    func `channel auto connect refuses receipt bound execution before dispatch`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(manager: manager, browsers: [Self.browser(pid: 821, generation: 5821)])
        let receipt = try #require(try await (session.connect(channel: .stable)).connectionReceipt)
        manager.executedTools.removeAll()

        await #expect(throws: BrowserMCPConnectionError.receiptBindingUnsupported) {
            _ = try await session.executeSequence(
                [BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "821_1"])],
                channel: .stable,
                expectedConnectionReceipt: receipt)
        }

        #expect(manager.executedTools.isEmpty)
        let legacy = try await session.execute(
            toolName: "click",
            arguments: ["uid": "821_1"],
            channel: .stable)
        #expect(!legacy.isError)
        #expect(manager.executedTools == ["click"])
    }

    @Test
    func `environment browser URL resolves one exact endpoint receipt and config`() async throws {
        let manager = MockBrowserMCPManager()
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            endpointResolver: Self.endpointResolver(),
            environment: ["PEEKABOO_BROWSER_MCP_BROWSER_URL": "http://127.0.0.1:9222"])

        let status = try await session.connect(channel: .stable)

        #expect(status.connectionReceipt?.browserURL == "http://127.0.0.1:9222/")
        #expect(status.connectionReceipt?.processIdentifier == nil)
        #expect(manager.addedConfigs[0].args.contains(
            "--wsEndpoint=ws://127.0.0.1:9222/devtools/browser/browser-a"))
        #expect(!manager.addedConfigs[0].args.contains("--browserUrl=http://127.0.0.1:9222"))
        #expect(!manager.addedConfigs[0].args.contains("--auto-connect"))
    }

    @Test
    func `isolated browser remains legacy only and cannot mint an exact receipt`() async throws {
        let manager = MockBrowserMCPManager()
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            endpointResolver: Self.endpointResolver(),
            environment: ["PEEKABOO_BROWSER_MCP_ISOLATED": "1"])
        let receipt = try #require(try await (session.connect(channel: .stable)).connectionReceipt)
        #expect(receipt.processIdentifier == nil)
        #expect(receipt.browserURL == nil)
        #expect(manager.addedConfigs[0].args.contains("--isolated"))
        manager.executedTools.removeAll()

        await #expect(throws: BrowserMCPConnectionError.receiptBindingUnsupported) {
            _ = try await session.executeSequence(
                [BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "1_1"])],
                channel: .stable,
                expectedConnectionReceipt: receipt)
        }
        #expect(manager.executedTools.isEmpty)
        let legacy = try await session.execute(
            toolName: "click",
            arguments: ["uid": "1_1"],
            channel: .stable)
        #expect(!legacy.isError)
        #expect(manager.executedTools == ["click"])
    }

    @Test
    func `concurrent reconnect refuses an old receipt before read-only dispatch`() async throws {
        let manager = MockBrowserMCPManager()
        let stable = Self.browser(pid: 83, generation: 5083)
        let canary = DetectedBrowser(
            name: "Google Chrome Canary",
            bundleIdentifier: "com.google.Chrome.canary",
            processIdentifier: 84,
            processStartIdentity: 5084,
            version: "151.0",
            channel: .canary)
        let browsers = BrowserListBox([stable])
        let generations: [Int32: UInt64] = [83: 5083, 84: 5084]
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { channel in
                browsers.get(channel: channel)
            },
            processStartIdentity: { generations[$0] },
            endpointResolver: Self.endpointResolver())
        let connected = try await session.connect(channel: .stable)
        let original = try #require(connected.connectionReceipt)
        await session.disconnect()
        browsers.set([canary])
        _ = try await session.connect(channel: .canary)
        manager.executedTools.removeAll()

        await #expect(throws: BrowserMCPConnectionError.expectedConnectionReceiptMismatch) {
            _ = try await session.executeSequence(
                [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: [:])],
                channel: nil,
                expectedConnectionReceipt: original)
        }

        #expect(manager.executedTools.isEmpty)
    }

    @Test
    func `exact endpoint is converted to WebSocket target and locked until disconnect`() async throws {
        let manager = MockBrowserMCPManager()
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            endpointResolver: Self.endpointResolver())

        let status = try await session.connect(
            channel: .stable,
            browserURL: "http://127.0.0.1:9222")
        #expect(status.connectionReceipt?.browserURL == "http://127.0.0.1:9222/")
        #expect(status.connectionReceipt?.devToolsBrowserID == "browser-a")
        #expect(manager.addedConfigs[0].args.contains(
            "--wsEndpoint=ws://127.0.0.1:9222/devtools/browser/browser-a"))

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await session.connect(
                channel: .stable,
                browserURL: "http://127.0.0.1:9333")
        }
    }

    @Test
    func `unbound endpoint identity replacement clears stale connection and preserves error`() async throws {
        let manager = MockBrowserMCPManager()
        let endpoints = EndpointMap()
        await endpoints.set("browser-a", port: 9222)
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                try await endpoints.resolve(url)
            })
        _ = try await session.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        manager.executedTools.removeAll()
        await endpoints.set("browser-b", port: 9222)

        await #expect(throws: BrowserMCPConnectionError.connectionLost(
            "the DevTools browser endpoint changed identity"))
        {
            _ = try await session.execute(toolName: "take_snapshot", arguments: [:], channel: nil)
        }
        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeCount == 1)
        #expect(!manager.connected)
        #expect(await (session.status(channel: nil)).connectionReceipt == nil)
    }

    @Test
    func `receipt bound endpoint drift refuses before tool dispatch`() async throws {
        let manager = MockBrowserMCPManager()
        let endpoints = EndpointMap()
        await endpoints.set("browser-a", port: 9222)
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                try await endpoints.resolve(url)
            })
        let status = try await session.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        let receipt = try #require(status.connectionReceipt)
        manager.executedTools.removeAll()
        await endpoints.set("browser-b", port: 9222)

        await #expect(throws: BrowserMCPConnectionError.expectedConnectionReceiptMismatch) {
            _ = try await session.executeSequence(
                [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: [:])],
                channel: nil,
                expectedConnectionReceipt: receipt)
        }
        #expect(manager.executedTools.isEmpty)
    }

    @Test
    func `receipt bound endpoint validation preserves cancellation before dispatch`() async throws {
        let manager = MockBrowserMCPManager()
        let endpoints = EndpointMap()
        await endpoints.set("browser-a", port: 9222)
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                try await endpoints.resolve(url)
            })
        let status = try await session.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        let receipt = try #require(status.connectionReceipt)
        manager.executedTools.removeAll()
        await endpoints.cancelResolution()

        do {
            _ = try await session.executeSequence(
                [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: [:])],
                channel: nil,
                expectedConnectionReceipt: receipt)
            Issue.record("Expected a typed pre-dispatch cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeCount == 1)
        #expect(!manager.connected)
        #expect(await (session.status(channel: nil)).connectionReceipt == nil)
    }

    @Test
    func `atomic browser sequence excludes a concurrent page action`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(manager: manager, browsers: [Self.browser(pid: 91, generation: 6091)])
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        let barrier = SequenceBarrier()
        manager.executeHandler = { toolName, _ in
            if toolName == "click" {
                await barrier.block()
            }
            return ToolResponse.text("ok")
        }

        let sequence = Task { @MainActor in
            try await session.executeSequence([
                BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "91_1"]),
                BrowserMCPMappedCall(toolName: "type_text", arguments: ["text": "value"]),
            ], channel: nil)
        }
        await barrier.waitUntilBlocked()
        let contender = Task { @MainActor in
            try await session.execute(toolName: "hover", arguments: ["uid": "91_2"], channel: nil)
        }
        await Task.yield()
        await Task.yield()
        #expect(manager.executedTools == ["click"])

        await barrier.release()
        _ = try await sequence.value
        _ = try await contender.value
        #expect(manager.executedTools == ["click", "type_text", "hover"])
    }

    @Test
    func `second tool error returns exact completed indeterminate progress`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        let receipt = try #require(try await (session.connect(channel: .stable)).connectionReceipt)
        manager.executedTools.removeAll()
        manager.executeHandler = { toolName, _ in
            toolName == "type_text" ? .error("fixture rejected input") : .text("ok")
        }

        let result = try await session.executeSequence(
            [
                BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "92_1"]),
                BrowserMCPMappedCall(toolName: "type_text", arguments: ["text": "value"]),
                BrowserMCPMappedCall(toolName: "hover", arguments: ["uid": "92_2"]),
            ],
            channel: nil,
            expectedConnectionReceipt: receipt)

        #expect(manager.executedTools == ["click", "type_text"])
        #expect(result.completedCallCount == 2)
        #expect(result.dispatchedCallCount == 2)
        #expect(result.actionFailure?.outcome.state == .indeterminate)
        #expect(result.actionFailure?.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(result.actionFailure?.outcome.retrySafety == .unsafe)
    }

    @Test
    func `second pre dispatch failure returns exact completed partial progress`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        let receipt = try #require(try await (session.connect(channel: .stable)).connectionReceipt)
        manager.executedTools.removeAll()

        let result = try await session.executeSequence(
            [
                BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "93_1"]),
                BrowserMCPMappedCall(toolName: "upload_file", arguments: ["filePath": "relative.txt"]),
            ],
            channel: nil,
            expectedConnectionReceipt: receipt)

        #expect(manager.executedTools == ["click"])
        #expect(result.completedCallCount == 1)
        #expect(result.dispatchedCallCount == 1)
        #expect(result.actionFailure?.outcome.state == .partial)
        #expect(result.actionFailure?.outcome.dispatchState.unitCount == .one)
    }

    @Test
    func `second in flight failure distinguishes completed from dispatched progress`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        let receipt = try #require(try await (session.connect(channel: .stable)).connectionReceipt)
        manager.executedTools.removeAll()
        manager.executeHandler = { toolName, _ in
            if toolName == "type_text" {
                throw MockBrowserError.probe
            }
            return .text("ok")
        }

        let result = try await session.executeSequence(
            [
                BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "94_1"]),
                BrowserMCPMappedCall(toolName: "type_text", arguments: ["text": "value"]),
            ],
            channel: nil,
            expectedConnectionReceipt: receipt)

        #expect(manager.executedTools == ["click", "type_text"])
        #expect(result.completedCallCount == 1)
        #expect(result.dispatchedCallCount == 2)
        #expect(result.actionFailure?.outcome.state == .indeterminate)
        #expect(result.actionFailure?.outcome.dispatchState.unitCount?.rawValue == 2)
    }

    @Test
    func `first pre dispatch upload failure stays typed retry safe and dispatch free`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.exactSession(manager: manager)
        let receipt = try #require(try await (session.connect(channel: .stable)).connectionReceipt)
        manager.executedTools.removeAll()

        do {
            _ = try await session.executeSequence(
                [BrowserMCPMappedCall(toolName: "upload_file", arguments: ["filePath": "relative.txt"])],
                channel: .stable,
                expectedConnectionReceipt: receipt)
            Issue.record("Expected a typed pre-dispatch upload refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .invalidRequest)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(manager.executedTools.isEmpty)
        #expect(manager.connected)
        #expect(await (session.status(channel: .stable)).isConnected)
    }

    @Test
    func `connection advertises exact private TMPDIR and retains successful upload until disconnect`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write(name: "browser receipt.txt", contents: Data("receipt-value".utf8))
        let manager = MockBrowserMCPManager()
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 101, generation: 7101)],
            uploadStager: fixture.stager())
        var stagedPath: String?
        manager.executeHandler = { toolName, arguments in
            guard toolName == "upload_file" else { return ToolResponse.text("ok") }
            let path = try #require(arguments["filePath"] as? String)
            stagedPath = path
            #expect(URL(fileURLWithPath: path).lastPathComponent == "browser receipt.txt")
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("receipt-value".utf8))
            return ToolResponse.text("uploaded")
        }

        _ = try await session.connect(channel: .stable)
        let advertisedRoot = try #require(manager.addedConfigs.first?.env["TMPDIR"])
        #expect(URL(fileURLWithPath: advertisedRoot).deletingLastPathComponent().path ==
            Self.canonicalPath(fixture.stagingParent.path))
        #expect(manager.addedConfigs.first?.args.contains("--allowUnrestrictedPaths") == false)
        manager.executedTools.removeAll()
        manager.executedArguments.removeAll()

        let response = try await session.execute(
            toolName: "upload_file",
            arguments: ["uid": "101_1", "filePath": source.path],
            channel: .stable)

        #expect(!response.isError)
        #expect(manager.executedTools == ["upload_file"])
        let actualStagedPath = try #require(stagedPath)
        #expect(actualStagedPath.hasPrefix(advertisedRoot + "/upload."))
        #expect(FileManager.default.fileExists(atPath: actualStagedPath))
        #expect(FileManager.default.fileExists(atPath: advertisedRoot))
        await session.disconnect()
        #expect(!FileManager.default.fileExists(atPath: advertisedRoot))
    }

    @Test
    func `invalid upload path is never dispatched and does not discard healthy browser session`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let manager = MockBrowserMCPManager()
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 111, generation: 8111)],
            uploadStager: fixture.stager())
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        let removalsBefore = manager.removeCount

        await #expect(throws: BrowserMCPUploadStagingError.self) {
            _ = try await session.execute(
                toolName: "upload_file",
                arguments: ["uid": "111_1", "filePath": "relative.txt"],
                channel: .stable)
        }

        #expect(manager.executedTools.isEmpty)
        #expect(manager.connected)
        #expect(manager.removeCount == removalsBefore)
        #expect(await (session.status(channel: .stable)).isConnected)
    }

    @Test
    func `upload tool error retains dispatched transfer in exact browser workspace`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write(name: "failure.txt", contents: Data("failure".utf8))
        let manager = MockBrowserMCPManager()
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 121, generation: 9121)],
            uploadStager: fixture.stager())
        var stagedPath: String?
        manager.executeHandler = { toolName, arguments in
            guard toolName == "upload_file" else { return ToolResponse.text("ok") }
            stagedPath = arguments["filePath"] as? String
            return ToolResponse.error("fixture rejected upload")
        }
        _ = try await session.connect(channel: .stable)
        let advertisedRoot = try #require(manager.addedConfigs.first?.env["TMPDIR"])

        let response = try await session.execute(
            toolName: "upload_file",
            arguments: ["uid": "121_1", "filePath": source.path],
            channel: .stable)

        #expect(response.isError)
        guard case let .text(text, _, _) = response.content.first else {
            Issue.record("Expected the MCP tool error response to remain unchanged")
            return
        }
        #expect(text == "fixture rejected upload")
        #expect(try FileManager.default.fileExists(atPath: #require(stagedPath)))
        #expect(FileManager.default.fileExists(atPath: advertisedRoot))
        #expect(manager.connected)
    }

    @Test
    func `caller cancellation removes staged bytes before noncooperative upload returns`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write(name: "cancel.txt", contents: Data("cancel".utf8))
        let manager = MockBrowserMCPManager()
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 131, generation: 10131)],
            uploadStager: fixture.stager())
        let barrier = SequenceBarrier()
        var stagedPath: String?
        var stagedFileExistedWhenChildRemoved = false
        manager.executeHandler = { toolName, arguments in
            guard toolName == "upload_file" else { return ToolResponse.text("ok") }
            stagedPath = arguments["filePath"] as? String
            await barrier.block()
            try Task.checkCancellation()
            return ToolResponse.text("unexpected")
        }
        manager.removeHandler = {
            stagedFileExistedWhenChildRemoved = stagedPath.map {
                FileManager.default.fileExists(atPath: $0)
            } ?? false
        }
        _ = try await session.connect(channel: .stable)
        let advertisedRoot = try #require(manager.addedConfigs.first?.env["TMPDIR"])

        let upload = Task { @MainActor in
            try await session.execute(
                toolName: "upload_file",
                arguments: ["uid": "131_1", "filePath": source.path],
                channel: .stable)
        }
        await barrier.waitUntilBlocked()
        let actualStagedPath = try #require(stagedPath)
        #expect(FileManager.default.fileExists(atPath: actualStagedPath))
        upload.cancel()
        #expect(await Self.waitUntilMissing(advertisedRoot))
        #expect(stagedFileExistedWhenChildRemoved)
        #expect(!FileManager.default.fileExists(atPath: actualStagedPath))
        await barrier.release()
        do {
            _ = try await upload.value
            Issue.record("Expected an indeterminate cancellation failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
    }

    @Test
    func `lost child cleanup removes the advertised browser workspace`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let manager = MockBrowserMCPManager()
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 141, generation: 11141)],
            uploadStager: fixture.stager())
        _ = try await session.connect(channel: .stable)
        let advertisedRoot = try #require(manager.addedConfigs.first?.env["TMPDIR"])
        #expect(FileManager.default.fileExists(atPath: advertisedRoot))
        manager.connected = false

        let status = await session.status(channel: .stable)

        #expect(!status.isConnected)
        #expect(!FileManager.default.fileExists(atPath: advertisedRoot))
    }

    private static func session(
        manager: MockBrowserMCPManager,
        browsers: [DetectedBrowser],
        uploadStager: BrowserMCPUploadStager = .live) -> BrowserMCPSessionManager
    {
        let generations = Dictionary(uniqueKeysWithValues: browsers.compactMap { browser in
            browser.processStartIdentity.map { (browser.processIdentifier, $0) }
        })
        return BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { channel in
                browsers.filter { channel == nil || $0.channel == channel }
            },
            processStartIdentity: { generations[$0] },
            endpointResolver: self.endpointResolver(),
            uploadStager: uploadStager,
            environment: [:])
    }

    private static func exactSession(
        manager: MockBrowserMCPManager,
        uploadStager: BrowserMCPUploadStager = .live) -> BrowserMCPSessionManager
    {
        BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            endpointResolver: self.endpointResolver(),
            uploadStager: uploadStager,
            environment: ["PEEKABOO_BROWSER_MCP_BROWSER_URL": "http://127.0.0.1:9222"])
    }

    private static func browser(pid: Int32, generation: UInt64) -> DetectedBrowser {
        DetectedBrowser(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            processIdentifier: pid,
            processStartIdentity: generation,
            version: "151.0",
            channel: .stable)
    }

    private static func endpointResolver() -> BrowserMCPDevToolsEndpointResolver {
        BrowserMCPDevToolsEndpointResolver { url in
            guard let port = URL(string: url)?.port else {
                throw BrowserMCPConnectionError.invalidEndpoint("missing port")
            }
            return BrowserMCPDevToolsEndpoint(
                browserURL: "http://127.0.0.1:\(port)/",
                webSocketDebuggerURL: "ws://127.0.0.1:\(port)/devtools/browser/browser-a",
                browserID: "browser-a",
                browserVersion: "Chrome/151.0",
                protocolVersion: "1.3")
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &resolved) != nil else { return path }
        let bytes = resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8) ?? path
    }

    private static func waitUntilMissing(_ path: String) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while FileManager.default.fileExists(atPath: path), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !FileManager.default.fileExists(atPath: path)
    }
}

@MainActor
private final class MockBrowserMCPManager: BrowserMCPManaging {
    var connected = false
    var hasConfiguredServer = false
    var addedConfigs: [MCPServerConfig] = []
    var executedTools: [String] = []
    var executedArguments: [[String: Any]] = []
    var removeCount = 0
    var executeError: (any Error)?
    var executeHandler: (@MainActor (String, [String: Any]) async throws -> ToolResponse)?
    var isConnectedHandler: (@MainActor () async -> Bool)?
    var removeHandler: (@MainActor () async -> Void)?

    func hasServer(name _: String) -> Bool {
        self.hasConfiguredServer
    }

    func isServerConnected(name _: String) async -> Bool {
        if let isConnectedHandler {
            return await isConnectedHandler()
        }
        return self.connected
    }

    func serverToolCount(name _: String) async -> Int {
        self.connected ? 29 : 0
    }

    func addServer(name _: String, config: MCPServerConfig) async throws {
        self.addedConfigs.append(config)
        self.hasConfiguredServer = true
        self.connected = true
    }

    func removeServer(name _: String) async {
        await self.removeHandler?()
        self.removeCount += 1
        self.hasConfiguredServer = false
        self.connected = false
    }

    func executeTool(
        serverName _: String,
        toolName: String,
        arguments: [String: Any]) async throws -> ToolResponse
    {
        if let executeError {
            throw executeError
        }
        self.executedTools.append(toolName)
        self.executedArguments.append(arguments)
        if let executeHandler {
            return try await executeHandler(toolName, arguments)
        }
        return ToolResponse.text("ok")
    }
}

private enum MockBrowserError: Error {
    case probe
}

private final class GenerationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64?

    init(_ value: UInt64?) {
        self.value = value
    }

    func get() -> UInt64? {
        self.lock.withLock { self.value }
    }

    func set(_ value: UInt64?) {
        self.lock.withLock { self.value = value }
    }
}

private final class BrowserListBox: @unchecked Sendable {
    private let lock = NSLock()
    private var browsers: [DetectedBrowser]

    init(_ browsers: [DetectedBrowser]) {
        self.browsers = browsers
    }

    func get(channel: BrowserMCPChannel?) -> [DetectedBrowser] {
        self.lock.withLock {
            self.browsers.filter { channel == nil || $0.channel == channel }
        }
    }

    func set(_ browsers: [DetectedBrowser]) {
        self.lock.withLock {
            self.browsers = browsers
        }
    }
}

private actor EndpointMap {
    private var endpoints: [Int: String] = [:]
    private var shouldCancelResolution = false

    func set(_ browserID: String, port: Int) {
        self.endpoints[port] = browserID
    }

    func cancelResolution() {
        self.shouldCancelResolution = true
    }

    func resolve(_ url: String) throws -> BrowserMCPDevToolsEndpoint {
        if self.shouldCancelResolution {
            throw CancellationError()
        }
        guard let port = URL(string: url)?.port,
              let browserID = self.endpoints[port]
        else {
            throw BrowserMCPConnectionError.invalidEndpoint("unknown endpoint")
        }
        return BrowserMCPDevToolsEndpoint(
            browserURL: "http://127.0.0.1:\(port)/",
            webSocketDebuggerURL: "ws://127.0.0.1:\(port)/devtools/browser/\(browserID)",
            browserID: browserID,
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
    }
}

private actor SequenceBarrier {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        self.blocked = true
        self.blockedWaiters.forEach { $0.resume() }
        self.blockedWaiters.removeAll()
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard !self.blocked else { return }
        await withCheckedContinuation { continuation in
            self.blockedWaiters.append(continuation)
        }
    }

    func release() {
        self.released = true
        self.releaseWaiters.forEach { $0.resume() }
        self.releaseWaiters.removeAll()
    }
}
