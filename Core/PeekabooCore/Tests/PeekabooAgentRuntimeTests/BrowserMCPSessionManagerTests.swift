import Darwin
import Foundation
import MCP
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import Tachikoma
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

// swiftlint:disable file_length

@MainActor
// swiftlint:disable:next type_body_length
struct BrowserMCPSessionManagerTests {
    @Test
    func `channel connect refuses ambiguous same-channel processes before spawning MCP`() async {
        let manager = MockBrowserMCPManager()
        let browsers = [
            Self.browser(pid: 41, generation: 1041),
            Self.browser(pid: 42, generation: 1042),
        ]
        let session = Self.session(manager: manager, browsers: browsers)

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await session.connect(channel: .stable)
        }
        #expect(manager.addedConfigs.isEmpty)
        #expect(manager.executedTools.isEmpty)
    }

    @Test
    func `channel connect probes list pages and publishes process bound endpoint receipt`() async throws {
        let manager = MockBrowserMCPManager()
        let browser = Self.browser(pid: 51, generation: 2051)
        let session = Self.session(manager: manager, browsers: [browser])

        let result = try await session.connectWithOutcome(channel: .stable)
        let status = result.payload

        #expect(status.isConnected)
        #expect(status.toolCount == 29)
        #expect(status.connectionReceipt?.processIdentifier == 51)
        #expect(status.connectionReceipt?.processStartIdentity == 2051)
        #expect(status.connectionReceipt?.browserURL == "http://127.0.0.1:9222/")
        let receiptWebSocket = try #require(status.connectionReceipt?.webSocketDebuggerURL)
        #expect(receiptWebSocket == "ws://127.0.0.1:9222/devtools/browser/browser-a")
        #expect(status.connectionReceipt?.devToolsBrowserID == "browser-a")
        #expect(manager.executedTools == ["list_pages"])
        #expect(manager.addedConfigs.count == 1)
        #expect(manager.addedConfigs[0].autoReconnect == false)
        #expect(manager.addedConfigs[0].args.contains("--wsEndpoint=\(receiptWebSocket)"))
        #expect(!manager.addedConfigs[0].args.contains("--auto-connect"))
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
    func `provider child restart on the same browser target rejects the old session epoch before dispatch`()
        async throws
    {
        let provider = MockBrowserMCPManager()
        let session = Self.exactSession(manager: provider)
        let first = try await session.connect(channel: .stable)
        let firstBinding = try BrowserMCPExecutionSessionBinding(
            connectionReceipt: #require(first.connectionReceipt),
            providerSessionEpoch: #require(first.providerSessionEpoch))
        await session.disconnect()
        let second = try await session.connect(channel: .stable)
        #expect(second.connectionReceipt == first.connectionReceipt)
        #expect(second.providerSessionEpoch != first.providerSessionEpoch)
        provider.executedTools.removeAll()

        await #expect(throws: BrowserMCPConnectionError.expectedProviderSessionEpochMismatch) {
            _ = try await session.executeSequence(
                [BrowserMCPMappedCall(toolName: "list_pages", arguments: [:])],
                channel: .stable,
                expectedSessionBinding: firstBinding,
                elementPreflight: nil)
        }
        #expect(provider.executedTools.isEmpty)
    }

    @Test
    func `element preflight rejects stale document uid before mutation dispatch`() async throws {
        let provider = MockBrowserMCPManager()
        let session = Self.exactSession(manager: provider)
        let status = try await session.connect(channel: .stable)
        let binding = try BrowserMCPExecutionSessionBinding(
            connectionReceipt: #require(status.connectionReceipt),
            providerSessionEpoch: #require(status.providerSessionEpoch))
        provider.executedTools.removeAll()
        provider.executeHandler = { toolName, _ in
            toolName == "take_snapshot" ? .text("uid=22_1 button \"Current\"") : .text("clicked")
        }

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await session.executeSequence(
                [BrowserMCPMappedCall(toolName: "click", arguments: ["pageId": 7, "uid": "21_1"])],
                channel: .stable,
                expectedSessionBinding: binding,
                elementPreflight: BrowserMCPElementPreflight(
                    providerPageID: 7,
                    providerUIDs: ["21_1"]))
        }
        #expect(provider.executedTools == ["take_snapshot"])
    }

    @Test
    func `element preflight preserves verbose snapshot references`() async throws {
        let provider = MockBrowserMCPManager()
        let session = Self.exactSession(manager: provider)
        let status = try await session.connect(channel: .stable)
        let binding = try BrowserMCPExecutionSessionBinding(
            connectionReceipt: #require(status.connectionReceipt),
            providerSessionEpoch: #require(status.providerSessionEpoch))
        provider.executedTools.removeAll()
        provider.executedArguments.removeAll()
        provider.executeHandler = { toolName, arguments in
            if toolName == "take_snapshot" {
                let uid = arguments["verbose"] as? Bool == true ? "21_1" : "22_1"
                return ToolResponse(
                    content: [.text(
                        text: "uid=\(uid) generic \"Verbose only\"",
                        annotations: nil,
                        _meta: nil)],
                    structuredContent: .object([
                        "snapshot": .object([
                            "id": .string(uid),
                            "role": .string("generic"),
                            "name": .string("Verbose only"),
                        ]),
                    ]))
            }
            return .text("clicked")
        }

        let result = try await session.executeSequence(
            [BrowserMCPMappedCall(toolName: "click", arguments: ["pageId": 7, "uid": "21_1"])],
            channel: .stable,
            expectedSessionBinding: binding,
            elementPreflight: BrowserMCPElementPreflight(
                providerPageID: 7,
                providerUIDs: ["21_1"]))

        #expect(!result.response.isError)
        #expect(provider.executedTools == ["take_snapshot", "click"])
        #expect(provider.executedArguments.first?["pageId"] as? Int == 7)
        #expect(provider.executedArguments.first?["verbose"] as? Bool == true)
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
    func `authenticated session pool preserves ordering within one session`() async throws {
        let provider = MockBrowserMCPManager()
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: provider)
        }
        let session = try #require(pool.manager(for: .init()))
        _ = try await session.connect(channel: .stable)
        provider.executedTools.removeAll()
        let barrier = SequenceBarrier()
        provider.executeHandler = { _, _ in
            await barrier.block()
            return .text("ok")
        }

        let first = Task { @MainActor in
            try await session.execute(toolName: "take_snapshot", arguments: [:], channel: nil)
        }
        await barrier.waitUntilBlocked()
        let second = Task { @MainActor in
            try await session.execute(toolName: "list_pages", arguments: [:], channel: nil)
        }
        try await Task.sleep(for: .milliseconds(30))

        #expect(provider.executedTools == ["take_snapshot"])
        await barrier.release()
        _ = try await first.value
        _ = try await second.value
        #expect(provider.executedTools == ["take_snapshot", "list_pages"])
    }

    @Test
    func `independently authenticated browser sessions overlap`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider]
        var serverNames: [String] = []
        let pool = BrowserMCPAuthenticatedSessionPool { serverName in
            serverNames.append(serverName)
            return Self.exactSession(manager: providers.removeFirst())
        }
        let firstSessionID = BrowserMCPAuthenticatedSessionPool.SessionID()
        let secondSessionID = BrowserMCPAuthenticatedSessionPool.SessionID()
        let firstSession = try #require(pool.manager(for: firstSessionID))
        let secondSession = try #require(pool.manager(for: secondSessionID))
        #expect(Set(serverNames).count == 2)
        _ = try await firstSession.connect(channel: .stable)
        _ = try await secondSession.connect(channel: .stable)
        firstProvider.executedTools.removeAll()
        secondProvider.executedTools.removeAll()
        let firstBarrier = SequenceBarrier()
        let secondBarrier = SequenceBarrier()
        firstProvider.executeHandler = { _, _ in
            await firstBarrier.block()
            return .text("first")
        }
        secondProvider.executeHandler = { _, _ in
            await secondBarrier.block()
            return .text("second")
        }

        let first = Task { @MainActor in
            try await firstSession.execute(toolName: "take_snapshot", arguments: [:], channel: nil)
        }
        await firstBarrier.waitUntilBlocked()
        let second = Task { @MainActor in
            try await secondSession.execute(toolName: "list_pages", arguments: [:], channel: nil)
        }
        await secondBarrier.waitUntilBlocked()

        #expect(firstProvider.executedTools == ["take_snapshot"])
        #expect(secondProvider.executedTools == ["list_pages"])
        await firstBarrier.release()
        await secondBarrier.release()
        _ = try await first.value
        _ = try await second.value

        await pool.end(firstSessionID)
        #expect(pool.count == 1)
        #expect(firstProvider.removeCount == 1)
        #expect(secondProvider.removeCount == 0)
        #expect(pool.manager(for: firstSessionID) == nil)
        do {
            _ = try await firstSession.connect(channel: .stable)
            Issue.record("Expected ended browser session to refuse reuse")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.causeDescription?.contains("session has ended") == true)
        } catch {
            Issue.record("Expected canonical ended-session refusal, got \(error)")
        }
    }

    @Test
    func `production MCP contexts use independent browser children and teardown only their owner`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider]
        var nextPort = 9321
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            let port = nextPort
            nextPort += 1
            return Self.exactSession(
                manager: providers.removeFirst(),
                browserURL: "http://127.0.0.1:\(port)",
                browserID: "browser-\(port)")
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let services = PeekabooServices()
        let context = MCPToolContext(
            services: services,
            browser: root,
            executionPolicy: .foregroundAllowed)
        let firstServer = try await PeekabooMCPServer(toolContext: context)
        let secondServer = try await PeekabooMCPServer(toolContext: context)
        let firstBrowser = await firstServer.browserClientForTesting()
        let secondBrowser = await secondServer.browserClientForTesting()
        let firstClient = try #require(firstBrowser as? BrowserMCPService)
        let secondClient = try #require(secondBrowser as? BrowserMCPService)
        _ = try await firstClient.connect(channel: nil, browserURL: nil)
        _ = try await secondClient.connect(channel: nil, browserURL: nil)
        firstProvider.executedTools.removeAll()
        secondProvider.executedTools.removeAll()
        let firstBarrier = SequenceBarrier()
        let secondBarrier = SequenceBarrier()
        firstProvider.executeHandler = { _, _ in
            await firstBarrier.block()
            return .text("first")
        }
        secondProvider.executeHandler = { _, _ in
            await secondBarrier.block()
            return .text("second")
        }

        let first = Task { @MainActor in
            try await firstClient.execute(toolName: "take_snapshot", arguments: [:], channel: nil)
        }
        await firstBarrier.waitUntilBlocked()
        let second = Task { @MainActor in
            try await secondClient.execute(toolName: "list_pages", arguments: [:], channel: nil)
        }
        await secondBarrier.waitUntilBlocked()
        #expect(firstProvider.executedTools == ["take_snapshot"])
        #expect(secondProvider.executedTools == ["list_pages"])
        await firstBarrier.release()
        await secondBarrier.release()
        _ = try await first.value
        _ = try await second.value

        await firstServer.stopForTesting()
        #expect(firstProvider.removeCount == 1)
        #expect(secondProvider.removeCount == 0)
        #expect(pool.count == 1)
        await secondServer.stopForTesting()
        #expect(secondProvider.removeCount == 1)
        #expect(pool.isEmpty)
    }

    @Test
    func `unowned browser service context ends its capability namespace on release`() async throws {
        let provider = MockBrowserMCPManager()
        let manager = Self.exactSession(manager: provider)
        let service = BrowserMCPService(sessionManager: manager)
        let context = MCPToolContext(
            services: Self.services(browser: service),
            executionPolicy: .foregroundAllowed)
            .replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        provider.executeHandler = { _, _ in Self.providerPageResponse(id: 7) }
        _ = try await service.connect(channel: nil, browserURL: nil)
        let listed = try await context.execute(
            tool: BrowserTool(context: context),
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        _ = try Self.opaquePageReference(from: listed)
        let dispatchCount = provider.executedTools.count

        await context.releaseSnapshotOwner()
        let afterRelease = try await context.execute(
            tool: BrowserTool(context: context),
            arguments: ToolArguments(raw: ["action": "list_pages"]))

        #expect(afterRelease.isError)
        #expect(provider.executedTools.count == dispatchCount)
    }

    @Test
    func `unowned browser release drains outer mutation completion before owner removal`() async throws {
        let provider = MockBrowserMCPManager()
        let manager = Self.exactSession(manager: provider)
        let service = BrowserMCPService(sessionManager: manager)
        let completionBarrier = SequenceBarrier()
        let context = MCPToolContext(
            services: Self.services(browser: service),
            snapshotMutationCoordinator: BlockingBrowserCompletionCoordinator(barrier: completionBarrier),
            executionPolicy: .foregroundAllowed)
            .replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        let ownerSnapshot = await context.uiSnapshots.createSnapshot(id: "unowned-completion")
        provider.executeHandler = { _, _ in Self.providerPageResponse(id: 7) }

        let connect = Task { @MainActor in
            try await context.execute(
                tool: BrowserTool(context: context),
                arguments: ToolArguments(raw: ["action": "connect"]))
        }
        await completionBarrier.waitUntilBlocked()
        let release = Task { await context.releaseSnapshotOwner() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await context.uiSnapshots.getSnapshot(id: ownerSnapshot.id) === ownerSnapshot)

        await completionBarrier.release()
        _ = try await connect.value
        _ = await release.value
        #expect(await context.uiSnapshots.getSnapshot(id: ownerSnapshot.id) == nil)
    }

    @Test
    func `MCP teardown retries retained cleanup debt and releases the exact target`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: providers.removeFirst())
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let base = MCPToolContext(
            services: Self.services(browser: root),
            executionPolicy: .foregroundAllowed)
        let firstContext = try base
            .scopingBrowserSession(named: "mcp:\(UUID().uuidString.lowercased())")
            .replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        let first = try #require(firstContext.browser as? BrowserMCPService)
        _ = try await first.connect(channel: nil, browserURL: nil)
        firstProvider.removeLeavesProvider = [true, false]

        #expect(await firstContext.releaseSnapshotOwner())
        #expect(firstProvider.removeCount == 2)
        #expect(root.pendingAuthenticatedSessionCleanupCount == 0)

        let secondContext = try base
            .scopingBrowserSession(named: "mcp:\(UUID().uuidString.lowercased())")
            .replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        let second = try #require(secondContext.browser as? BrowserMCPService)
        _ = try await second.connect(channel: nil, browserURL: nil)
        #expect(secondProvider.addedConfigs.count == 1)
        #expect(await secondContext.releaseSnapshotOwner())
    }

    @Test
    func `cleanup debt stays bounded and session creation fails closed at capacity`() async throws {
        var providers: [MockBrowserMCPManager] = []
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            let provider = MockBrowserMCPManager()
            provider.hasConfiguredServer = true
            provider.connected = true
            provider.removeLeavesProvider = [true, false]
            providers.append(provider)
            return Self.exactSession(manager: provider)
        }
        for _ in 0..<BrowserMCPAuthenticatedSessionPool.sessionCapacity {
            let sessionID = BrowserMCPAuthenticatedSessionPool.SessionID()
            _ = try #require(pool.manager(for: sessionID))
            #expect(await !pool.endAndConfirm(sessionID))
        }
        #expect(pool.pendingCleanupCount == BrowserMCPAuthenticatedSessionPool.sessionCapacity)

        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let context = MCPToolContext(
            services: Self.services(browser: root),
            executionPolicy: .foregroundAllowed)
        await #expect(throws: BrowserMCPConnectionError.authenticatedSessionCapacityExceeded) {
            _ = try await context.openingBrowserSession(named: "mcp:over-capacity")
        }
        let agent = try PeekabooAgentService(services: Self.services(browser: root))
        await #expect(throws: BrowserMCPConnectionError.authenticatedSessionCapacityExceeded) {
            _ = try await agent.browserClient(forAgentSessionID: "over-capacity")
        }

        #expect(await root.retryPendingAuthenticatedSessionCleanup())
        #expect(pool.pendingCleanupCount == 0)
        #expect(providers.allSatisfy { $0.removeCount == 2 })
        _ = try root.createAuthenticatedSession(named: "after-drain")
    }

    @Test
    func `unsupported local handoff does not consume authenticated session capacity`() async throws {
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: MockBrowserMCPManager())
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let context = MCPToolContext(
            services: Self.services(browser: root),
            executionPolicy: .foregroundAllowed)

        await #expect(throws: BrowserMCPConnectionError.receiptBindingUnsupported) {
            _ = try await context.openingBrowserSession(
                named: "mcp:unsupported-local-handoff",
                handoff: BrowserMCPHandoffGrant(payload: Data("unsupported".utf8)))
        }

        #expect(pool.isEmpty)
        #expect(pool.pendingCleanupCount == 0)
    }

    @Test
    func `concurrent cleanup drains join one provider retry`() async throws {
        let provider = MockBrowserMCPManager()
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: provider)
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let child = try root.createAuthenticatedSession(named: "agent:coalesced-cleanup")
        _ = try await child.connect(channel: nil, browserURL: nil)
        provider.removeLeavesProvider = [true]
        #expect(await !child.endAuthenticatedBrowserSession())
        #expect(pool.pendingCleanupCount == 1)

        let removalBarrier = SequenceBarrier()
        provider.removeHandler = { await removalBarrier.block() }
        let first = Task { @MainActor in await root.retryPendingAuthenticatedSessionCleanup() }
        await removalBarrier.waitUntilBlocked()
        let secondFinished = CompletionFlag()
        let second = Task { @MainActor in
            let result = await root.retryPendingAuthenticatedSessionCleanup()
            await secondFinished.markFinished()
            return result
        }
        await Task.yield()
        #expect(await !secondFinished.finished)

        await removalBarrier.release()
        #expect(await first.value)
        #expect(await second.value)
        #expect(provider.removeCount == 2)
        #expect(pool.pendingCleanupCount == 0)
    }

    @Test
    func `production MCP contexts overlap source proven browser mutations on distinct gates`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider]
        var nextPort = 9421
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            let port = nextPort
            nextPort += 1
            return Self.exactSession(
                manager: providers.removeFirst(),
                browserURL: "http://127.0.0.1:\(port)",
                browserID: "browser-\(port)")
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let coordinator = BrowserLaneMutationCoordinator()
        let base = MCPToolContext(
            services: Self.services(browser: root),
            snapshotMutationCoordinator: coordinator,
            executionPolicy: .foregroundAllowed)
        let firstContext = try base
            .scopingBrowserSession(named: "mcp:first")
            .replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        let secondContext = try base
            .scopingBrowserSession(named: "mcp:second")
            .replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        let firstClient = try #require(firstContext.browser as? BrowserMCPService)
        let secondClient = try #require(secondContext.browser as? BrowserMCPService)
        firstProvider.executeHandler = { _, _ in Self.providerPageResponse(id: 7) }
        secondProvider.executeHandler = { _, _ in Self.providerPageResponse(id: 8) }
        _ = try await firstClient.connect(channel: nil, browserURL: nil)
        _ = try await secondClient.connect(channel: nil, browserURL: nil)
        let firstList = try await firstContext.execute(
            tool: BrowserTool(context: firstContext),
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let secondList = try await secondContext.execute(
            tool: BrowserTool(context: secondContext),
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let firstPage = try Self.opaquePageReference(from: firstList)
        let secondPage = try Self.opaquePageReference(from: secondList)
        firstProvider.executedTools.removeAll()
        secondProvider.executedTools.removeAll()
        let sharedPrepareBaseline = coordinator.sharedPrepareCount
        #expect(sharedPrepareBaseline == 2)
        let firstBarrier = SequenceBarrier()
        let secondBarrier = SequenceBarrier()
        firstProvider.executeHandler = { toolName, _ in
            if toolName == "performance_start_trace" {
                await firstBarrier.block()
            }
            return Self.providerPageResponse(id: 7)
        }
        secondProvider.executeHandler = { toolName, _ in
            if toolName == "performance_start_trace" {
                await secondBarrier.block()
            }
            return Self.providerPageResponse(id: 8)
        }

        let firstMutation = Task { @MainActor in
            try await firstContext.execute(
                tool: BrowserTool(context: firstContext),
                arguments: ToolArguments(raw: [
                    "action": "performance_trace",
                    "page_id": firstPage,
                    "trace_action": "start",
                ]))
        }
        await firstBarrier.waitUntilBlocked()
        let secondMutation = Task { @MainActor in
            try await secondContext.execute(
                tool: BrowserTool(context: secondContext),
                arguments: ToolArguments(raw: [
                    "action": "performance_trace",
                    "page_id": secondPage,
                    "trace_action": "start",
                ]))
        }
        await secondBarrier.waitUntilBlocked()
        #expect(secondProvider.executedTools == ["performance_start_trace"])
        #expect(coordinator.sharedPrepareCount == sharedPrepareBaseline)
        #expect(coordinator.maximumConcurrentCount == 2)

        await secondBarrier.release()
        await firstBarrier.release()
        _ = try await firstMutation.value
        _ = try await secondMutation.value
        await firstContext.releaseSnapshotOwner()
        await secondContext.releaseSnapshotOwner()
    }

    @Test
    func `browser mutation read lease excludes desktop mutation after authorization`() async throws {
        let provider = MockBrowserMCPManager()
        let pool = BrowserMCPAuthenticatedSessionPool { _ in Self.exactSession(manager: provider) }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let context = try MCPToolContext(
            services: Self.services(browser: root),
            executionPolicy: .unrestricted)
            .scopingBrowserSession(named: "mcp:desktop-exclusion")
            .replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        let client = try #require(context.browser as? BrowserMCPService)
        provider.executeHandler = { _, _ in Self.providerPageResponse(id: 7) }
        _ = try await client.connect(channel: nil, browserURL: nil)
        let page = try await Self.opaquePageReference(from: context.execute(
            tool: BrowserTool(context: context),
            arguments: ToolArguments(raw: ["action": "list_pages"])))
        let browserBarrier = SequenceBarrier()
        provider.executeHandler = { toolName, _ in
            if toolName == "navigate_page" {
                await browserBarrier.block()
            }
            return Self.providerPageResponse(id: 7)
        }

        let browserMutation = Task { @MainActor in
            try await context.execute(
                tool: BrowserTool(context: context),
                arguments: ToolArguments(raw: [
                    "action": "navigate",
                    "page_id": page,
                    "url": "https://reader.example/",
                ]))
        }
        await browserBarrier.waitUntilBlocked()
        let desktopBarrier = SequenceBarrier()
        let desktopEntries = ResolutionCounter()
        let desktopMutation = Task { @MainActor in
            try await context.execute(
                tool: BrowserLaneDesktopMutationTool(
                    entries: desktopEntries,
                    barrier: desktopBarrier),
                arguments: ToolArguments(raw: [:]))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await desktopEntries.value == 0)

        await browserBarrier.release()
        _ = try await browserMutation.value
        await desktopBarrier.waitUntilBlocked()
        #expect(await desktopEntries.value == 1)
        await desktopBarrier.release()
        _ = try await desktopMutation.value
        await context.releaseSnapshotOwner()
    }

    @Test
    func `production MCP context keeps same session browser mutations FIFO`() async throws {
        let provider = MockBrowserMCPManager()
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: provider)
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let base = MCPToolContext(
            services: Self.services(browser: root),
            executionPolicy: .foregroundAllowed)
        let context = try base
            .scopingBrowserSession(named: "mcp:one")
            .replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        let client = try #require(context.browser as? BrowserMCPService)
        provider.executeHandler = { _, _ in Self.providerPageResponse(id: 7) }
        _ = try await client.connect(channel: nil, browserURL: nil)
        let listed = try await context.execute(
            tool: BrowserTool(context: context),
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let page = try Self.opaquePageReference(from: listed)
        provider.executedTools.removeAll()
        let firstBarrier = SequenceBarrier()
        var invocation = 0
        provider.executeHandler = { toolName, _ in
            if toolName == "navigate_page" {
                invocation += 1
                if invocation == 1 {
                    await firstBarrier.block()
                }
            }
            return Self.providerPageResponse(id: 7)
        }

        let first = Task { @MainActor in
            try await context.execute(
                tool: BrowserTool(context: context),
                arguments: ToolArguments(raw: [
                    "action": "navigate",
                    "page_id": page,
                    "url": "https://first.example/",
                ]))
        }
        await firstBarrier.waitUntilBlocked()
        let second = Task { @MainActor in
            try await context.execute(
                tool: BrowserTool(context: context),
                arguments: ToolArguments(raw: [
                    "action": "navigate",
                    "page_id": page,
                    "url": "https://second.example/",
                ]))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(provider.executedTools == ["navigate_page"])

        await firstBarrier.release()
        _ = try await first.value
        _ = try await second.value
        #expect(provider.executedTools == ["navigate_page", "navigate_page"])
        await context.releaseSnapshotOwner()
    }

    @Test
    func `failed browser invalidation debt blocks another session until shared recovery succeeds`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider]
        var nextPort = 9521
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            let port = nextPort
            nextPort += 1
            return Self.exactSession(
                manager: providers.removeFirst(),
                browserURL: "http://127.0.0.1:\(port)",
                browserID: "browser-\(port)")
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let coordinator = BrowserInvalidationDebtCoordinator()
        let base = MCPToolContext(
            services: Self.services(browser: root),
            snapshotMutationCoordinator: coordinator,
            executionPolicy: .foregroundAllowed)
        let firstContext = try base
            .scopingBrowserSession(named: "mcp:debt-first")
            .replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        let secondContext = try base
            .scopingBrowserSession(named: "mcp:debt-second")
            .replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        let firstClient = try #require(firstContext.browser as? BrowserMCPService)
        let secondClient = try #require(secondContext.browser as? BrowserMCPService)
        firstProvider.executeHandler = { _, _ in Self.providerPageResponse(id: 7) }
        secondProvider.executeHandler = { _, _ in Self.providerPageResponse(id: 8) }
        _ = try await firstClient.connect(channel: nil, browserURL: nil)
        _ = try await secondClient.connect(channel: nil, browserURL: nil)
        let firstPage = try await Self.opaquePageReference(from: firstContext.execute(
            tool: BrowserTool(context: firstContext),
            arguments: ToolArguments(raw: ["action": "list_pages"])))
        let secondPage = try await Self.opaquePageReference(from: secondContext.execute(
            tool: BrowserTool(context: secondContext),
            arguments: ToolArguments(raw: ["action": "list_pages"])))
        firstProvider.executedTools.removeAll()
        secondProvider.executedTools.removeAll()
        let setupCompletionAttempts = coordinator.completionAttempts
        #expect(setupCompletionAttempts == 2)
        coordinator.completionAllowed = false

        let firstResult = try await firstContext.execute(
            tool: BrowserTool(context: firstContext),
            arguments: ToolArguments(raw: [
                "action": "navigate",
                "page_id": firstPage,
                "url": "https://first.example/",
            ]))
        #expect(!firstResult.isError)
        #expect(firstProvider.executedTools == ["navigate_page"])

        let blocked = try await secondContext.execute(
            tool: BrowserTool(context: secondContext),
            arguments: ToolArguments(raw: [
                "action": "navigate",
                "page_id": secondPage,
                "url": "https://second.example/",
            ]))
        #expect(blocked.isError)
        #expect(secondProvider.executedTools.isEmpty)
        #expect(coordinator.completionAttempts == setupCompletionAttempts + 2)

        coordinator.completionAllowed = true
        let recovered = try await secondContext.execute(
            tool: BrowserTool(context: secondContext),
            arguments: ToolArguments(raw: [
                "action": "navigate",
                "page_id": secondPage,
                "url": "https://second.example/",
            ]))
        #expect(!recovered.isError)
        #expect(secondProvider.executedTools == ["navigate_page"])
        #expect(coordinator.completionAttempts == setupCompletionAttempts + 4)

        await firstContext.releaseSnapshotOwner()
        await secondContext.releaseSnapshotOwner()
    }

    @Test
    func `duplicate session teardown callers join mutation completion before removing owner`() async throws {
        let provider = MockBrowserMCPManager()
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: provider)
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let completionBarrier = SequenceBarrier()
        let coordinator = BlockingBrowserCompletionCoordinator(
            barrier: completionBarrier,
            initiallyArmed: false)
        let context = try MCPToolContext(
            services: Self.services(browser: root),
            snapshotMutationCoordinator: coordinator,
            executionPolicy: .foregroundAllowed)
            .scopingBrowserSession(named: "mcp:teardown")
            .replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        let client = try #require(context.browser as? BrowserMCPService)
        provider.executeHandler = { _, _ in Self.providerPageResponse(id: 7) }
        _ = try await client.connect(channel: nil, browserURL: nil)
        let page = try await Self.opaquePageReference(from: context.execute(
            tool: BrowserTool(context: context),
            arguments: ToolArguments(raw: ["action": "list_pages"])))
        let ownerSnapshot = await context.uiSnapshots.createSnapshot(id: "teardown-owner")
        provider.executedTools.removeAll()
        coordinator.arm()

        let mutation = Task { @MainActor in
            try await context.execute(
                tool: BrowserTool(context: context),
                arguments: ToolArguments(raw: [
                    "action": "navigate",
                    "page_id": page,
                    "url": "https://teardown.example/",
                ]))
        }
        await completionBarrier.waitUntilBlocked()
        let firstRelease = Task { @MainActor in await context.releaseSnapshotOwner() }
        let secondRelease = Task { @MainActor in await context.releaseSnapshotOwner() }
        try await Task.sleep(for: .milliseconds(30))

        #expect(provider.removeCount == 0)
        #expect(await context.uiSnapshots.getSnapshot(id: ownerSnapshot.id) === ownerSnapshot)

        await completionBarrier.release()
        _ = try await mutation.value
        _ = await firstRelease.value
        _ = await secondRelease.value
        #expect(provider.removeCount == 1)
        #expect(await context.uiSnapshots.getSnapshot(id: ownerSnapshot.id) == nil)
    }

    @Test
    func `session teardown drains desktop mutation before removing owner`() async throws {
        let root = BrowserMCPService(authenticatedSessionPool: BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: MockBrowserMCPManager())
        })
        let context = try MCPToolContext(
            services: Self.services(browser: root),
            executionPolicy: .unrestricted)
            .scopingBrowserSession(named: "mcp:desktop-teardown")
            .replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        let ownerSnapshot = await context.uiSnapshots.createSnapshot(id: "desktop-teardown-owner")
        let mutationBarrier = SequenceBarrier()
        let entries = ResolutionCounter()
        let mutation = Task { @MainActor in
            try await context.execute(
                tool: BrowserLaneDesktopMutationTool(entries: entries, barrier: mutationBarrier),
                arguments: ToolArguments(raw: [:]))
        }
        await mutationBarrier.waitUntilBlocked()
        let releaseFinished = CompletionFlag()
        let release = Task { @MainActor in
            await context.releaseSnapshotOwner()
            await releaseFinished.markFinished()
        }
        try await Task.sleep(for: .milliseconds(30))

        #expect(await !releaseFinished.finished)
        #expect(await context.uiSnapshots.getSnapshot(id: ownerSnapshot.id) === ownerSnapshot)

        await mutationBarrier.release()
        _ = try await mutation.value
        _ = await release.value
        #expect(await !context.uiSnapshots.hasOwnerState())
    }

    @Test
    func `session teardown releases its lifecycle gate before ending the provider session`() async {
        let lifecycleGate = MCPToolSnapshotExecutionGate()
        let browser = LifecycleGateProbingBrowserClient(gate: lifecycleGate)
        let context = MCPToolContext(
            services: Self.services(browser: browser),
            snapshotExecutionGate: MCPToolSnapshotExecutionGate(),
            browserMutationExecutionGate: lifecycleGate,
            snapshotOwner: MCPToolSnapshotOwner(),
            executionPolicy: .unrestricted)

        await context.releaseSnapshotOwner()

        #expect(browser.acquiredLifecycleGate)
    }

    @Test
    func `foreground browser completion retains session lifecycle gate through teardown`() async throws {
        let provider = MockBrowserMCPManager()
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: provider)
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let completionBarrier = SequenceBarrier()
        let context = try MCPToolContext(
            services: Self.services(browser: root),
            snapshotMutationCoordinator: BlockingBrowserCompletionCoordinator(barrier: completionBarrier),
            executionPolicy: .foregroundAllowed)
            .scopingBrowserSession(named: "mcp:foreground-teardown")
            .replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        provider.executeHandler = { _, _ in Self.providerPageResponse(id: 7) }

        let connect = Task { @MainActor in
            try await context.execute(
                tool: BrowserTool(context: context),
                arguments: ToolArguments(raw: ["action": "connect"]))
        }
        await completionBarrier.waitUntilBlocked()
        let release = Task { @MainActor in await context.releaseSnapshotOwner() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(provider.removeCount == 0)

        await completionBarrier.release()
        _ = try await connect.value
        _ = await release.value
        #expect(provider.removeCount == 1)
    }

    @Test
    func `authenticated sessions cannot concurrently own the same exact browser target`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: providers.removeFirst())
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:first"))
        let second = try #require(root.authenticatedSession(named: "agent:second"))
        _ = try await first.connect(channel: nil, browserURL: nil)

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await second.connect(channel: nil, browserURL: nil)
        }
        #expect(firstProvider.removeCount == 0)
        #expect(secondProvider.addedConfigs.isEmpty)
        #expect(secondProvider.executedTools.isEmpty)
        #expect(secondProvider.removeCount == 0)
        await root.endAuthenticatedSession(named: "agent:first")
        await root.endAuthenticatedSession(named: "agent:second")
    }

    @Test
    func `same target reservation precedes concurrent provider connection and probe`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: providers.removeFirst())
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:first"))
        let second = try #require(root.authenticatedSession(named: "agent:second"))
        let firstProbe = SequenceBarrier()
        firstProvider.executeHandler = { toolName, _ in
            if toolName == "list_pages" {
                await firstProbe.block()
            }
            return .text("ok")
        }

        let firstConnection = Task { @MainActor in
            try await first.connect(channel: nil, browserURL: nil)
        }
        await firstProbe.waitUntilBlocked()
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await second.connect(channel: nil, browserURL: nil)
        }
        #expect(secondProvider.addedConfigs.isEmpty)
        #expect(secondProvider.executedTools.isEmpty)
        #expect(secondProvider.removeCount == 0)

        await firstProbe.release()
        _ = try await firstConnection.value
        await root.endAuthenticatedSession(named: "agent:first")
        await root.endAuthenticatedSession(named: "agent:second")
    }

    @Test
    func `older disconnect cannot release a newer connection reservation`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: providers.removeFirst())
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:first"))
        let second = try #require(root.authenticatedSession(named: "agent:second"))
        _ = try await first.connect(channel: nil, browserURL: nil)

        let teardownBarrier = SequenceBarrier()
        firstProvider.removeHandler = { await teardownBarrier.block() }
        let reconnectProbe = SequenceBarrier()
        firstProvider.executeHandler = { toolName, _ in
            if toolName == "list_pages" {
                await reconnectProbe.block()
            }
            return .text("ok")
        }
        let disconnectCompletion = CompletionFlag()
        let disconnect = Task { @MainActor in
            await first.disconnect()
            await disconnectCompletion.markFinished()
        }
        await teardownBarrier.waitUntilBlocked()
        let reconnect = Task { @MainActor in
            try await first.connect(channel: nil, browserURL: nil)
        }

        await teardownBarrier.release()
        await reconnectProbe.waitUntilBlocked()
        let completionDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await !disconnectCompletion.finished, ContinuousClock.now < completionDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await disconnectCompletion.finished)
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await second.connect(channel: nil, browserURL: nil)
        }
        #expect(secondProvider.addedConfigs.isEmpty)

        await reconnectProbe.release()
        _ = try await reconnect.value
        await disconnect.value
        await root.endAuthenticatedSession(named: "agent:first")
        await root.endAuthenticatedSession(named: "agent:second")
    }

    @Test
    func `older root disconnect cannot release a newer root connection reservation`() async throws {
        let rootProvider = MockBrowserMCPManager()
        let scopedProvider = MockBrowserMCPManager()
        let rootManager = Self.exactSession(manager: rootProvider)
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: scopedProvider)
        }
        let scopedSessionID = BrowserMCPAuthenticatedSessionPool.SessionID()
        let scopedManager = try #require(pool.manager(for: scopedSessionID))
        _ = try await rootManager.connectWithOutcome(
            channel: nil,
            reserveTarget: { try pool.bindRoot(to: $0) })

        let teardownBarrier = SequenceBarrier()
        rootProvider.removeHandler = { await teardownBarrier.block() }
        let reconnectProbe = SequenceBarrier()
        rootProvider.executeHandler = { toolName, _ in
            if toolName == "list_pages" {
                await reconnectProbe.block()
            }
            return .text("ok")
        }
        let disconnectCompletion = CompletionFlag()
        let disconnect = Task { @MainActor in
            await rootManager.disconnect(releaseTarget: { pool.unbindRoot() })
            await disconnectCompletion.markFinished()
        }
        await teardownBarrier.waitUntilBlocked()
        let reconnect = Task { @MainActor in
            try await rootManager.connectWithOutcome(
                channel: nil,
                reserveTarget: { try pool.bindRoot(to: $0) })
        }

        await teardownBarrier.release()
        await reconnectProbe.waitUntilBlocked()
        let completionDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await !disconnectCompletion.finished, ContinuousClock.now < completionDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await disconnectCompletion.finished)
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await scopedManager.connectWithOutcome(
                channel: nil,
                reserveTarget: { try pool.bind(scopedSessionID, to: $0) })
        }
        #expect(scopedProvider.addedConfigs.isEmpty)

        await reconnectProbe.release()
        _ = try await reconnect.value
        await disconnect.value
        await rootManager.disconnect(releaseTarget: { pool.unbindRoot() })
        await pool.end(scopedSessionID)
    }

    @Test
    func `foreground root auto connect reserves target while scoped execution stays receipt only`() async throws {
        let rootProvider = MockBrowserMCPManager()
        let scopedProvider = MockBrowserMCPManager()
        let rootManager = Self.exactSession(manager: rootProvider)
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: scopedProvider)
        }
        let root = BrowserMCPService(
            sessionManager: rootManager,
            authenticatedSessionPool: pool)
        let scoped = try root.createAuthenticatedSession(named: "agent:scoped")

        do {
            _ = try await scoped.executeSequenceWithOutcome(
                [BrowserMCPMappedCall(toolName: "list_pages", arguments: [:])],
                channel: nil,
                connectionPolicy: .allowAutoConnect)
            Issue.record("Expected scoped execution to require an existing exact connection")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(scopedProvider.addedConfigs.isEmpty)
        #expect(scopedProvider.executedTools.isEmpty)

        let response = try await BrowserTool(
            client: root,
            executionPolicy: .foregroundAllowed,
            instructionAudience: .commandLine)
            .execute(arguments: ToolArguments(raw: ["action": "list_pages"]))

        #expect(!response.isError)
        #expect(rootProvider.addedConfigs.count == 1)
        #expect(rootProvider.executedTools == ["list_pages", "list_pages"])

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await scoped.connect(channel: nil, browserURL: nil)
        }
        #expect(scopedProvider.addedConfigs.isEmpty)

        await root.disconnect()
        _ = try await scoped.connect(channel: nil, browserURL: nil)
        #expect(scopedProvider.addedConfigs.count == 1)
        #expect(scopedProvider.executedTools == ["list_pages"])

        await root.endAuthenticatedSession(named: "agent:scoped")
    }

    @Test
    func `cancelled root implicit connect releases its pre-provider target reservation`() async throws {
        let rootProvider = MockBrowserMCPManager()
        let scopedProvider = MockBrowserMCPManager()
        let resolutionBarrier = SequenceBarrier()
        let rootManager = Self.exactSession(
            manager: rootProvider,
            endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                await resolutionBarrier.block()
                try Task.checkCancellation()
                let port = try #require(URL(string: url)?.port)
                return BrowserMCPDevToolsEndpoint(
                    browserURL: "http://127.0.0.1:\(port)/",
                    webSocketDebuggerURL: "ws://127.0.0.1:\(port)/devtools/browser/browser-a",
                    browserID: "browser-a",
                    browserVersion: "Chrome/151.0",
                    protocolVersion: "1.3")
            })
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: scopedProvider)
        }
        let root = BrowserMCPService(
            sessionManager: rootManager,
            authenticatedSessionPool: pool)
        let scoped = try root.createAuthenticatedSession(named: "agent:scoped")
        let execution = Task { @MainActor in
            try await root.executeSequenceWithOutcome(
                [BrowserMCPMappedCall(toolName: "list_pages", arguments: [:])],
                channel: nil,
                connectionPolicy: .allowAutoConnect)
        }

        await resolutionBarrier.waitUntilBlocked()
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await scoped.connect(channel: nil, browserURL: nil)
        }
        #expect(rootProvider.addedConfigs.isEmpty)
        #expect(scopedProvider.addedConfigs.isEmpty)

        execution.cancel()
        await resolutionBarrier.release()
        do {
            _ = try await execution.value
            Issue.record("Expected implicit root connection to be cancelled")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }

        _ = try await scoped.connect(channel: nil, browserURL: nil)
        #expect(scopedProvider.addedConfigs.count == 1)
        await root.endAuthenticatedSession(named: "agent:scoped")
    }

    @Test
    func `cancelled connect releases its target reservation through an uncancelled gate`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        let resolutionBarrier = SequenceBarrier()
        let firstManager = Self.exactSession(
            manager: firstProvider,
            endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                await resolutionBarrier.block()
                try Task.checkCancellation()
                let port = try #require(URL(string: url)?.port)
                return BrowserMCPDevToolsEndpoint(
                    browserURL: "http://127.0.0.1:\(port)/",
                    webSocketDebuggerURL: "ws://127.0.0.1:\(port)/devtools/browser/browser-a",
                    browserID: "browser-a",
                    browserVersion: "Chrome/151.0",
                    protocolVersion: "1.3")
            })
        let secondManager = Self.exactSession(manager: secondProvider)
        var managers = [firstManager, secondManager]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in managers.removeFirst() }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:first"))
        let second = try #require(root.authenticatedSession(named: "agent:second"))
        let connection = Task { @MainActor in
            try await first.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        }

        await resolutionBarrier.waitUntilBlocked()
        connection.cancel()
        await resolutionBarrier.release()
        do {
            _ = try await connection.value
            Issue.record("Expected the first connection to be cancelled")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        _ = try await second.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        #expect(firstProvider.addedConfigs.isEmpty)
        #expect(secondProvider.addedConfigs.count == 1)

        await root.endAuthenticatedSession(named: "agent:first")
        await root.endAuthenticatedSession(named: "agent:second")
    }

    @Test
    func `real validation loss on a cancelled status releases its target reservation`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        let validationBarrier = SequenceBarrier()
        let endpoints = EndpointMap()
        await endpoints.set("browser-a", port: 9222)
        let firstManager = Self.exactSession(
            manager: firstProvider,
            endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                try await endpoints.resolve(url)
            })
        let secondManager = Self.exactSession(manager: secondProvider)
        var managers = [firstManager, secondManager]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in managers.removeFirst() }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:first"))
        let second = try #require(root.authenticatedSession(named: "agent:second"))
        _ = try await first.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        await endpoints.failNextResolution(after: validationBarrier)

        let inspection = Task { @MainActor in
            await first.status(channel: nil)
        }
        await validationBarrier.waitUntilBlocked()
        inspection.cancel()
        await validationBarrier.release()

        let disconnected = await inspection.value
        #expect(!disconnected.isConnected)
        #expect(disconnected.connectionReceipt == nil)
        #expect(disconnected.observation == .confirmed)
        _ = try await second.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        #expect(firstProvider.removeCount == 1)
        #expect(secondProvider.addedConfigs.count == 1)

        await root.endAuthenticatedSession(named: "agent:first")
        await root.endAuthenticatedSession(named: "agent:second")
    }

    @Test
    func `second reconnect validation cancellation retains its healthy target reservation`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        let secondValidationBarrier = SequenceBarrier()
        let endpoints = EndpointMap()
        await endpoints.set("browser-a", port: 9222)
        let firstManager = Self.exactSession(
            manager: firstProvider,
            endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                try await endpoints.resolve(url)
            })
        let secondManager = Self.exactSession(manager: secondProvider)
        var managers = [firstManager, secondManager]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in managers.removeFirst() }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:first"))
        let second = try #require(root.authenticatedSession(named: "agent:second"))
        _ = try await first.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        await endpoints.cancelResolution(
            afterSuccessfulResolutions: 1,
            at: secondValidationBarrier)

        let reconnect = Task { @MainActor in
            try await first.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        }
        await secondValidationBarrier.waitUntilBlocked()
        await secondValidationBarrier.release()
        do {
            _ = try await reconnect.value
            Issue.record("Expected the second validation to cancel the reconnect")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        let retained = await first.status(channel: nil)
        #expect(retained.isConnected)
        #expect(retained.observation == .confirmed)
        #expect(firstProvider.removeCount == 0)
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await second.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        }

        await first.disconnect()
        _ = try await second.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        await root.endAuthenticatedSession(named: "agent:first")
        await root.endAuthenticatedSession(named: "agent:second")
    }

    @Test(arguments: [false, true])
    func `cancelled capability preflight retains provider target and opaque refs`(
        transportCancellation: Bool) async throws
    {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        let preflightBarrier = SequenceBarrier()
        let endpoints = EndpointMap()
        await endpoints.set("browser-a", port: 9222)
        let firstManager = Self.exactSession(
            manager: firstProvider,
            endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                try await endpoints.resolve(url)
            })
        let secondManager = Self.exactSession(manager: secondProvider)
        var managers = [firstManager, secondManager]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in managers.removeFirst() }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let base = MCPToolContext(
            services: Self.services(browser: root),
            executionPolicy: .unrestricted)
        let firstContext = try base.scopingBrowserSession(named: "mcp:first")
        let secondContext = try base.scopingBrowserSession(named: "mcp:second")
        let firstClient = try #require(firstContext.browser as? BrowserMCPService)
        let secondClient = try #require(secondContext.browser as? BrowserMCPService)
        _ = try await firstClient.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        firstProvider.executeHandler = { toolName, _ in
            switch toolName {
            case "list_pages": Self.providerPageResponse(id: 7)
            case "take_snapshot": Self.providerSnapshotResponse(id: "1_0")
            default: .text("ok")
            }
        }
        let tool = BrowserTool(context: firstContext)
        let listed = try await firstContext.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.opaquePageReference(from: listed)
        let snapshotted = try await firstContext.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try #require(
            snapshotted.structuredContent?.objectValue?["snapshot"]?.objectValue?["id"]?.stringValue)
        firstProvider.executedTools.removeAll()
        await endpoints.cancelResolution(
            afterSuccessfulResolutions: 1,
            at: preflightBarrier,
            asTransportError: transportCancellation)

        let cancelled = Task { @MainActor in
            try await firstContext.execute(
                tool: tool,
                arguments: ToolArguments(raw: [
                    "action": "click",
                    "page_id": pageReference,
                    "uid": elementReference,
                ]))
        }
        await preflightBarrier.waitUntilBlocked()
        await preflightBarrier.release()
        do {
            _ = try await cancelled.value
            Issue.record("Expected capability receipt preflight cancellation")
        } catch {
            #expect(error is CancellationError)
        }

        #expect(firstProvider.executedTools.isEmpty)
        #expect(firstProvider.removeCount == 0)
        let retainedElement = await firstContext.browserCapabilities.elementBinding(for: elementReference)
        #expect(retainedElement != nil)
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await secondClient.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        }

        let retried = try await firstContext.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "click",
                "page_id": pageReference,
                "uid": elementReference,
            ]))
        #expect(!retried.isError)
        #expect(firstProvider.executedTools == ["take_snapshot", "click"])

        await firstClient.disconnect()
        _ = try await secondClient.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        await firstContext.releaseSnapshotOwner()
        await secondContext.releaseSnapshotOwner()
    }

    @Test(arguments: [false, true])
    func `cancelled status inspection retains live target ownership`(transportCancellation: Bool) async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        let endpoints = EndpointMap()
        await endpoints.set("browser-a", port: 9222)
        let firstManager = Self.exactSession(
            manager: firstProvider,
            endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                try await endpoints.resolve(url)
            })
        let secondManager = Self.exactSession(manager: secondProvider)
        var managers = [firstManager, secondManager]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in managers.removeFirst() }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:first"))
        let second = try #require(root.authenticatedSession(named: "agent:second"))
        let connected = try await first.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        await endpoints.cancelResolution(asTransportError: transportCancellation)

        let cancelledStatus = await first.status(channel: nil)

        #expect(!cancelledStatus.isConnected)
        #expect(cancelledStatus.connectionReceipt == connected.connectionReceipt)
        #expect(cancelledStatus.providerSessionEpoch == connected.providerSessionEpoch)
        #expect(cancelledStatus.observation == .indeterminate)
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await second.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        }
        #expect(firstProvider.removeCount == 0)
        #expect(secondProvider.addedConfigs.isEmpty)

        await first.disconnect()
        await root.endAuthenticatedSession(named: "agent:first")
        await root.endAuthenticatedSession(named: "agent:second")
    }

    @Test
    func `explicit URL reservation precedes endpoint discovery and provider setup`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        let firstResolution = ResolutionCounter()
        let secondResolution = ResolutionCounter()
        let discoveryBarrier = SequenceBarrier()
        let endpoint = BrowserMCPDevToolsEndpoint(
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            browserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let firstResolver = BrowserMCPDevToolsEndpointResolver { _ in
            await firstResolution.record()
            await discoveryBarrier.block()
            return endpoint
        }
        let secondResolver = BrowserMCPDevToolsEndpointResolver { _ in
            await secondResolution.record()
            return BrowserMCPDevToolsEndpoint(
                browserURL: endpoint.browserURL,
                webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-b",
                browserID: "browser-b",
                browserVersion: endpoint.browserVersion,
                protocolVersion: endpoint.protocolVersion)
        }
        var managers = [
            Self.exactSession(manager: firstProvider, endpointResolver: firstResolver),
            Self.exactSession(manager: secondProvider, endpointResolver: secondResolver),
        ]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in managers.removeFirst() }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:url-first"))
        let second = try #require(root.authenticatedSession(named: "agent:url-second"))

        let firstConnection = Task { @MainActor in
            try await first.connect(channel: nil, browserURL: nil)
        }
        await discoveryBarrier.waitUntilBlocked()
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await second.connect(channel: .stable, browserURL: nil)
        }
        #expect(await firstResolution.value == 1)
        #expect(await secondResolution.value == 0)
        #expect(secondProvider.addedConfigs.isEmpty)

        await discoveryBarrier.release()
        _ = try await firstConnection.value
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await second.connect(channel: .stable, browserURL: nil)
        }
        #expect(await secondResolution.value == 0)
        await root.endAuthenticatedSession(named: "agent:url-first")
        await root.endAuthenticatedSession(named: "agent:url-second")
    }

    @Test
    func `native process reservation precedes permission bearing endpoint resolution`() async throws {
        let browser = Self.browser(pid: 211, generation: 10211)
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        let firstResolution = ResolutionCounter()
        let secondResolution = ResolutionCounter()
        let permissionBarrier = SequenceBarrier()
        let endpoint = BrowserMCPDevToolsEndpoint(
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            browserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let firstResolver = BrowserMCPChannelEndpointResolver(
            resolveInitial: { _, attempt in
                await firstResolution.record()
                await permissionBarrier.block()
                attempt.state.markPermissionDispatchStarted()
                return endpoint
            },
            revalidate: { _, _ in })
        let secondResolver = BrowserMCPChannelEndpointResolver(
            resolveInitial: { _, attempt in
                await secondResolution.record()
                attempt.state.markPermissionDispatchStarted()
                return endpoint
            },
            revalidate: { _, _ in })
        var providers = [firstProvider, secondProvider]
        var resolvers = [firstResolver, secondResolver]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.session(
                manager: providers.removeFirst(),
                browsers: [browser],
                channelEndpointResolver: resolvers.removeFirst())
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:first"))
        let second = try #require(root.authenticatedSession(named: "agent:second"))

        let firstConnection = Task { @MainActor in
            try await first.connect(channel: .stable, browserURL: nil)
        }
        await permissionBarrier.waitUntilBlocked()
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await second.connect(channel: .stable, browserURL: nil)
        }
        #expect(await firstResolution.value == 1)
        #expect(await secondResolution.value == 0)
        #expect(secondProvider.addedConfigs.isEmpty)

        await permissionBarrier.release()
        _ = try await firstConnection.value
        await root.endAuthenticatedSession(named: "agent:first")
        await root.endAuthenticatedSession(named: "agent:second")
    }

    @Test
    func `native identity collision refuses before probe and releases process reservation`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        let thirdProvider = MockBrowserMCPManager()
        let reservationAttempts = ResolutionCounter()
        let permissionProbes = ResolutionCounter()
        let endpoint = BrowserMCPDevToolsEndpoint(
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            browserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let secondResolver = BrowserMCPChannelEndpointResolver(
            resolveInitialWithReservation: { _, attempt, reserveAuthority in
                await reservationAttempts.record()
                try await reserveAuthority?(BrowserMCPChannelEndpointReservation(
                    browserURL: endpoint.browserURL,
                    webSocketDebuggerURL: endpoint.webSocketDebuggerURL,
                    browserID: endpoint.browserID))
                await permissionProbes.record()
                attempt.state.markPermissionDispatchStarted()
                return endpoint
            },
            revalidate: { _, _ in })
        var managers = [
            Self.exactSession(manager: firstProvider, browserID: "browser-a"),
            Self.session(
                manager: secondProvider,
                browsers: [Self.browser(pid: 222, generation: 10222)],
                channelEndpointResolver: secondResolver),
            Self.exactSession(manager: thirdProvider, browserID: "browser-c"),
        ]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in managers.removeFirst() }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:devtools-first"))
        let second = try #require(root.authenticatedSession(named: "agent:devtools-second"))
        _ = try await first.connect(channel: nil, browserURL: nil)

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await second.connect(channel: .stable, browserURL: nil)
        }
        #expect(await reservationAttempts.value == 1)
        #expect(await permissionProbes.value == 0)
        #expect(secondProvider.addedConfigs.isEmpty)

        let thirdID = try #require(pool.sessionID(named: "agent:devtools-third"))
        _ = pool.manager(for: thirdID)
        try pool.bind(thirdID, to: BrowserMCPConnectionReceipt(
            channel: .stable,
            processIdentifier: 222,
            processStartIdentity: 10222,
            bundleIdentifier: ChromeChannelIdentity.stable.bundleIdentifier))

        await root.endAuthenticatedSession(named: "agent:devtools-first")
        await root.endAuthenticatedSession(named: "agent:devtools-second")
        await pool.end(thirdID)
    }

    @Test
    func `pooled execution cannot implicitly connect around another target owner`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: providers.removeFirst())
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:first"))
        let second = try #require(root.authenticatedSession(named: "agent:second"))
        _ = try await first.connect(channel: nil, browserURL: nil)

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await second.executeSequenceWithOutcome(
                [BrowserMCPMappedCall(toolName: "click", arguments: [
                    "uid": "1_0",
                    "pageId": 7,
                ])],
                channel: nil,
                connectionPolicy: .allowAutoConnect)
        }
        #expect(secondProvider.addedConfigs.isEmpty)
        #expect(secondProvider.executedTools.isEmpty)

        await root.endAuthenticatedSession(named: "agent:first")
        await root.endAuthenticatedSession(named: "agent:second")
    }

    @Test
    func `authenticated target lock canonicalizes endpoint aliases by browser identity`() throws {
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: MockBrowserMCPManager())
        }
        let firstSessionID = BrowserMCPAuthenticatedSessionPool.SessionID()
        let secondSessionID = BrowserMCPAuthenticatedSessionPool.SessionID()
        _ = pool.manager(for: firstSessionID)
        _ = pool.manager(for: secondSessionID)
        try pool.bind(firstSessionID, to: BrowserMCPConnectionReceipt(
            processIdentifier: 42,
            processStartIdentity: 1001,
            browserURL: "http://localhost:9222/",
            webSocketDebuggerURL: "ws://localhost:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a"))

        #expect(throws: BrowserMCPConnectionError.targetLocked) {
            try pool.bind(secondSessionID, to: BrowserMCPConnectionReceipt(
                browserURL: "http://127.0.0.1:9222/",
                webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
                devToolsBrowserID: "browser-a"))
        }
    }

    @Test
    func `root and scoped sessions cannot claim the same exact target in either order`() throws {
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: MockBrowserMCPManager())
        }
        let sessionID = BrowserMCPAuthenticatedSessionPool.SessionID()
        _ = pool.manager(for: sessionID)
        let receipt = BrowserMCPConnectionReceipt(
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a")

        try pool.bindRoot(to: receipt)
        #expect(throws: BrowserMCPConnectionError.targetLocked) {
            try pool.bind(sessionID, to: receipt)
        }
        pool.unbindRoot()
        try pool.bind(sessionID, to: receipt)
        #expect(throws: BrowserMCPConnectionError.targetLocked) {
            try pool.bindRoot(to: receipt)
        }
        pool.unbind(sessionID)
        try pool.bindRoot(to: receipt)
    }

    @Test
    func `isolated child receipts do not overlock independently owned browser instances`() throws {
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: MockBrowserMCPManager())
        }
        let first = BrowserMCPAuthenticatedSessionPool.SessionID()
        let second = BrowserMCPAuthenticatedSessionPool.SessionID()
        _ = pool.manager(for: first)
        _ = pool.manager(for: second)
        let isolatedReceipt = BrowserMCPConnectionReceipt(channel: .stable)

        try pool.bind(first, to: isolatedReceipt)
        try pool.bind(second, to: isolatedReceipt)
    }

    @Test
    func `authenticated target ownership remains reserved until provider teardown completes`() async throws {
        let firstProvider = MockBrowserMCPManager()
        firstProvider.hasConfiguredServer = true
        firstProvider.connected = true
        let teardownBarrier = SequenceBarrier()
        firstProvider.removeHandler = {
            await teardownBarrier.block()
        }
        var providers = [firstProvider, MockBrowserMCPManager()]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: providers.removeFirst())
        }
        let firstSessionID = BrowserMCPAuthenticatedSessionPool.SessionID()
        let secondSessionID = BrowserMCPAuthenticatedSessionPool.SessionID()
        let firstManager = try #require(pool.manager(for: firstSessionID))
        _ = pool.manager(for: secondSessionID)
        let firstService = BrowserMCPService(
            sessionManager: firstManager,
            ownedSession: (pool: pool, id: firstSessionID))
        let receipt = BrowserMCPConnectionReceipt(
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a")
        try pool.bind(firstSessionID, to: receipt)

        let teardown = Task { @MainActor in
            await pool.end(firstSessionID)
        }
        await teardownBarrier.waitUntilBlocked()
        let duplicateCompletion = CompletionFlag()
        let duplicateTeardown = Task { @MainActor in
            await pool.end(firstSessionID)
            await duplicateCompletion.markFinished()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await !(duplicateCompletion.finished))
        _ = await firstService.status(channel: nil)
        await firstService.disconnect()
        #expect(throws: BrowserMCPConnectionError.targetLocked) {
            try pool.bind(secondSessionID, to: receipt)
        }

        await teardownBarrier.release()
        await teardown.value
        await duplicateTeardown.value
        #expect(await duplicateCompletion.finished)
        try pool.bind(secondSessionID, to: receipt)
    }

    @Test
    func `authenticated target rebind replaces the prior ownership keys`() throws {
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: MockBrowserMCPManager())
        }
        let firstSessionID = BrowserMCPAuthenticatedSessionPool.SessionID()
        let secondSessionID = BrowserMCPAuthenticatedSessionPool.SessionID()
        _ = pool.manager(for: firstSessionID)
        _ = pool.manager(for: secondSessionID)
        let firstReceipt = BrowserMCPConnectionReceipt(devToolsBrowserID: "browser-a")
        let secondReceipt = BrowserMCPConnectionReceipt(devToolsBrowserID: "browser-b")

        try pool.bind(firstSessionID, to: firstReceipt)
        try pool.bind(firstSessionID, to: secondReceipt)
        try pool.bind(secondSessionID, to: firstReceipt)
        #expect(throws: BrowserMCPConnectionError.targetLocked) {
            try pool.bind(secondSessionID, to: secondReceipt)
        }
    }

    @Test
    func `failed post connect rebind releases the caller stale target ownership`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        let thirdProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider, thirdProvider]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: providers.removeFirst(), browserID: nil)
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:first"))
        let second = try #require(root.authenticatedSession(named: "agent:second"))
        let third = try #require(root.authenticatedSession(named: "agent:third"))
        let firstURL = "http://127.0.0.1:9222"
        let secondURL = "http://127.0.0.1:9333"
        _ = try await first.connect(channel: nil, browserURL: firstURL)
        firstProvider.connected = false
        _ = await first.status(channel: nil)
        _ = try await second.connect(channel: nil, browserURL: secondURL)

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await first.connect(channel: nil, browserURL: secondURL)
        }
        _ = try await third.connect(channel: nil, browserURL: firstURL)

        await root.endAuthenticatedSession(named: "agent:first")
        await root.endAuthenticatedSession(named: "agent:second")
        await root.endAuthenticatedSession(named: "agent:third")
    }

    @Test
    func `failed reconnect setup releases stale target ownership`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: providers.removeFirst(), browserID: nil)
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:first"))
        let second = try #require(root.authenticatedSession(named: "agent:second"))
        let firstSessionID = try #require(pool.sessionID(named: "agent:first"))
        let firstManager = try #require(pool.manager(for: firstSessionID))
        let firstURL = "http://127.0.0.1:9222"
        _ = try await first.connect(channel: nil, browserURL: firstURL)
        firstProvider.connected = false
        _ = await firstManager.status(channel: nil)
        firstProvider.executeError = MockBrowserError.probe

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await first.connect(
                channel: nil,
                browserURL: "http://127.0.0.1:9333")
        }
        _ = try await second.connect(channel: nil, browserURL: firstURL)

        await root.endAuthenticatedSession(named: "agent:first")
        await root.endAuthenticatedSession(named: "agent:second")
    }

    @Test
    func `returned connection failure releases stale target ownership`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: providers.removeFirst())
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:first"))
        let second = try #require(root.authenticatedSession(named: "agent:second"))
        _ = try await first.connect(channel: nil, browserURL: nil)
        firstProvider.executeError = MockBrowserError.probe

        let result = try await first.executeSequenceWithOutcome(
            [BrowserMCPMappedCall(toolName: "click", arguments: [
                "uid": "1_0",
                "pageId": 7,
            ])],
            channel: nil,
            connectionPolicy: .requireExistingLiveReceipt)

        #expect(result.payload.isError)
        _ = try await second.connect(channel: nil, browserURL: nil)
        await root.endAuthenticatedSession(named: "agent:first")
        await root.endAuthenticatedSession(named: "agent:second")
    }

    @Test
    func `production Agent session resumes reuse one scoped child capability namespace`() async throws {
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: MockBrowserMCPManager())
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let services = Self.services(browser: root)
        let agent = try PeekabooAgentService(services: services)
        let first = try #require(await agent.browserClient(forAgentSessionID: "session-a") as? BrowserMCPService)
        let resumed = try #require(await agent.browserClient(forAgentSessionID: "session-a") as? BrowserMCPService)
        let other = try #require(await agent.browserClient(forAgentSessionID: "session-b") as? BrowserMCPService)
        let firstCapabilities = try #require(first.browserCapabilitySession)
        let resumedCapabilities = try #require(resumed.browserCapabilitySession)
        let otherCapabilities = try #require(other.browserCapabilitySession)

        #expect(firstCapabilities === resumedCapabilities)
        #expect(firstCapabilities !== otherCapabilities)
        await agent.endBrowserClient(forAgentSessionID: "session-a")
        let restarted = try #require(await agent.browserClient(forAgentSessionID: "session-a") as? BrowserMCPService)
        let restartedCapabilities = try #require(restarted.browserCapabilitySession)
        #expect(restartedCapabilities !== firstCapabilities)
        await agent.endBrowserClient(forAgentSessionID: "session-a")
        await agent.endBrowserClient(forAgentSessionID: "session-b")
    }

    @Test
    func `remote Agent sessions coalesce resume and never dispatch through shared root`() async throws {
        let root = AgentRemoteBrowserRoot()
        let openBarrier = SequenceBarrier()
        root.openBarrier = openBarrier
        let agent = try PeekabooAgentService(services: Self.services(browser: root))

        let firstOpen = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: "session-a")
        }
        await openBarrier.waitUntilBlocked()
        let resumedOpen = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: "session-a")
        }
        await Task.yield()
        #expect(root.openCount == 1)
        await openBarrier.release()
        let first = try await firstOpen.value
        let resumed = try await resumedOpen.value
        let other = try await agent.browserClient(forAgentSessionID: "session-b")

        #expect(first !== root)
        #expect(first === resumed)
        #expect(first !== other)
        #expect(root.openCount == 2)
        let firstCapabilities = try #require(agent.remoteBrowserCapabilities["session-a"])
        let resumedCapabilities = try #require(agent.remoteBrowserCapabilities["session-a"])
        let otherCapabilities = try #require(agent.remoteBrowserCapabilities["session-b"])
        #expect(firstCapabilities === resumedCapabilities)
        #expect(firstCapabilities !== otherCapabilities)

        _ = try await first.execute(toolName: "list_pages", arguments: [:], channel: nil)
        let firstChild = try #require(first as? AgentRemoteScopedBrowserChild)
        #expect(firstChild.executeCount == 1)
        #expect(root.rootExecuteCount == 0)

        #expect(await agent.endBrowserClient(forAgentSessionID: "session-a"))
        #expect(await agent.endBrowserClient(forAgentSessionID: "session-b"))
        #expect(root.children.allSatisfy { $0.endCount == 1 })
    }

    @Test
    func `simultaneous remote Agent sessions serialize root opens and receive distinct children`() async throws {
        let root = AgentRemoteBrowserRoot()
        let openBarrier = SequenceBarrier()
        root.openBarrier = openBarrier
        let agent = try PeekabooAgentService(services: Self.services(browser: root))

        let firstOpen = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: "simultaneous-a")
        }
        await openBarrier.waitUntilBlocked()
        let secondOpen = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: "simultaneous-b")
        }
        await Task.yield()

        #expect(root.openCount == 1)
        #expect(root.concurrentOpenCount == 0)
        await openBarrier.release()

        let first = try await firstOpen.value
        let second = try await secondOpen.value
        #expect(first !== second)
        #expect(first !== root)
        #expect(second !== root)
        #expect(root.openCount == 2)
        #expect(root.concurrentOpenCount == 0)
        #expect(root.rootExecuteCount == 0)
        #expect(await agent.endBrowserClient(forAgentSessionID: "simultaneous-a"))
        #expect(await agent.endBrowserClient(forAgentSessionID: "simultaneous-b"))
        #expect(root.children.allSatisfy { $0.endCount == 1 })
    }

    @Test
    func `ending a queued remote Agent session prevents it from opening after the owner completes`() async throws {
        let root = AgentRemoteBrowserRoot()
        let openBarrier = SequenceBarrier()
        root.openBarrier = openBarrier
        let agent = try PeekabooAgentService(services: Self.services(browser: root))

        let ownerOpen = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: "queued-owner")
        }
        await openBarrier.waitUntilBlocked()
        let queuedOpen = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: "queued-ended")
        }
        await Task.yield()
        #expect(agent.remoteBrowserQueuedOpeningIDs["queued-ended"] != nil)

        #expect(await agent.endBrowserClient(forAgentSessionID: "queued-ended"))
        #expect(agent.remoteBrowserQueuedOpeningIDs["queued-ended"] == nil)
        await openBarrier.release()
        let owner = try await ownerOpen.value
        await #expect(throws: BrowserMCPConnectionError.sessionEnded) {
            _ = try await queuedOpen.value
        }

        #expect(root.openCount == 1)
        #expect(root.concurrentOpenCount == 0)
        #expect(root.children.count == 1)
        #expect(await agent.endBrowserClient(forAgentSessionID: "queued-owner"))
        let ownerChild = try #require(owner as? AgentRemoteScopedBrowserChild)
        #expect(ownerChild.endCount == 1)
    }

    @Test
    func `cancelled queued remote Agent open returns before owner completion and releases reservation`() async throws {
        let root = AgentRemoteBrowserRoot()
        let openBarrier = SequenceBarrier()
        root.openBarrier = openBarrier
        let agent = try PeekabooAgentService(services: Self.services(browser: root))

        let ownerOpen = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: "cancel-owner")
        }
        await openBarrier.waitUntilBlocked()
        let cancellationFinished = CompletionFlag()
        let queuedOpen = Task { @MainActor in
            do {
                _ = try await agent.browserClient(forAgentSessionID: "cancel-queued")
                Issue.record("Expected the queued browser open to be cancelled")
                return false
            } catch is CancellationError {
                await cancellationFinished.markFinished()
                return true
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
                return false
            }
        }
        await Task.yield()
        let queuedID = try #require(agent.remoteBrowserQueuedOpeningIDs["cancel-queued"])

        queuedOpen.cancel()
        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await !cancellationFinished.finished, ContinuousClock.now < cancellationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await cancellationFinished.finished)
        #expect(await queuedOpen.value)
        #expect(root.openCount == 1)
        #expect(agent.remoteBrowserQueuedOpeningIDs["cancel-queued"] == nil)
        #expect(agent.remoteBrowserQueuedOpeningWaiterCounts[queuedID] == nil)
        #expect(await agent.endBrowserClient(forAgentSessionID: "cancel-queued"))

        await openBarrier.release()
        _ = try await ownerOpen.value
        #expect(await agent.endBrowserClient(forAgentSessionID: "cancel-owner"))
    }

    @Test
    func `ended queued generation cannot retain a cancelled replacement reservation`() async throws {
        let root = AgentRemoteBrowserRoot()
        let ownerBarrier = SequenceBarrier()
        root.openBarrier = ownerBarrier
        let agent = try PeekabooAgentService(services: Self.services(browser: root))
        let ownerSessionID = "queue-generation-owner"
        let queuedSessionID = "queue-generation-replacement"

        let ownerOpen = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: ownerSessionID)
        }
        await ownerBarrier.waitUntilBlocked()
        let endedGenerationOpen = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: queuedSessionID)
        }
        await Task.yield()
        let endedQueuedID = try #require(agent.remoteBrowserQueuedOpeningIDs[queuedSessionID])
        #expect(agent.remoteBrowserQueuedOpeningWaiterCounts[endedQueuedID] == 1)

        #expect(await agent.endBrowserClient(forAgentSessionID: queuedSessionID))
        #expect(agent.remoteBrowserQueuedOpeningIDs[queuedSessionID] == nil)
        #expect(agent.remoteBrowserQueuedOpeningWaiterCounts[endedQueuedID] == 1)

        let replacementCancelled = CompletionFlag()
        let replacementOpen = Task { @MainActor in
            do {
                _ = try await agent.browserClient(forAgentSessionID: queuedSessionID)
                Issue.record("Expected replacement queued generation cancellation")
                return false
            } catch is CancellationError {
                await replacementCancelled.markFinished()
                return true
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
                return false
            }
        }
        await Task.yield()
        let replacementQueuedID = try #require(agent.remoteBrowserQueuedOpeningIDs[queuedSessionID])
        #expect(replacementQueuedID != endedQueuedID)
        #expect(agent.remoteBrowserQueuedOpeningWaiterCounts[replacementQueuedID] == 1)

        replacementOpen.cancel()
        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await !replacementCancelled.finished, ContinuousClock.now < cancellationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await replacementCancelled.finished)
        #expect(await replacementOpen.value)
        #expect(agent.remoteBrowserQueuedOpeningIDs[queuedSessionID] == nil)
        #expect(agent.remoteBrowserQueuedOpeningWaiterCounts[replacementQueuedID] == nil)
        #expect(agent.remoteBrowserQueuedOpeningWaiterCounts[endedQueuedID] == 1)

        await ownerBarrier.release()
        _ = try await ownerOpen.value
        await #expect(throws: BrowserMCPConnectionError.sessionEnded) {
            _ = try await endedGenerationOpen.value
        }
        #expect(agent.remoteBrowserQueuedOpeningWaiterCounts[endedQueuedID] == nil)
        #expect(await agent.endBrowserClient(forAgentSessionID: ownerSessionID))
    }

    @Test
    func `cancelled coalesced remote Agent open does not cancel its surviving waiter`() async throws {
        let root = AgentRemoteBrowserRoot()
        let openBarrier = SequenceBarrier()
        root.openBarrier = openBarrier
        let agent = try PeekabooAgentService(services: Self.services(browser: root))
        let sessionID = "coalesced-cancellation"
        let cancellationFinished = CompletionFlag()

        let cancelledOpen = Task { @MainActor in
            do {
                _ = try await agent.browserClient(forAgentSessionID: sessionID)
                Issue.record("Expected the first coalesced waiter to be cancelled")
                return false
            } catch is CancellationError {
                await cancellationFinished.markFinished()
                return true
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
                return false
            }
        }
        await openBarrier.waitUntilBlocked()
        let survivingOpen = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: sessionID)
        }
        await Task.yield()
        #expect(root.openCount == 1)
        guard case let .inFlight(_, _, openingWaiters)? = agent.remoteBrowserOpeningTasks[sessionID] else {
            Issue.record("Expected one shared in-flight opening generation")
            return
        }
        #expect(openingWaiters.pendingCount == 2)

        cancelledOpen.cancel()
        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await !cancellationFinished.finished, ContinuousClock.now < cancellationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await cancellationFinished.finished)
        #expect(await cancelledOpen.value)
        #expect(openingWaiters.pendingCount == 1)
        #expect(agent.remoteBrowserOpeningSessionID == sessionID)
        #expect(agent.remoteBrowserOpeningTasks[sessionID] != nil)

        await openBarrier.release()
        let survivingClient = try await survivingOpen.value
        #expect(survivingClient !== root)
        #expect(agent.remoteBrowserClients[sessionID] === survivingClient)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(agent.remoteBrowserOpeningSessionID == nil)
        #expect(root.openCount == 1)
        #expect(await agent.endBrowserClient(forAgentSessionID: sessionID))
    }

    @Test
    func `cancelled sole remote Agent open is reconciled after its provider returns`() async throws {
        let root = AgentRemoteBrowserRoot()
        let openBarrier = SequenceBarrier()
        root.openBarrier = openBarrier
        let agent = try PeekabooAgentService(services: Self.services(browser: root))
        let sessionID = "sole-cancellation"
        let cancellationFinished = CompletionFlag()

        let cancelledOpen = Task { @MainActor in
            do {
                _ = try await agent.browserClient(forAgentSessionID: sessionID)
                Issue.record("Expected the sole browser open waiter to be cancelled")
                return false
            } catch is CancellationError {
                await cancellationFinished.markFinished()
                return true
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
                return false
            }
        }
        await openBarrier.waitUntilBlocked()
        cancelledOpen.cancel()

        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await !cancellationFinished.finished, ContinuousClock.now < cancellationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await cancellationFinished.finished)
        #expect(await cancelledOpen.value)
        #expect(agent.remoteBrowserOpeningSessionID == sessionID)
        guard case let .inFlight(_, _, openingWaiters)? = agent.remoteBrowserOpeningTasks[sessionID] else {
            Issue.record("Expected the provider-owned generation to remain addressable")
            return
        }
        #expect(openingWaiters.pendingCount == 0)

        await openBarrier.release()
        let reconciliationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while agent.remoteBrowserClients[sessionID] == nil,
              ContinuousClock.now < reconciliationDeadline
        {
            try await Task.sleep(for: .milliseconds(5))
        }
        let reconciledClient = try #require(agent.remoteBrowserClients[sessionID])
        #expect(reconciledClient !== root)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(agent.remoteBrowserOpeningSessionID == nil)
        #expect(await agent.endBrowserClient(forAgentSessionID: sessionID))
    }

    @Test
    func `cancelled Agent waiter preserves production transport claim retry`() async throws {
        let transport = AgentClaimRecordingRemoteBrowserTransport()
        let openBarrier = SequenceBarrier()
        transport.openBarrier = openBarrier
        let root = RemoteBrowserMCPClient(
            client: PeekabooBridgeClient(
                socketPath: "/private/tmp/peekaboo-agent-claim-retry-no-root.sock",
                requestTimeoutSec: 0.1),
            sessionTransport: transport)
        let agent = try PeekabooAgentService(services: Self.services(browser: root))
        let sessionID = "production-claim-cancellation"
        let cancellationFinished = CompletionFlag()

        let cancelledOpen = Task { @MainActor in
            do {
                _ = try await agent.browserClient(forAgentSessionID: sessionID)
                Issue.record("Expected the production transport waiter to be cancelled")
                return false
            } catch is CancellationError {
                await cancellationFinished.markFinished()
                return true
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
                return false
            }
        }
        await openBarrier.waitUntilBlocked()
        cancelledOpen.cancel()

        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await !cancellationFinished.finished, ContinuousClock.now < cancellationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await cancellationFinished.finished)
        #expect(await cancelledOpen.value)
        #expect(transport.openedClaimIDs.count == 1)

        await openBarrier.release()
        let reconciliationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while agent.remoteBrowserClients[sessionID] == nil,
              ContinuousClock.now < reconciliationDeadline
        {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(transport.openedClaimIDs.count == 2)
        #expect(transport.openedClaimIDs[0] == transport.openedClaimIDs[1])
        #expect(!root.browserMCPScopedSessionOpenAttemptRequiresRecovery)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(agent.remoteBrowserOpeningSessionID == nil)
        #expect(await agent.endBrowserClient(forAgentSessionID: sessionID))
        #expect(transport.endedSessionIDs.count == 1)
    }

    @Test
    func `cancelled coalesced queued remote Agent open preserves its surviving reservation`() async throws {
        let root = AgentRemoteBrowserRoot()
        let ownerBarrier = SequenceBarrier()
        root.openBarrier = ownerBarrier
        let agent = try PeekabooAgentService(services: Self.services(browser: root))
        let queuedSessionID = "coalesced-queued-cancellation"
        let cancellationFinished = CompletionFlag()

        let ownerOpen = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: "coalesced-queued-owner")
        }
        await ownerBarrier.waitUntilBlocked()
        let cancelledOpen = Task { @MainActor in
            do {
                _ = try await agent.browserClient(forAgentSessionID: queuedSessionID)
                Issue.record("Expected the first queued waiter to be cancelled")
                return false
            } catch is CancellationError {
                await cancellationFinished.markFinished()
                return true
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
                return false
            }
        }
        let survivingOpen = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: queuedSessionID)
        }
        await Task.yield()
        let queuedID = try #require(agent.remoteBrowserQueuedOpeningIDs[queuedSessionID])
        #expect(agent.remoteBrowserQueuedOpeningWaiterCounts[queuedID] == 2)

        cancelledOpen.cancel()
        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await !cancellationFinished.finished, ContinuousClock.now < cancellationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await cancellationFinished.finished)
        #expect(await cancelledOpen.value)
        #expect(agent.remoteBrowserQueuedOpeningIDs[queuedSessionID] == queuedID)
        #expect(agent.remoteBrowserQueuedOpeningWaiterCounts[queuedID] == 1)

        await ownerBarrier.release()
        let ownerClient = try await ownerOpen.value
        let survivingClient = try await survivingOpen.value
        #expect(ownerClient !== survivingClient)
        #expect(root.openCount == 2)
        #expect(agent.remoteBrowserQueuedOpeningIDs[queuedSessionID] == nil)
        #expect(agent.remoteBrowserQueuedOpeningWaiterCounts[queuedID] == nil)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(agent.remoteBrowserOpeningSessionID == nil)
        #expect(await agent.endBrowserClient(forAgentSessionID: "coalesced-queued-owner"))
        #expect(await agent.endBrowserClient(forAgentSessionID: queuedSessionID))
    }

    @Test
    func `retryable remote Agent open uses a fresh task generation`() async throws {
        let root = AgentRemoteBrowserRoot()
        root.failNextOpenIndeterminately = true
        let agent = try PeekabooAgentService(services: Self.services(browser: root))
        let sessionID = "retry-generation"

        await #expect(throws: AgentRemoteBrowserOpenFixtureError.self) {
            _ = try await agent.browserClient(forAgentSessionID: sessionID)
        }
        let failedGeneration = try #require(agent.remoteBrowserOpeningTasks[sessionID]?.id)

        let retryBarrier = SequenceBarrier()
        root.openBarrier = retryBarrier
        let retry = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: sessionID)
        }
        await retryBarrier.waitUntilBlocked()
        let retryGeneration = try #require(agent.remoteBrowserOpeningTasks[sessionID]?.id)
        #expect(retryGeneration != failedGeneration)

        await retryBarrier.release()
        let browser = try await retry.value
        #expect(browser !== root)
        #expect(root.openCount == 2)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(await agent.endBrowserClient(forAgentSessionID: sessionID))
    }

    @Test
    func `remote Agent reports unresolved root recovery separately from capacity`() async throws {
        let root = AgentRemoteBrowserRoot()
        root.failNextOpenIndeterminately = true
        let agent = try PeekabooAgentService(services: Self.services(browser: root))

        await #expect(throws: AgentRemoteBrowserOpenFixtureError.self) {
            _ = try await agent.browserClient(forAgentSessionID: "recovery-owner")
        }
        do {
            _ = try await agent.browserClient(forAgentSessionID: "recovery-waiter")
            Issue.record("Expected the unresolved root owner to block another session")
        } catch let error as BrowserMCPConnectionError {
            #expect(error == .scopedSessionOpenRecoveryRequired)
            #expect(error.localizedDescription == "A caller-scoped browser session open remains unresolved. " +
                "End or retry its owning session before starting another browser-enabled session.")
        }

        #expect(root.openCount == 1)
        #expect(root.concurrentOpenCount == 0)
        #expect(await agent.endBrowserClient(forAgentSessionID: "recovery-waiter"))
        #expect(await agent.endBrowserClient(forAgentSessionID: "recovery-owner"))
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(agent.remoteBrowserQueuedOpeningIDs.isEmpty)
        #expect(agent.remoteBrowserOpeningSessionID == nil)
    }

    @Test
    func `indeterminate remote Agent open remains owned until exact cleanup before admitting another session`()
        async throws
    {
        let root = AgentRemoteBrowserRoot()
        root.failNextOpenIndeterminately = true
        let agent = try PeekabooAgentService(services: Self.services(browser: root))
        let firstSessionID = "indeterminate-a"

        await #expect(throws: AgentRemoteBrowserOpenFixtureError.self) {
            _ = try await agent.browserClient(forAgentSessionID: firstSessionID)
        }
        #expect(root.browserMCPScopedSessionOpenAttemptRequiresRecovery)
        #expect(agent.remoteBrowserOpeningTasks[firstSessionID] != nil)
        #expect(agent.remoteBrowserOpeningSessionID == firstSessionID)

        let cleanupBarrier = SequenceBarrier()
        root.openBarrier = cleanupBarrier
        let firstEnd = Task { @MainActor in
            await agent.endBrowserClient(forAgentSessionID: firstSessionID)
        }
        await cleanupBarrier.waitUntilBlocked()
        let secondOpen = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: "indeterminate-b")
        }
        await Task.yield()
        #expect(root.openCount == 2)
        #expect(root.concurrentOpenCount == 0)

        await cleanupBarrier.release()
        #expect(await firstEnd.value)
        let second = try await secondOpen.value
        let secondChild = try #require(second as? AgentRemoteScopedBrowserChild)
        let recoveredFirstChild = try #require(root.children.first)
        #expect(recoveredFirstChild !== secondChild)
        #expect(recoveredFirstChild.endCount == 1)
        #expect(secondChild.endCount == 0)
        #expect(root.openCount == 3)
        #expect(root.concurrentOpenCount == 0)
        #expect(root.rootExecuteCount == 0)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(agent.remoteBrowserOpeningSessionID == nil)
        #expect(await agent.endBrowserClient(forAgentSessionID: "indeterminate-b"))
        #expect(secondChild.endCount == 1)
    }

    @Test(arguments: [false, true])
    func `ephemeral Agent execution cleans indeterminate remote open before the next run`(
        streaming: Bool) async throws
    {
        let root = AgentRemoteBrowserRoot()
        root.failNextOpenIndeterminately = true
        let provider = AgentRemoteBrowserStatusProvider(supportsStreaming: streaming)
        let model = LanguageModel.custom(provider: provider)
        let agent = try PeekabooAgentService(
            services: Self.services(browser: root),
            defaultModel: model)
        let delegate: (any AgentEventDelegate)? = streaming
            ? StreamingEventDelegate { _ in }
            : nil

        await #expect(throws: AgentRemoteBrowserOpenFixtureError.self) {
            _ = try await agent.executeTask(
                "Inspect browser status",
                model: model,
                eventDelegate: delegate,
                persistSession: false)
        }
        #expect(provider.requestCount == 0)
        #expect(root.openCount == 2)
        #expect(root.children.count == 1)
        #expect(root.children[0].endCount == 1)
        #expect(agent.remoteBrowserClients.isEmpty)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(agent.remoteBrowserQueuedOpeningIDs.isEmpty)
        #expect(agent.remoteBrowserOpeningSessionID == nil)
        #expect(agent.remoteBrowserCleanupDebt.isEmpty)
        #expect(!agent.browserCleanupDebtPending)

        let result = try await agent.executeTask(
            "Inspect browser status again",
            model: model,
            eventDelegate: delegate,
            persistSession: false)

        #expect(result.content == "remote browser execution completed")
        #expect(provider.requestCount == 2)
        #expect(root.openCount == 3)
        #expect(root.children.count == 2)
        #expect(root.children[1].statusCount == 1)
        #expect(root.children.allSatisfy { $0.endCount == 1 })
        #expect(agent.remoteBrowserClients.isEmpty)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(agent.remoteBrowserQueuedOpeningIDs.isEmpty)
        #expect(agent.remoteBrowserOpeningSessionID == nil)
        #expect(agent.remoteBrowserCleanupDebt.isEmpty)
        #expect(!agent.browserCleanupDebtPending)
        #expect(root.rootExecuteCount == 0)
    }

    @Test(arguments: [false, true])
    func `persistent Agent setup failure cleans its undelivered remote claim before resume`(
        streaming: Bool) async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekabooPersistentRemoteAgent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionManager = try AgentSessionManager(sessionDirectory: directory)
        let root = AgentRemoteBrowserRoot()
        root.failNextOpenIndeterminately = true
        let provider = AgentRemoteBrowserStatusProvider(supportsStreaming: streaming)
        let model = LanguageModel.custom(provider: provider)
        let agent = try PeekabooAgentService(
            services: Self.services(browser: root),
            defaultModel: model,
            sessionManager: sessionManager)
        let delegate: (any AgentEventDelegate)? = streaming
            ? StreamingEventDelegate { _ in }
            : nil

        await #expect(throws: AgentRemoteBrowserOpenFixtureError.self) {
            _ = try await agent.executeTask(
                "Inspect persistent browser status",
                model: model,
                eventDelegate: delegate)
        }
        let sessionID = try #require(sessionManager.listSessions().first?.id)
        #expect(provider.requestCount == 0)
        #expect(root.openCount == 2)
        #expect(root.children.count == 1)
        #expect(root.children[0].endCount == 1)
        #expect(agent.remoteBrowserClients.isEmpty)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(agent.remoteBrowserQueuedOpeningIDs.isEmpty)
        #expect(agent.remoteBrowserOpeningSessionID == nil)
        #expect(agent.remoteBrowserCleanupDebt.isEmpty)
        #expect(!agent.browserCleanupDebtPending)

        let result = try await agent.continueSession(
            sessionId: sessionID,
            userMessage: "Inspect persistent browser status again",
            model: model,
            eventDelegate: delegate)

        #expect(result.content == "remote browser execution completed")
        #expect(result.sessionId == sessionID)
        #expect(provider.requestCount == 2)
        #expect(root.openCount == 3)
        #expect(root.children.count == 2)
        #expect(root.children[1].statusCount == 1)
        #expect(root.children[1].endCount == 0)
        #expect(agent.remoteBrowserClients[sessionID] === root.children[1])
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(agent.remoteBrowserQueuedOpeningIDs.isEmpty)
        #expect(agent.remoteBrowserOpeningSessionID == nil)
        #expect(agent.remoteBrowserCleanupDebt.isEmpty)
        #expect(!agent.browserCleanupDebtPending)

        try await agent.deleteSession(id: sessionID)
        #expect(root.children[1].endCount == 1)
        #expect(agent.remoteBrowserClients.isEmpty)
    }

    @Test
    func `cancelled peer acquisition cannot end a coalesced browser generation`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekabooConcurrentBrowserAcquisition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionManager = try AgentSessionManager(sessionDirectory: directory)
        let sessionID = "concurrent-browser-acquisition"
        let now = Date()
        try sessionManager.saveSession(AgentSession(
            id: sessionID,
            modelName: "agent-remote-browser-status",
            messages: [.user("Inspect browser status")],
            metadata: SessionMetadata(),
            createdAt: now,
            updatedAt: now))
        let root = AgentRemoteBrowserRoot()
        let openBarrier = SequenceBarrier()
        let terminalResponseBarrier = SequenceBarrier()
        root.openBarrier = openBarrier
        let provider = AgentRemoteBrowserStatusProvider(
            supportsStreaming: false,
            terminalResponseBarrier: terminalResponseBarrier)
        let model = LanguageModel.custom(provider: provider)
        let agent = try PeekabooAgentService(
            services: Self.services(browser: root),
            defaultModel: model,
            sessionManager: sessionManager)
        let firstGeneration = try agent.beginAgentSessionExecution(for: sessionID)
        let secondGeneration = try agent.beginAgentSessionExecution(for: sessionID)

        func context(generation: UUID) -> PeekabooAgentService.SessionContext {
            PeekabooAgentService.SessionContext(
                id: sessionID,
                isPersistent: true,
                messages: [.user("Inspect browser status")],
                createdAt: now,
                executionStart: now,
                metadata: SessionMetadata(),
                modelIdentity: .init(
                    displayName: provider.modelId,
                    selection: nil,
                    endpointIdentity: nil,
                    providerIdentity: nil),
                storedToolExecutionPolicy: .backgroundOnly,
                toolExecutionPolicy: .backgroundOnly,
                provider: provider,
                executionGeneration: generation)
        }

        let first = Task { @MainActor in
            try await agent.executeWithoutStreaming(
                context: context(generation: firstGeneration),
                model: model)
        }
        await openBarrier.waitUntilBlocked()
        #expect(agent.agentSessionBrowserExecutionGenerations[sessionID] == [firstGeneration])

        let cancelledPeer = Task { @MainActor in
            do {
                _ = try await agent.executeWithoutStreaming(
                    context: context(generation: secondGeneration),
                    model: model)
                Issue.record("Expected the peer browser acquisition to be cancelled")
                return false
            } catch is CancellationError {
                return true
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
                return false
            }
        }
        let waiterDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < waiterDeadline {
            guard case let .inFlight(_, _, waiters)? = agent.remoteBrowserOpeningTasks[sessionID] else {
                break
            }
            if waiters.pendingCount == 2 {
                break
            }
            await Task.yield()
        }
        guard case let .inFlight(_, _, waiters)? = agent.remoteBrowserOpeningTasks[sessionID] else {
            Issue.record("Expected one coalesced browser opening")
            await openBarrier.release()
            _ = try? await first.value
            return
        }
        #expect(waiters.pendingCount == 2)

        cancelledPeer.cancel()
        #expect(await cancelledPeer.value)
        #expect(agent.agentSessionBrowserExecutionGenerations[sessionID] == [firstGeneration])
        #expect(agent.remoteBrowserEndingTasks.isEmpty)
        #expect(agent.remoteBrowserCleanupDebt.isEmpty)

        await openBarrier.release()
        await terminalResponseBarrier.waitUntilBlocked()
        #expect(root.children.count == 1)
        let child = try #require(root.children.first)
        #expect(child.statusCount == 1)
        #expect(child.endCount == 0)
        #expect(agent.remoteBrowserClients[sessionID] === child)

        await terminalResponseBarrier.release()
        let result = try await first.value
        #expect(result.content == "remote browser execution completed")
        #expect(agent.agentSessionBrowserExecutionGenerations[sessionID] == nil)
        #expect(await (child.status(channel: nil)).observation == BrowserMCPStatusObservation.confirmed)
        #expect(child.endCount == 0)

        #expect(await agent.endBrowserClient(forAgentSessionID: sessionID))
        #expect(child.endCount == 1)
        #expect(agent.remoteBrowserClients.isEmpty)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(agent.remoteBrowserEndingTasks.isEmpty)
        #expect(agent.remoteBrowserCleanupDebt.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func `cancelled Agent setup returns while remote open is stalled and later admits another run`(
        streaming: Bool,
        persistent: Bool) async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekabooCancelledRemoteAgent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionManager = try AgentSessionManager(sessionDirectory: directory)
        let root = AgentRemoteBrowserRoot()
        let openBarrier = SequenceBarrier()
        root.openBarrier = openBarrier
        let provider = AgentRemoteBrowserStatusProvider(supportsStreaming: streaming)
        let model = LanguageModel.custom(provider: provider)
        let agent = try PeekabooAgentService(
            services: Self.services(browser: root),
            defaultModel: model,
            sessionManager: sessionManager)
        let delegate: (any AgentEventDelegate)? = streaming
            ? StreamingEventDelegate { _ in }
            : nil
        let cancellationFinished = CompletionFlag()

        let execution = Task { @MainActor in
            do {
                _ = try await agent.executeTask(
                    "Inspect browser status before cancellation",
                    model: model,
                    eventDelegate: delegate,
                    persistSession: persistent)
                Issue.record("Expected Agent setup to be cancelled")
                return false
            } catch is CancellationError {
                await cancellationFinished.markFinished()
                return true
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
                return false
            }
        }
        await openBarrier.waitUntilBlocked()
        let sessionID = try #require(agent.remoteBrowserOpeningSessionID)
        #expect(agent.remoteBrowserOpeningTasks[sessionID] != nil)
        #expect(provider.requestCount == 0)

        execution.cancel()
        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await !cancellationFinished.finished, ContinuousClock.now < cancellationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await cancellationFinished.finished)
        #expect(await execution.value)
        #expect(agent.remoteBrowserCleanupDebt == [sessionID])
        let ending = try #require(agent.remoteBrowserEndingTasks[sessionID])
        #expect(ending.waiters.pendingCount == 0)
        #expect(root.openCount == 1)

        await openBarrier.release()
        let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !agent.remoteBrowserOpeningTasks.isEmpty ||
            !agent.remoteBrowserEndingTasks.isEmpty ||
            !agent.remoteBrowserCleanupDebt.isEmpty,
            ContinuousClock.now < cleanupDeadline
        {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(agent.remoteBrowserClients.isEmpty)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(agent.remoteBrowserQueuedOpeningIDs.isEmpty)
        #expect(agent.remoteBrowserQueuedOpeningWaiterCounts.isEmpty)
        #expect(agent.remoteBrowserOpeningSessionID == nil)
        #expect(agent.remoteBrowserEndingTasks.isEmpty)
        #expect(agent.remoteBrowserCleanupDebt.isEmpty)
        #expect(!agent.browserCleanupDebtPending)
        #expect(root.children.count == 1)
        #expect(root.children[0].endCount == 1)

        let result: AgentExecutionResult
        if persistent {
            #expect(sessionManager.listSessions().contains { $0.id == sessionID })
            result = try await agent.continueSession(
                sessionId: sessionID,
                userMessage: "Inspect browser status after cancellation",
                model: model,
                eventDelegate: delegate)
        } else {
            result = try await agent.executeTask(
                "Inspect browser status after cancellation",
                model: model,
                eventDelegate: delegate,
                persistSession: false)
        }
        #expect(result.content == "remote browser execution completed")
        #expect(provider.requestCount == 2)
        #expect(root.openCount == 2)
        #expect(root.children.count == 2)
        #expect(root.children[1].statusCount == 1)
        if persistent {
            #expect(root.children[1].endCount == 0)
            try await agent.deleteSession(id: sessionID)
            #expect(root.children[1].endCount == 1)
        } else {
            #expect(root.children[1].endCount == 1)
        }
        #expect(agent.remoteBrowserClients.isEmpty)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(agent.remoteBrowserQueuedOpeningIDs.isEmpty)
        #expect(agent.remoteBrowserQueuedOpeningWaiterCounts.isEmpty)
        #expect(agent.remoteBrowserOpeningSessionID == nil)
        #expect(agent.remoteBrowserCleanupDebt.isEmpty)
        #expect(!agent.browserCleanupDebtPending)
    }

    @Test
    func `browser filtered Agent execution toolset opens no remote scope`() async throws {
        let root = AgentRemoteBrowserRoot()
        let agent = try PeekabooAgentService(services: Self.services(browser: root))
        let filters = ToolFiltering.filters(
            config: Configuration(tools: .init(allow: ["permissions", "sleep"])),
            environment: [:])

        let tools = try await agent.buildExecutionToolset(
            for: .anthropic(.sonnet45),
            agentSessionID: "browser-filtered",
            snapshotOwner: MCPToolSnapshotOwner(sessionID: "browser-filtered"),
            executionPolicy: .backgroundOnly,
            filters: filters)

        #expect(!tools.contains { $0.name == "browser" })
        #expect(root.openCount == 0)
        #expect(root.rootExecuteCount == 0)
        #expect(agent.remoteBrowserClients.isEmpty)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
    }

    @Test
    func `browser included remote Agent execution toolset refuses a legacy shared root`() async throws {
        let root = AgentLegacyRemoteBrowserRoot()
        let services = AgentRemoteBrowserServices(base: Self.services(browser: root))
        let agent = try PeekabooAgentService(services: services)
        let filters = ToolFiltering.filters(
            config: Configuration(tools: .init(allow: ["browser"])),
            environment: [:])

        await #expect(throws: BrowserMCPConnectionError.receiptBindingUnsupported) {
            _ = try await agent.buildExecutionToolset(
                for: .anthropic(.sonnet45),
                agentSessionID: "browser-included",
                snapshotOwner: MCPToolSnapshotOwner(sessionID: "browser-included"),
                executionPolicy: .backgroundOnly,
                filters: filters)
        }
        #expect(root.executeCount == 0)
        #expect(agent.remoteBrowserClients.isEmpty)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
    }

    @Test
    func `remote Agent teardown closes an in flight open before the child becomes usable`() async throws {
        let root = AgentRemoteBrowserRoot()
        let openBarrier = SequenceBarrier()
        root.openBarrier = openBarrier
        let agent = try PeekabooAgentService(services: Self.services(browser: root))
        let sessionID = "opening-then-ended"

        let opening = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: sessionID)
        }
        await openBarrier.waitUntilBlocked()
        let firstEnding = Task { @MainActor in
            await agent.endBrowserClient(forAgentSessionID: sessionID)
        }
        await Task.yield()
        #expect(agent.remoteBrowserCleanupDebt.contains(sessionID))
        #expect(agent.remoteBrowserEndingTasks.count == 1)
        let secondEnding = Task { @MainActor in
            await agent.endBrowserClient(forAgentSessionID: sessionID)
        }
        await Task.yield()
        #expect(agent.remoteBrowserEndingTasks.count == 1)

        await openBarrier.release()
        await #expect(throws: BrowserMCPConnectionError.sessionEnded) {
            _ = try await opening.value
        }
        #expect(await firstEnding.value)
        let endedChild = try #require(root.children.first)
        #expect(endedChild.endCount == 1)
        #expect(agent.remoteBrowserClients.isEmpty)
        #expect(agent.remoteBrowserCapabilities.isEmpty)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(agent.remoteBrowserEndingTasks.isEmpty)
        #expect(agent.remoteBrowserCleanupDebt.isEmpty)

        let restarted = try await agent.browserClient(forAgentSessionID: sessionID)
        let restartedChild = try #require(restarted as? AgentRemoteScopedBrowserChild)
        #expect(await secondEnding.value)
        #expect(agent.remoteBrowserClients[sessionID] === restartedChild)
        #expect(endedChild.endCount == 1)
        #expect(restartedChild.endCount == 0)
        #expect(await agent.endBrowserClient(forAgentSessionID: sessionID))
        #expect(restartedChild.endCount == 1)
    }

    @Test
    func `remote Agent refuses a browser root without scoped session support`() async throws {
        let root = AgentLegacyRemoteBrowserRoot()
        let services = Self.services(browser: root)
        let agent = try PeekabooAgentService(services: AgentRemoteBrowserServices(base: services))

        await #expect(throws: BrowserMCPConnectionError.receiptBindingUnsupported) {
            _ = try await agent.browserClient(forAgentSessionID: "must-not-borrow-root")
        }
        #expect(root.executeCount == 0)
        #expect(agent.remoteBrowserClients.isEmpty)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
    }

    @Test
    func `local Agent refuses a browser provider without authenticated or scoped sessions`() async throws {
        let root = AgentLegacyRemoteBrowserRoot()
        let agent = try PeekabooAgentService(services: Self.services(browser: root))

        await #expect(throws: BrowserMCPConnectionError.receiptBindingUnsupported) {
            _ = try await agent.browserClient(forAgentSessionID: "unsupported-local-provider")
        }

        #expect(root.executeCount == 0)
        #expect(agent.remoteBrowserClients.isEmpty)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
    }

    @Test
    func `remote Agent capacity counts active and opening sessions and reopens after release`() async throws {
        let root = AgentRemoteBrowserRoot()
        let agent = try PeekabooAgentService(services: Self.services(browser: root))
        let capacity = BrowserMCPAuthenticatedSessionPool.sessionCapacity
        var activeSessionIDs: [String] = []
        for index in 0..<(capacity - 1) {
            let sessionID = "capacity-active-\(index)"
            _ = try await agent.browserClient(forAgentSessionID: sessionID)
            activeSessionIDs.append(sessionID)
        }

        let openBarrier = SequenceBarrier()
        root.openBarrier = openBarrier
        let pendingSessionID = "capacity-pending"
        let pendingOpen = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: pendingSessionID)
        }
        await openBarrier.waitUntilBlocked()
        #expect(agent.remoteBrowserClients.count == capacity - 1)
        #expect(agent.remoteBrowserOpeningTasks.count == 1)
        #expect(root.openCount == capacity)

        do {
            _ = try await agent.browserClient(forAgentSessionID: "capacity-overflow")
            Issue.record("Expected the full session store to refuse another reservation")
        } catch let error as BrowserMCPConnectionError {
            #expect(error == .authenticatedSessionCapacityExceeded)
            #expect(error.localizedDescription == "The bounded authenticated browser session store is full. " +
                "End a session, or retry after cleanup completes.")
        }
        #expect(root.openCount == capacity)

        let releasedSessionID = activeSessionIDs.removeFirst()
        #expect(await agent.endBrowserClient(forAgentSessionID: releasedSessionID))
        let replacementSessionID = "capacity-replacement"
        let replacementOpen = Task { @MainActor in
            try await agent.browserClient(forAgentSessionID: replacementSessionID)
        }
        await Task.yield()
        #expect(root.openCount == capacity)

        await openBarrier.release()
        let pending = try await pendingOpen.value
        let replacement = try await replacementOpen.value
        #expect(pending !== replacement)
        #expect(agent.remoteBrowserClients.count == capacity)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(root.openCount == capacity + 1)
        await #expect(throws: BrowserMCPConnectionError.authenticatedSessionCapacityExceeded) {
            _ = try await agent.browserClient(forAgentSessionID: "capacity-overflow-again")
        }

        for sessionID in activeSessionIDs + [replacementSessionID, pendingSessionID] {
            #expect(await agent.endBrowserClient(forAgentSessionID: sessionID))
        }
        #expect(agent.remoteBrowserClients.isEmpty)
        #expect(root.children.allSatisfy { $0.endCount == 1 })
    }

    @Test
    func `remote Agent cleanup debt blocks resume until exact child cleanup succeeds`() async throws {
        let root = AgentRemoteBrowserRoot()
        root.nextEndResults = [[false, true], [true]]
        let agent = try PeekabooAgentService(services: Self.services(browser: root))
        let first = try await agent.browserClient(forAgentSessionID: "debt-session")
        let firstChild = try #require(first as? AgentRemoteScopedBrowserChild)

        #expect(await !agent.endBrowserClient(forAgentSessionID: "debt-session"))
        #expect(agent.browserCleanupDebtPending)
        #expect(firstChild.endCount == 1)
        await #expect(throws: BrowserMCPConnectionError.sessionEnded) {
            _ = try await agent.browserClient(forAgentSessionID: "debt-session")
        }

        let cleanupBarrier = SequenceBarrier()
        firstChild.endBarrier = cleanupBarrier
        let firstDrain = Task { @MainActor in await agent.drainBrowserCleanupDebt() }
        await cleanupBarrier.waitUntilBlocked()
        let secondDrain = Task { @MainActor in await agent.drainBrowserCleanupDebt() }
        await Task.yield()
        #expect(firstChild.endCount == 2)
        await cleanupBarrier.release()
        #expect(await firstDrain.value)
        #expect(await secondDrain.value)
        #expect(!agent.browserCleanupDebtPending)
        #expect(firstChild.endCount == 2)
        let restarted = try await agent.browserClient(forAgentSessionID: "debt-session")
        #expect(restarted !== first)
        #expect(root.openCount == 2)
        #expect(await agent.endBrowserClient(forAgentSessionID: "debt-session"))
    }

    @Test
    func `overlapping remote Agent teardown retains one failed child cleanup for a later drain`() async throws {
        let root = AgentRemoteBrowserRoot()
        root.nextEndResults = [[false, true]]
        let agent = try PeekabooAgentService(services: Self.services(browser: root))
        let sessionID = "overlapping-cleanup"
        let browser = try await agent.browserClient(forAgentSessionID: sessionID)
        let child = try #require(browser as? AgentRemoteScopedBrowserChild)
        let endBarrier = SequenceBarrier()
        child.endBarrier = endBarrier

        let firstEnd = Task { @MainActor in
            await agent.endBrowserClient(forAgentSessionID: sessionID)
        }
        await endBarrier.waitUntilBlocked()
        let releaseFirstEnd = Task { @MainActor in
            await endBarrier.release()
        }
        #expect(child.endCount == 1)

        let overlappingEnd = await agent.endBrowserClient(forAgentSessionID: sessionID)
        await releaseFirstEnd.value
        #expect(await !firstEnd.value)
        #expect(!overlappingEnd)
        #expect(child.endCount == 1)
        #expect(agent.remoteBrowserClients[sessionID] === child)
        #expect(agent.remoteBrowserEndingTasks.isEmpty)
        #expect(agent.remoteBrowserCleanupDebt == [sessionID])
        #expect(agent.browserCleanupDebtPending)

        #expect(await agent.drainBrowserCleanupDebt())
        #expect(child.endCount == 2)
        #expect(agent.remoteBrowserClients.isEmpty)
        #expect(agent.remoteBrowserCapabilities.isEmpty)
        #expect(agent.remoteBrowserEndingTasks.isEmpty)
        #expect(agent.remoteBrowserCleanupDebt.isEmpty)
        #expect(!agent.browserCleanupDebtPending)
    }

    @Test
    func `overlapping remote Agent teardown retains failed indeterminate recovery for a later drain`() async throws {
        let root = AgentRemoteBrowserRoot()
        root.failNextOpenIndeterminately = true
        let agent = try PeekabooAgentService(services: Self.services(browser: root))
        let sessionID = "overlapping-indeterminate-cleanup"

        await #expect(throws: AgentRemoteBrowserOpenFixtureError.self) {
            _ = try await agent.browserClient(forAgentSessionID: sessionID)
        }
        root.failNextOpenIndeterminately = true
        let recoveryBarrier = SequenceBarrier()
        root.openBarrier = recoveryBarrier
        let firstEnd = Task { @MainActor in
            await agent.endBrowserClient(forAgentSessionID: sessionID)
        }
        await recoveryBarrier.waitUntilBlocked()
        let releaseFirstEnd = Task { @MainActor in
            await recoveryBarrier.release()
        }
        #expect(root.openCount == 2)

        let overlappingEnd = await agent.endBrowserClient(forAgentSessionID: sessionID)
        await releaseFirstEnd.value
        #expect(await !firstEnd.value)
        #expect(!overlappingEnd)
        #expect(root.openCount == 2)
        #expect(root.children.isEmpty)
        #expect(agent.remoteBrowserOpeningTasks[sessionID] != nil)
        #expect(agent.remoteBrowserOpeningSessionID == sessionID)
        #expect(agent.remoteBrowserEndingTasks.isEmpty)
        #expect(agent.remoteBrowserCleanupDebt == [sessionID])
        #expect(agent.browserCleanupDebtPending)

        #expect(await agent.drainBrowserCleanupDebt())
        #expect(root.openCount == 3)
        #expect(root.children.count == 1)
        #expect(root.children[0].endCount == 1)
        #expect(agent.remoteBrowserClients.isEmpty)
        #expect(agent.remoteBrowserCapabilities.isEmpty)
        #expect(agent.remoteBrowserOpeningTasks.isEmpty)
        #expect(agent.remoteBrowserOpeningSessionID == nil)
        #expect(agent.remoteBrowserEndingTasks.isEmpty)
        #expect(agent.remoteBrowserCleanupDebt.isEmpty)
        #expect(!agent.browserCleanupDebtPending)
    }

    @Test
    func `remote Agent deletion and ephemeral completion end their exact scoped children`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekabooRemoteAgentBrowser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionManager = try AgentSessionManager(sessionDirectory: directory)
        let persistentID = "persistent-session"
        let now = Date()
        try sessionManager.saveSession(AgentSession(
            id: persistentID,
            modelName: "test-model",
            messages: [.user("Test session")],
            metadata: SessionMetadata(),
            createdAt: now,
            updatedAt: now))
        let root = AgentRemoteBrowserRoot()
        let agent = try PeekabooAgentService(
            services: Self.services(browser: root),
            sessionManager: sessionManager)

        let persistent = try await agent.browserClient(forAgentSessionID: persistentID)
        let persistentChild = try #require(persistent as? AgentRemoteScopedBrowserChild)
        try await agent.deleteSession(id: persistentID)
        #expect(persistentChild.endCount == 1)
        #expect(agent.remoteBrowserClients[persistentID] == nil)

        let ephemeralID = "ephemeral-session"
        let ephemeral = try await agent.browserClient(forAgentSessionID: ephemeralID)
        let ephemeralChild = try #require(ephemeral as? AgentRemoteScopedBrowserChild)
        let context = PeekabooAgentService.SessionContext(
            id: ephemeralID,
            isPersistent: false,
            messages: [],
            createdAt: now,
            executionStart: now,
            metadata: SessionMetadata(),
            modelIdentity: .init(
                displayName: "test-model",
                selection: nil,
                endpointIdentity: nil,
                providerIdentity: nil),
            storedToolExecutionPolicy: .backgroundOnly,
            toolExecutionPolicy: .backgroundOnly,
            provider: nil,
            executionGeneration: nil)
        #expect(await agent.endEphemeralBrowserClientIfNeeded(context))
        #expect(ephemeralChild.endCount == 1)
        #expect(agent.remoteBrowserClients[ephemeralID] == nil)
        #expect(root.rootExecuteCount == 0)
    }

    @Test
    func `in flight Agent execution cannot reacquire a local browser child after deletion`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekabooLocalAgentDeleteRace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionManager = try AgentSessionManager(sessionDirectory: directory)
        let sessionID = "local-delete-race"
        let now = Date()
        try sessionManager.saveSession(AgentSession(
            id: sessionID,
            modelName: "test-model",
            messages: [.user("Test session")],
            metadata: SessionMetadata(),
            createdAt: now,
            updatedAt: now))
        var providerCount = 0
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            providerCount += 1
            return Self.exactSession(manager: MockBrowserMCPManager())
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let agent = try PeekabooAgentService(
            services: Self.services(browser: root),
            sessionManager: sessionManager)
        let executionGeneration = try agent.beginAgentSessionExecution(for: sessionID)
        _ = try await agent.browserClient(
            forAgentSessionID: sessionID,
            executionGeneration: executionGeneration)
        let resumeBarrier = SequenceBarrier()
        let execution = Task { @MainActor in
            defer {
                agent.finishAgentSessionExecution(
                    sessionID: sessionID,
                    executionGeneration: executionGeneration)
            }
            await resumeBarrier.block()
            return try await agent.browserClient(
                forAgentSessionID: sessionID,
                executionGeneration: executionGeneration)
        }
        await resumeBarrier.waitUntilBlocked()

        try await agent.deleteSession(id: sessionID)

        #expect(pool.isEmpty)
        #expect(providerCount == 1)
        #expect(agent.agentSessionDeletionTombstones[sessionID]?.phase == .deleted)
        await resumeBarrier.release()
        await #expect(throws: BrowserMCPConnectionError.sessionEnded) {
            _ = try await execution.value
        }
        #expect(pool.isEmpty)
        #expect(providerCount == 1)
        #expect(agent.agentSessionDeletionTombstones[sessionID] == nil)
    }

    @Test
    func `in flight Agent execution cannot reacquire a remote browser child after deletion`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekabooRemoteAgentDeleteRace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionManager = try AgentSessionManager(sessionDirectory: directory)
        let sessionID = "remote-delete-race"
        let now = Date()
        try sessionManager.saveSession(AgentSession(
            id: sessionID,
            modelName: "test-model",
            messages: [.user("Test session")],
            metadata: SessionMetadata(),
            createdAt: now,
            updatedAt: now))
        let root = AgentRemoteBrowserRoot()
        let agent = try PeekabooAgentService(
            services: Self.services(browser: root),
            sessionManager: sessionManager)
        let executionGeneration = try agent.beginAgentSessionExecution(for: sessionID)
        _ = try await agent.browserClient(
            forAgentSessionID: sessionID,
            executionGeneration: executionGeneration)
        let resumeBarrier = SequenceBarrier()
        let execution = Task { @MainActor in
            defer {
                agent.finishAgentSessionExecution(
                    sessionID: sessionID,
                    executionGeneration: executionGeneration)
            }
            await resumeBarrier.block()
            return try await agent.browserClient(
                forAgentSessionID: sessionID,
                executionGeneration: executionGeneration)
        }
        await resumeBarrier.waitUntilBlocked()

        try await agent.deleteSession(id: sessionID)

        #expect(root.openCount == 1)
        #expect(root.children[0].endCount == 1)
        #expect(agent.agentSessionDeletionTombstones[sessionID]?.phase == .deleted)
        await resumeBarrier.release()
        await #expect(throws: BrowserMCPConnectionError.sessionEnded) {
            _ = try await execution.value
        }
        #expect(root.openCount == 1)
        #expect(agent.remoteBrowserClients.isEmpty)
        #expect(agent.agentSessionDeletionTombstones[sessionID] == nil)
    }

    @Test
    func `unrelated cleanup drain cannot acknowledge a deletion before its own cleanup attempt`() throws {
        let agent = try PeekabooAgentService(services: PeekabooServices())
        let sessionID = "cleanup-not-started"
        let claims = agent.installAgentSessionDeletionTombstones(for: [sessionID])
        let deletionGeneration = try #require(claims[sessionID])
        agent.markAgentSessionStorageDeleted(
            sessionID: sessionID,
            deletionGeneration: deletionGeneration)

        agent.recordDrainedAgentSessionBrowserCleanup()

        #expect(agent.agentSessionDeletionTombstones[sessionID] != nil)
        agent.recordAgentSessionBrowserCleanup(
            sessionID: sessionID,
            deletionGeneration: deletionGeneration,
            confirmed: true)
        #expect(agent.agentSessionDeletionTombstones[sessionID] == nil)
    }

    @Test(arguments: [false, true])
    func `invalid Agent step budget releases its execution generation`(streaming: Bool) async throws {
        let agent = try PeekabooAgentService(services: PeekabooServices())
        let sessionID = "invalid-step-budget"
        let executionGeneration = try agent.beginAgentSessionExecution(for: sessionID)
        let now = Date()
        let context = PeekabooAgentService.SessionContext(
            id: sessionID,
            isPersistent: true,
            messages: [],
            createdAt: now,
            executionStart: now,
            metadata: SessionMetadata(),
            modelIdentity: .init(
                displayName: "test-model",
                selection: nil,
                endpointIdentity: nil,
                providerIdentity: nil),
            storedToolExecutionPolicy: .backgroundOnly,
            toolExecutionPolicy: .backgroundOnly,
            provider: nil,
            executionGeneration: executionGeneration)

        await #expect(throws: PeekabooError.self) {
            if streaming {
                _ = try await agent.executeWithStreaming(
                    context: context,
                    model: .anthropic(.sonnet45),
                    maxSteps: 0,
                    streamingDelegate: StreamingEventDelegate { _ in })
            } else {
                _ = try await agent.executeWithoutStreaming(
                    context: context,
                    model: .anthropic(.sonnet45),
                    maxSteps: 0)
            }
        }

        #expect(agent.agentSessionExecutionGenerations[sessionID] == nil)
        let claims = agent.installAgentSessionDeletionTombstones(for: [sessionID])
        let deletionGeneration = try #require(claims[sessionID])
        agent.markAgentSessionStorageDeleted(
            sessionID: sessionID,
            deletionGeneration: deletionGeneration)
        agent.recordAgentSessionBrowserCleanup(
            sessionID: sessionID,
            deletionGeneration: deletionGeneration,
            confirmed: true)
        #expect(agent.agentSessionDeletionTombstones[sessionID] == nil)
    }

    @Test(arguments: AgentDeletionSweep.allCases)
    func `Agent deletion sweeps tombstone every session before awaiting browser cleanup`(
        sweep: AgentDeletionSweep) async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekabooAgentDeleteSweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionManager = try AgentSessionManager(sessionDirectory: directory)
        let firstID = "sweep-first"
        let secondID = "sweep-second"
        let firstDate = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let secondDate = firstDate.addingTimeInterval(-60)
        for (sessionID, updatedAt) in [(firstID, firstDate), (secondID, secondDate)] {
            try sessionManager.saveSession(AgentSession(
                id: sessionID,
                modelName: "test-model",
                messages: [.user("Test session")],
                metadata: SessionMetadata(),
                createdAt: updatedAt,
                updatedAt: updatedAt))
        }
        let root = AgentRemoteBrowserRoot()
        let agent = try PeekabooAgentService(
            services: Self.services(browser: root),
            sessionManager: sessionManager)
        let firstGeneration = try agent.beginAgentSessionExecution(for: firstID)
        let secondGeneration = try agent.beginAgentSessionExecution(for: secondID)
        _ = try await agent.browserClient(
            forAgentSessionID: firstID,
            executionGeneration: firstGeneration)
        _ = try await agent.browserClient(
            forAgentSessionID: secondID,
            executionGeneration: secondGeneration)
        let cleanupBarrier = SequenceBarrier()
        root.children[0].endBarrier = cleanupBarrier
        let deletion = Task { @MainActor in
            switch sweep {
            case .clearAll:
                try await agent.clearAllSessions()
            case .expiration:
                await agent.cleanup()
            }
        }
        await cleanupBarrier.waitUntilBlocked()

        #expect(agent.agentSessionDeletionTombstones[firstID] != nil)
        #expect(agent.agentSessionDeletionTombstones[secondID] != nil)
        await #expect(throws: BrowserMCPConnectionError.sessionEnded) {
            _ = try await agent.browserClient(
                forAgentSessionID: secondID,
                executionGeneration: secondGeneration)
        }

        await cleanupBarrier.release()
        try await deletion.value
        agent.finishAgentSessionExecution(
            sessionID: firstID,
            executionGeneration: firstGeneration)
        agent.finishAgentSessionExecution(
            sessionID: secondID,
            executionGeneration: secondGeneration)
        #expect(root.openCount == 2)
        #expect(root.children.allSatisfy { $0.endCount == 1 })
        #expect(agent.agentSessionDeletionTombstones.isEmpty)
        #expect(sessionManager.listSessions().isEmpty)
    }

    @Test
    func `Agent deletion drains retained browser cleanup before releasing its target`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekabooAgentBrowserDebt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionManager = try AgentSessionManager(sessionDirectory: directory)
        let sessionID = "debt-session"
        let now = Date()
        try sessionManager.saveSession(AgentSession(
            id: sessionID,
            modelName: "test-model",
            messages: [.user("Test session")],
            metadata: SessionMetadata(),
            createdAt: now,
            updatedAt: now))
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: providers.removeFirst())
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let agent = try PeekabooAgentService(
            services: Self.services(browser: root),
            sessionManager: sessionManager)
        let first = try #require(await agent.browserClient(forAgentSessionID: sessionID) as? BrowserMCPService)
        _ = try await first.connect(channel: nil, browserURL: nil)
        firstProvider.removeLeavesProvider = [true, false]

        try await agent.deleteSession(id: sessionID)

        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(sessionID).json").path))
        #expect(firstProvider.removeCount == 2)
        #expect(!agent.browserCleanupDebtPending)
        #expect(root.pendingAuthenticatedSessionCleanupCount == 0)
        let second = try #require(await agent.browserClient(forAgentSessionID: "next-session") as? BrowserMCPService)
        _ = try await second.connect(channel: nil, browserURL: nil)
        #expect(secondProvider.addedConfigs.count == 1)
        await agent.endBrowserClient(forAgentSessionID: "next-session")
    }

    @Test
    func `Agent deletion reports retained cleanup debt and a later drain releases its target`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekabooAgentBrowserDebtFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionManager = try AgentSessionManager(sessionDirectory: directory)
        let sessionID = "debt-failure-session"
        let now = Date()
        try sessionManager.saveSession(AgentSession(
            id: sessionID,
            modelName: "test-model",
            messages: [.user("Test session")],
            metadata: SessionMetadata(),
            createdAt: now,
            updatedAt: now))
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: providers.removeFirst())
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let agent = try PeekabooAgentService(
            services: Self.services(browser: root),
            sessionManager: sessionManager)
        let first = try #require(await agent.browserClient(forAgentSessionID: sessionID) as? BrowserMCPService)
        _ = try await first.connect(channel: nil, browserURL: nil)
        firstProvider.removeLeavesProvider = [true, true, false]

        await #expect(throws: PeekabooError.self) {
            try await agent.deleteSession(id: sessionID)
        }

        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(sessionID).json").path))
        #expect(firstProvider.removeCount == 2)
        #expect(agent.browserCleanupDebtPending)
        #expect(root.pendingAuthenticatedSessionCleanupCount == 1)
        let second = try #require(await agent.browserClient(forAgentSessionID: "blocked-session") as? BrowserMCPService)
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await second.connect(channel: nil, browserURL: nil)
        }

        #expect(await root.retryPendingAuthenticatedSessionCleanup())
        #expect(root.pendingAuthenticatedSessionCleanupCount == 0)
        _ = try await second.connect(channel: nil, browserURL: nil)
        #expect(secondProvider.addedConfigs.count == 1)
        await agent.endBrowserClient(forAgentSessionID: "blocked-session")
    }

    @Test
    func `Agent clear all uses the final cleanup state after transient failures`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekabooAgentBrowserClearDebt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionManager = try AgentSessionManager(sessionDirectory: directory)
        let sessionID = "clear-debt-session"
        let now = Date()
        try sessionManager.saveSession(AgentSession(
            id: sessionID,
            modelName: "test-model",
            messages: [.user("Test session")],
            metadata: SessionMetadata(),
            createdAt: now,
            updatedAt: now))
        let provider = MockBrowserMCPManager()
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: provider)
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let agent = try PeekabooAgentService(
            services: Self.services(browser: root),
            sessionManager: sessionManager)
        let browser = try #require(await agent.browserClient(forAgentSessionID: sessionID) as? BrowserMCPService)
        _ = try await browser.connect(channel: nil, browserURL: nil)
        provider.removeLeavesProvider = [true, true, false]

        try await agent.clearAllSessions()

        #expect(provider.removeCount == 3)
        #expect(root.pendingAuthenticatedSessionCleanupCount == 0)
        #expect(sessionManager.listSessions().isEmpty)
    }

    @Test
    func `failed expired session deletion preserves its browser capability namespace`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekabooAgentCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let sessionManager = try AgentSessionManager(sessionDirectory: directory)
        let sessionID = "expired-session"
        let expiredAt = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        try sessionManager.saveSession(AgentSession(
            id: sessionID,
            modelName: "test-model",
            messages: [.user("Test session")],
            metadata: SessionMetadata(),
            createdAt: expiredAt,
            updatedAt: expiredAt))
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: MockBrowserMCPManager())
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let agent = try PeekabooAgentService(
            services: Self.services(browser: root),
            sessionManager: sessionManager)
        let first = try #require(await agent.browserClient(forAgentSessionID: sessionID) as? BrowserMCPService)
        let firstCapabilities = try #require(first.browserCapabilitySession)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        await agent.cleanup()

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(sessionID).json").path))
        let resumed = try #require(await agent.browserClient(forAgentSessionID: sessionID) as? BrowserMCPService)
        #expect(resumed.browserCapabilitySession === firstCapabilities)
        await agent.endBrowserClient(forAgentSessionID: sessionID)
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
            processBundleIdentifier: { _ in "com.google.Chrome" },
            processCodeSignatureValidator: { _, _, channel in .browserTestIdentity(channel: channel) },
            endpointResolver: Self.endpointResolver(),
            channelEndpointResolver: Self.channelEndpointResolver())
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
    func `Browser tool executes against a native channel receipt`() async throws {
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

        #expect(!response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("dispatched_unverified"))
        #expect(meta["dispatch_state"] == .string("dispatched"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(manager.executedTools == ["click"])
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
    func `status retains target ownership until orphan provider removal is confirmed`() async throws {
        let staging = try UploadStagingFixture()
        defer { staging.cleanup() }
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(
                manager: providers.removeFirst(),
                uploadStager: staging.stager())
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:first"))
        let second = try #require(root.authenticatedSession(named: "agent:second"))
        let connected = try await first.connect(channel: nil, browserURL: nil)
        let connectedReceipt = try #require(connected.connectionReceipt)
        let connectedEpoch = try #require(connected.providerSessionEpoch)
        let uploadRoot = try #require(firstProvider.addedConfigs.first?.env["TMPDIR"])
        firstProvider.connected = false
        firstProvider.removeLeavesProvider = [true, true, false]

        let lost = await first.status(channel: nil)
        #expect(!lost.isConnected)
        #expect(lost.observation == .indeterminate)
        #expect(lost.connectionReceipt == connectedReceipt)
        #expect(lost.providerSessionEpoch == connectedEpoch)
        #expect(firstProvider.removeCount == 1)
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await first.connect(channel: nil, browserURL: "http://127.0.0.1:9333")
        }
        #expect(firstProvider.removeCount == 2)
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await second.connect(channel: nil, browserURL: nil)
        }
        #expect(secondProvider.addedConfigs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: uploadRoot))

        let cleaned = await first.status(channel: nil)
        #expect(!cleaned.isConnected)
        #expect(cleaned.observation == .confirmed)
        #expect(cleaned.connectionReceipt == nil)
        #expect(cleaned.providerSessionEpoch == nil)
        #expect(firstProvider.removeCount == 3)
        #expect(!FileManager.default.fileExists(atPath: uploadRoot))
        _ = try await second.connect(channel: nil, browserURL: nil)
        #expect(secondProvider.addedConfigs.count == 1)
        await root.endAuthenticatedSession(named: "agent:first")
        await root.endAuthenticatedSession(named: "agent:second")
    }

    @Test
    func `pending cleanup retains capabilities and handoff authorization until confirmed`() async throws {
        let sourceProvider = MockBrowserMCPManager()
        let destinationProvider = MockBrowserMCPManager()
        let sourceManager = Self.exactSession(manager: sourceProvider)
        let destinationManager = Self.exactSession(manager: destinationProvider)
        let pool = BrowserMCPAuthenticatedSessionPool { _ in destinationManager }
        let root = BrowserMCPService(
            sessionManager: sourceManager,
            authenticatedSessionPool: pool)
        let context = MCPToolContext(
            services: Self.services(browser: root),
            executionPolicy: .unrestricted)
        sourceProvider.executeHandler = { toolName, _ in
            switch toolName {
            case "list_pages": Self.providerPageResponse(id: 7)
            case "take_snapshot": Self.providerSnapshotResponse(id: "1_0")
            default: .text("ok")
            }
        }
        let connected = try await root.connect(channel: nil, browserURL: nil)
        let receipt = try #require(connected.connectionReceipt)
        let epoch = try #require(connected.providerSessionEpoch)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.opaquePageReference(from: listed)
        let snapshotted = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try #require(
            snapshotted.structuredContent?.objectValue?["snapshot"]?.objectValue?["id"]?.stringValue)
        let authorizationID = try await root.storeConnectionHandoffAuthorization(connectionReceipt: receipt)
        sourceProvider.connected = false
        sourceProvider.removeLeavesProvider = [true, false]

        let pending = await root.status(channel: nil)
        await context.browserCapabilities.observeStatus(pending)

        #expect(!pending.isConnected)
        #expect(pending.observation == .indeterminate)
        #expect(pending.connectionReceipt == receipt)
        #expect(pending.providerSessionEpoch == epoch)
        #expect(await context.browserCapabilities.elementBinding(for: elementReference) != nil)
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:pending-cleanup",
                authorizationID: authorizationID,
                expectedConnectionReceipt: receipt)
        }

        let cleaned = await root.status(channel: nil)
        await context.browserCapabilities.observeStatus(cleaned)

        #expect(!cleaned.isConnected)
        #expect(cleaned.observation == .confirmed)
        #expect(cleaned.connectionReceipt == nil)
        #expect(cleaned.providerSessionEpoch == nil)
        #expect(await context.browserCapabilities.elementBinding(for: elementReference) == nil)
        await #expect(throws: BrowserMCPConnectionError.invalidHandoffAuthorization) {
            _ = try await root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:pending-cleanup",
                authorizationID: authorizationID,
                expectedConnectionReceipt: receipt)
        }
        #expect(await root.endAuthenticatedSession(named: "mcp:pending-cleanup"))
    }

    @Test
    func `disconnect retains cleanup debt until end and normal disconnect still releases`() async throws {
        let firstProvider = MockBrowserMCPManager()
        let secondProvider = MockBrowserMCPManager()
        let thirdProvider = MockBrowserMCPManager()
        var providers = [firstProvider, secondProvider, thirdProvider]
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: providers.removeFirst())
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let first = try #require(root.authenticatedSession(named: "agent:first"))
        let second = try #require(root.authenticatedSession(named: "agent:second"))
        let third = try #require(root.authenticatedSession(named: "agent:third"))
        _ = try await first.connect(channel: nil, browserURL: nil)
        firstProvider.removeLeavesProvider = [true, false]

        do {
            _ = try await first.disconnectWithResult()
            Issue.record("Expected unconfirmed provider cleanup to report an indeterminate disconnect")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        #expect(firstProvider.removeCount == 1)
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await second.connect(channel: nil, browserURL: nil)
        }
        #expect(await root.endAuthenticatedSession(named: "agent:first"))
        #expect(firstProvider.removeCount == 2)

        _ = try await second.connect(channel: nil, browserURL: nil)
        let disconnected = try await second.disconnectWithResult()
        #expect(!disconnected.isConnected)
        #expect(disconnected.observation == .confirmed)
        _ = try await third.connect(channel: nil, browserURL: nil)
        #expect(thirdProvider.addedConfigs.count == 1)
        await root.endAuthenticatedSession(named: "agent:second")
        await root.endAuthenticatedSession(named: "agent:third")
    }

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

        do {
            _ = try await Task { @MainActor in
                try await service.executeSequenceWithOutcome(
                    [BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "7_1"])],
                    channel: .stable,
                    connectionPolicy: .allowAutoConnect)
            }.value
            Issue.record("Expected connection cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .browserProtocol, mode: .foreground))
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Expected canonical connection failure, got \(error)")
        }
        #expect(manager.executedTools == ["list_pages"])
    }

    @Test
    func `native channel session keeps repeated mutations receipt bound`() async throws {
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

        let second = try await service.executeSequenceWithOutcome(
            [BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "7_2"])],
            channel: .stable,
            connectionPolicy: .allowAutoConnect)
        #expect(second.outcome?.state == .dispatchedUnverified)
        #expect(manager.executedTools == ["list_pages", "click", "click"])
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
    func `isolated receipt incompatible snapshot reports foreground user activation`() async throws {
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
        #expect(response.meta?.objectValue?["state"] == .string("dispatched_unverified"))
        #expect(response.meta?.objectValue?["delivery_mechanism"] == .string("browser_protocol"))
        #expect(response.meta?.objectValue?["delivery_mode"] == .string("foreground"))
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(true))
        #expect(response.meta?.objectValue?["retry_safe"] == .bool(false))
        #expect(manager.executedTools == ["take_snapshot"])
    }

    @Test
    func `raw list pages read publishes execution evidence and foreground user activation`() async throws {
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
        #expect(response.meta?.objectValue?["state"] == .string("dispatched_unverified"))
        #expect(response.meta?.objectValue?["delivery_mechanism"] == .string("browser_protocol"))
        #expect(response.meta?.objectValue?["delivery_mode"] == .string("foreground"))
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(true))
        #expect(response.meta?.objectValue?["retry_safe"] == .bool(false))
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
    func `native channel connection supports receipt bound execution`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(manager: manager, browsers: [Self.browser(pid: 821, generation: 5821)])
        let receipt = try #require(try await (session.connect(channel: .stable)).connectionReceipt)
        manager.executedTools.removeAll()

        let result = try await session.executeSequence(
            [BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "821_1"])],
            channel: .stable,
            expectedConnectionReceipt: receipt)

        #expect(!result.response.isError)
        #expect(result.connectionReceipt == receipt)
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
    func `authenticated capability session refuses isolated browser before provider dispatch`() async throws {
        let manager = MockBrowserMCPManager()
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            BrowserMCPSessionManager(
                serverName: "test-browser",
                manager: manager,
                detectedBrowsers: { _ in [] },
                processStartIdentity: { _ in nil },
                environment: ["PEEKABOO_BROWSER_MCP_ISOLATED": "1"])
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let context = try MCPToolContext(
            services: Self.services(browser: root),
            executionPolicy: .foregroundAllowed)
            .scopingBrowserSession(named: "mcp:isolated-refusal")

        let response = try await BrowserTool(context: context).execute(
            arguments: ToolArguments(raw: ["action": "connect", "channel": "stable"]))

        #expect(response.isError)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["state"] == .string("refused"))
        #expect(metadata["refusal_reason"] == .string("operation_unsupported"))
        #expect(metadata["dispatch_state"] == .string("none"))
        #expect(metadata["retry_safe"] == .bool(true))
        #expect(manager.addedConfigs.isEmpty)
        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeCount == 0)
        await root.endAuthenticatedSession(named: "mcp:isolated-refusal")
    }

    @Test
    func `authenticated capability session prefers explicit browser URL over isolated environment`() async throws {
        let manager = MockBrowserMCPManager()
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            BrowserMCPSessionManager(
                serverName: "test-browser",
                manager: manager,
                detectedBrowsers: { _ in [] },
                processStartIdentity: { _ in nil },
                endpointResolver: Self.endpointResolver(),
                environment: ["PEEKABOO_BROWSER_MCP_ISOLATED": "1"])
        }
        let root = BrowserMCPService(authenticatedSessionPool: pool)
        let context = try MCPToolContext(
            services: Self.services(browser: root),
            executionPolicy: .foregroundAllowed)
            .scopingBrowserSession(named: "mcp:explicit-endpoint")

        let response = try await BrowserTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "connect",
            "channel": "stable",
            "browser_url": "http://127.0.0.1:9222",
        ]))

        #expect(!response.isError)
        #expect(manager.addedConfigs.count == 1)
        #expect(manager.addedConfigs[0].args.contains(
            "--wsEndpoint=ws://127.0.0.1:9222/devtools/browser/browser-a"))
        #expect(!manager.addedConfigs[0].args.contains("--isolated"))
        #expect(manager.executedTools == ["list_pages"])
        await root.endAuthenticatedSession(named: "mcp:explicit-endpoint")
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
            processBundleIdentifier: { processIdentifier in
                processIdentifier == 84 ? "com.google.Chrome.canary" : "com.google.Chrome"
            },
            processCodeSignatureValidator: { _, _, channel in .browserTestIdentity(channel: channel) },
            endpointResolver: Self.endpointResolver(),
            channelEndpointResolver: Self.channelEndpointResolver())
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
        let originalReceipt = try #require(status.connectionReceipt)
        #expect(status.connectionReceipt?.browserURL == "http://127.0.0.1:9222/")
        #expect(status.connectionReceipt?.devToolsBrowserID == "browser-a")
        #expect(manager.addedConfigs[0].args.contains(
            "--wsEndpoint=ws://127.0.0.1:9222/devtools/browser/browser-a"))

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await session.connect(
                channel: .stable,
                browserURL: "http://127.0.0.1:9333")
        }
        #expect(manager.addedConfigs.count == 1)
        #expect(manager.removeCount == 0)
        #expect(manager.connected)
        #expect(await (session.status(channel: .stable)).connectionReceipt == originalReceipt)
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
    func `receipt bound endpoint validation preserves live connection on cancellation`() async throws {
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
        #expect(manager.removeCount == 0)
        #expect(manager.connected)
        await endpoints.set("browser-a", port: 9222)
        #expect(await (session.status(channel: nil)).connectionReceipt == receipt)
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
            let message = "File uploaded from \(path)."
            let malformedResourceData = try JSONSerialization.data(withJSONObject: [
                "uri": path,
                "blob": "%%%",
                "_meta": ["provider_path": path],
            ])
            let malformedResource = try JSONDecoder().decode(Resource.Content.self, from: malformedResourceData)
            return ToolResponse(
                content: [
                    .text(
                        text: message,
                        annotations: nil,
                        _meta: Metadata(additionalFields: ["provider_message": .string(message)])),
                    .resource(
                        resource: .text(
                            message,
                            uri: path,
                            _meta: Metadata(additionalFields: ["provider_path": .string(path)])),
                        annotations: nil,
                        _meta: Metadata(additionalFields: ["provider_path": .string(path)])),
                    .resourceLink(
                        uri: path,
                        name: path,
                        title: path,
                        description: path),
                    .resource(resource: malformedResource, annotations: nil, _meta: nil),
                ],
                meta: .object(["provider_message": .string(message)]),
                structuredContent: .object(["message": .string(message)]))
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
        guard case let .text(responseText, _, contentMetadata)? = response.content.first else {
            Issue.record("Expected projected upload response text")
            return
        }
        #expect(responseText.contains(source.path))
        #expect(!responseText.contains(actualStagedPath))
        #expect(contentMetadata?.fields["provider_message"]?.stringValue?.contains(source.path) == true)
        #expect(contentMetadata?.fields["provider_message"]?.stringValue?.contains(actualStagedPath) == false)
        guard case let .resource(resource, _, resourceMetadata) = response.content[1] else {
            Issue.record("Expected projected upload resource")
            return
        }
        #expect(resource.uri == source.path)
        #expect(resource.text?.contains(source.path) == true)
        #expect(resource._meta?.fields["provider_path"] == .string(source.path))
        #expect(resourceMetadata?.fields["provider_path"] == .string(source.path))
        guard case let .resourceLink(uri, name, title, description, _, _) = response.content[2] else {
            Issue.record("Expected projected upload resource link")
            return
        }
        #expect(uri == source.path)
        #expect(name == source.path)
        #expect(title == source.path)
        #expect(description == source.path)
        guard case let .resource(projectedMalformed, _, _) = response.content[3] else {
            Issue.record("Expected projected malformed upload resource")
            return
        }
        #expect(projectedMalformed.uri == source.path)
        #expect(projectedMalformed.blob?.isEmpty == true)
        #expect(projectedMalformed._meta?.fields["provider_path"] == .string(source.path))
        #expect(response.structuredContent?.objectValue?["message"]?.stringValue?.contains(source.path) == true)
        #expect(response.meta?.objectValue?["provider_message"]?.stringValue?.contains(actualStagedPath) == false)
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
    func `thrown upload provider error projects private staged path back to caller path`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write(name: "thrown.txt", contents: Data("failure".utf8))
        let manager = MockBrowserMCPManager()
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 126, generation: 9126)],
            uploadStager: fixture.stager())
        var stagedPath: String?
        manager.executeHandler = { toolName, arguments in
            guard toolName == "upload_file" else { return ToolResponse.text("ok") }
            let path = try #require(arguments["filePath"] as? String)
            stagedPath = path
            throw UploadProviderFixtureError(message: "Provider rejected staged path \(path)")
        }
        _ = try await session.connect(channel: .stable)

        do {
            _ = try await session.execute(
                toolName: "upload_file",
                arguments: ["uid": "126_1", "filePath": source.path],
                channel: .stable)
            Issue.record("Expected an indeterminate upload provider failure")
        } catch let failure as DesktopActionFailure {
            let cause = try #require(failure.causeDescription)
            #expect(cause.contains(source.path))
            #expect(try !cause.contains(#require(stagedPath)))
        }
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
        uploadStager: BrowserMCPUploadStager = .live,
        channelEndpointResolver: BrowserMCPChannelEndpointResolver? = nil) -> BrowserMCPSessionManager
    {
        let generations = Dictionary(uniqueKeysWithValues: browsers.compactMap { browser in
            browser.processStartIdentity.map { (browser.processIdentifier, $0) }
        })
        let bundles = Dictionary(uniqueKeysWithValues: browsers.map { browser in
            (browser.processIdentifier, browser.bundleIdentifier)
        })
        return BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { channel in
                browsers.filter { channel == nil || $0.channel == channel }
            },
            processStartIdentity: { generations[$0] },
            processBundleIdentifier: { bundles[$0] },
            processCodeSignatureValidator: { _, _, channel in .browserTestIdentity(channel: channel) },
            endpointResolver: self.endpointResolver(),
            channelEndpointResolver: channelEndpointResolver ?? self.channelEndpointResolver(),
            uploadStager: uploadStager,
            environment: [:])
    }

    private static func exactSession(
        manager: MockBrowserMCPManager,
        uploadStager: BrowserMCPUploadStager = .live,
        browserURL: String = "http://127.0.0.1:9222",
        browserID: String? = "browser-a",
        endpointResolver: BrowserMCPDevToolsEndpointResolver? = nil) -> BrowserMCPSessionManager
    {
        BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            endpointResolver: endpointResolver ?? BrowserMCPDevToolsEndpointResolver { url in
                guard let port = URL(string: url)?.port else {
                    throw BrowserMCPConnectionError.invalidEndpoint("missing port")
                }
                let resolvedBrowserID = browserID ?? "browser-\(port)"
                return BrowserMCPDevToolsEndpoint(
                    browserURL: "http://127.0.0.1:\(port)/",
                    webSocketDebuggerURL: "ws://127.0.0.1:\(port)/devtools/browser/\(resolvedBrowserID)",
                    browserID: resolvedBrowserID,
                    browserVersion: "Chrome/151.0",
                    protocolVersion: "1.3")
            },
            uploadStager: uploadStager,
            environment: ["PEEKABOO_BROWSER_MCP_BROWSER_URL": browserURL])
    }

    private static func services(browser: any BrowserMCPClientProviding) -> PeekabooServices {
        let base = PeekabooServices()
        return PeekabooServices(
            logging: base.logging,
            screenCapture: base.screenCapture,
            applications: base.applications,
            automation: base.automation,
            windows: base.windows,
            menu: base.menu,
            dock: base.dock,
            dialogs: base.dialogs,
            snapshots: base.snapshots,
            files: base.files,
            clipboard: base.clipboard,
            permissions: base.permissions,
            audioInput: base.audioInput,
            browser: browser,
            agent: nil,
            configuration: base.configuration,
            screens: base.screens)
    }

    private static func providerPageResponse(id: Int) -> ToolResponse {
        ToolResponse(
            content: [.text(
                text: "## Pages\n\(id): Example (https://example.test/) [selected]",
                annotations: nil,
                _meta: nil)],
            structuredContent: .object([
                "pages": .array([.object([
                    "id": .int(id),
                    "url": .string("https://example.test/"),
                    "title": .string("Example"),
                    "selected": .bool(true),
                ])]),
            ]))
    }

    private static func providerSnapshotResponse(id: String) -> ToolResponse {
        ToolResponse(
            content: [.text(
                text: "uid=\(id) button \"Continue\"",
                annotations: nil,
                _meta: nil)],
            structuredContent: .object([
                "snapshot": .object([
                    "id": .string(id),
                    "role": .string("button"),
                    "name": .string("Continue"),
                ]),
            ]))
    }

    private static func opaquePageReference(from response: ToolResponse) throws -> String {
        let pages = try #require(response.structuredContent?.objectValue?["pages"]?.arrayValue)
        return try #require(pages.first?.objectValue?["id"]?.stringValue)
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

enum AgentDeletionSweep: CaseIterable, Sendable {
    case clearAll
    case expiration
}

@MainActor
private final class AgentRemoteBrowserRoot: BrowserMCPScopedSessionOpening, @unchecked Sendable {
    var openBarrier: SequenceBarrier?
    var nextEndResults: [[Bool]] = []
    var failNextOpenIndeterminately = false
    private(set) var browserMCPScopedSessionOpenAttemptRequiresRecovery = false
    private(set) var openCount = 0
    private(set) var concurrentOpenCount = 0
    private(set) var rootExecuteCount = 0
    private(set) var children: [AgentRemoteScopedBrowserChild] = []
    private var openInProgress = false

    func openBrowserMCPScopedSession(
        handoff: BrowserMCPHandoffGrant?) async throws -> any BrowserMCPScopedSessionEnding
    {
        #expect(handoff == nil)
        guard !self.openInProgress else {
            self.concurrentOpenCount += 1
            throw AgentRemoteBrowserOpenFixtureError.concurrentOpen
        }
        self.openInProgress = true
        defer { self.openInProgress = false }
        self.openCount += 1
        if let openBarrier {
            self.openBarrier = nil
            await openBarrier.block()
        }
        if self.failNextOpenIndeterminately {
            self.failNextOpenIndeterminately = false
            self.browserMCPScopedSessionOpenAttemptRequiresRecovery = true
            throw AgentRemoteBrowserOpenFixtureError.indeterminate
        }
        self.browserMCPScopedSessionOpenAttemptRequiresRecovery = false
        let endResults = self.nextEndResults.isEmpty ? [true] : self.nextEndResults.removeFirst()
        let child = AgentRemoteScopedBrowserChild(endResults: endResults)
        self.children.append(child)
        return child
    }

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
    }

    func connect(channel _: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        await self.status(channel: nil)
    }

    func disconnect() async {}

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        self.rootExecuteCount += 1
        return .text("shared root")
    }
}

private enum AgentRemoteBrowserOpenFixtureError: Error {
    case concurrentOpen
    case indeterminate
}

@MainActor
private final class AgentClaimRecordingRemoteBrowserTransport: RemoteBrowserMCPSessionTransport, @unchecked Sendable {
    var openBarrier: SequenceBarrier?
    private(set) var openedClaimIDs: [UUID] = []
    private(set) var endedSessionIDs: [UUID] = []
    private var failsNextOpen = true

    func openSession(
        handoff: BrowserMCPHandoffGrant?,
        claimID: UUID) async throws -> RemoteBrowserMCPSessionHandle
    {
        #expect(handoff == nil)
        self.openedClaimIDs.append(claimID)
        if let openBarrier {
            self.openBarrier = nil
            await openBarrier.block()
        }
        if self.failsNextOpen {
            self.failsNextOpen = false
            throw URLError(.networkConnectionLost)
        }
        return RemoteBrowserMCPSessionHandle(sessionID: UUID())
    }

    func status(
        session _: RemoteBrowserMCPSessionHandle,
        channel _: BrowserMCPChannel?) async throws -> BrowserMCPStatus
    {
        BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
    }

    func connectWithOutcome(
        session _: RemoteBrowserMCPSessionHandle,
        channel _: BrowserMCPChannel?,
        browserURL _: String?) async throws -> DesktopActionResult<BrowserMCPStatus>
    {
        DesktopActionResult(
            payload: BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: []),
            outcome: nil)
    }

    func executeSequenceWithOutcome(
        session _: RemoteBrowserMCPSessionHandle,
        calls _: [BrowserMCPMappedCall],
        channel _: BrowserMCPChannel?,
        expectedSessionBinding _: BrowserMCPExecutionSessionBinding,
        elementPreflight _: BrowserMCPElementPreflight?) async throws -> DesktopActionResult<ToolResponse>
    {
        DesktopActionResult(payload: .text("unused"), outcome: nil)
    }

    func disconnect(session _: RemoteBrowserMCPSessionHandle) async throws {}

    func endSession(_ session: RemoteBrowserMCPSessionHandle) async throws {
        self.endedSessionIDs.append(session.sessionID)
    }
}

private final class AgentRemoteBrowserStatusProvider: ModelProvider, @unchecked Sendable {
    let modelId = "agent-remote-browser-status"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities: ModelCapabilities
    let terminalResponseBarrier: SequenceBarrier?
    private let lock = NSLock()
    private var requests = 0

    init(supportsStreaming: Bool, terminalResponseBarrier: SequenceBarrier? = nil) {
        self.capabilities = ModelCapabilities(supportsStreaming: supportsStreaming)
        self.terminalResponseBarrier = terminalResponseBarrier
    }

    var requestCount: Int {
        self.lock.withLock { self.requests }
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        let requestIndex = self.lock.withLock {
            defer { self.requests += 1 }
            return self.requests
        }
        if requestIndex == 0 {
            return ProviderResponse(
                text: "",
                finishReason: .toolCalls,
                toolCalls: [AgentToolCall(
                    id: "remote-browser-status",
                    name: "browser",
                    arguments: ["action": AnyAgentToolValue(string: "status")])])
        }
        await self.terminalResponseBarrier?.block()
        return ProviderResponse(
            text: "remote browser execution completed",
            finishReason: .stop)
    }

    func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let response = try await self.generateText(request: request)
        return AsyncThrowingStream { continuation in
            if !response.text.isEmpty {
                continuation.yield(.text(response.text))
            }
            for toolCall in response.toolCalls ?? [] {
                continuation.yield(.tool(toolCall))
            }
            continuation.yield(.done(finishReason: response.finishReason))
            continuation.finish()
        }
    }
}

@MainActor
private final class AgentLegacyRemoteBrowserRoot: BrowserMCPClientProviding, @unchecked Sendable {
    private(set) var executeCount = 0

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
    }

    func connect(channel _: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        await self.status(channel: nil)
    }

    func disconnect() async {}

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        self.executeCount += 1
        return .text("shared root")
    }
}

@MainActor
private final class AgentRemoteBrowserServices: PeekabooServiceProviding {
    let executionHost: PeekabooServiceExecutionHost = .remote
    private let base: PeekabooServices

    init(base: PeekabooServices) {
        self.base = base
    }

    var logging: any LoggingServiceProtocol {
        self.base.logging
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        self.base.desktopObservation
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.base.screenCapture
    }

    var applications: any ApplicationServiceProtocol {
        self.base.applications
    }

    var automation: any UIAutomationServiceProtocol {
        self.base.automation
    }

    var windows: any WindowManagementServiceProtocol {
        self.base.windows
    }

    var menu: any MenuServiceProtocol {
        self.base.menu
    }

    var dock: any DockServiceProtocol {
        self.base.dock
    }

    var dialogs: any DialogServiceProtocol {
        self.base.dialogs
    }

    var snapshots: any SnapshotManagerProtocol {
        self.base.snapshots
    }

    var files: any FileServiceProtocol {
        self.base.files
    }

    var clipboard: any ClipboardServiceProtocol {
        self.base.clipboard
    }

    var configuration: ConfigurationManager {
        self.base.configuration
    }

    var permissions: PermissionsService {
        self.base.permissions
    }

    var audioInput: AudioInputService {
        self.base.audioInput
    }

    var screens: any ScreenServiceProtocol {
        self.base.screens
    }

    var browser: any BrowserMCPClientProviding {
        self.base.browser
    }

    var agent: (any AgentServiceProtocol)? {
        self.base.agent
    }

    func ensureVisualizerConnection() {}
}

@MainActor
private final class AgentRemoteScopedBrowserChild: BrowserMCPScopedSessionEnding, @unchecked Sendable {
    private var endResults: [Bool]
    var endBarrier: SequenceBarrier?
    private(set) var executeCount = 0
    private(set) var endCount = 0
    private(set) var statusCount = 0

    init(endResults: [Bool]) {
        self.endResults = endResults
    }

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        self.statusCount += 1
        return BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
    }

    func connect(channel _: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        await self.status(channel: nil)
    }

    func disconnect() async {}

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        self.executeCount += 1
        return .text("scoped child")
    }

    func endBrowserMCPScopedSession() async -> Bool {
        self.endCount += 1
        if let endBarrier {
            self.endBarrier = nil
            await endBarrier.block()
        }
        return self.endResults.isEmpty ? true : self.endResults.removeFirst()
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
    var removeLeavesProvider: [Bool] = []

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
        let leavesProvider = self.removeLeavesProvider.isEmpty ? false : self.removeLeavesProvider.removeFirst()
        self.hasConfiguredServer = leavesProvider
        self.connected = leavesProvider
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

private struct UploadProviderFixtureError: LocalizedError {
    let message: String

    var errorDescription: String? {
        self.message
    }
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
    private var shouldUseTransportCancellation = false
    private var nextFailureBarrier: SequenceBarrier?
    private var scheduledCancellationRemaining: Int?
    private var scheduledCancellationBarrier: SequenceBarrier?
    private var scheduledTransportCancellation = false

    func set(_ browserID: String, port: Int) {
        self.endpoints[port] = browserID
    }

    func cancelResolution(asTransportError: Bool = false) {
        self.shouldCancelResolution = true
        self.shouldUseTransportCancellation = asTransportError
    }

    func failNextResolution(after barrier: SequenceBarrier) {
        self.nextFailureBarrier = barrier
    }

    func cancelResolution(
        afterSuccessfulResolutions count: Int,
        at barrier: SequenceBarrier,
        asTransportError: Bool = false)
    {
        self.scheduledCancellationRemaining = count
        self.scheduledCancellationBarrier = barrier
        self.scheduledTransportCancellation = asTransportError
    }

    func resolve(_ url: String) async throws -> BrowserMCPDevToolsEndpoint {
        if let failureBarrier = self.nextFailureBarrier {
            self.nextFailureBarrier = nil
            await failureBarrier.block()
            throw BrowserMCPConnectionError.connectionLost("the endpoint disappeared during validation")
        }
        if let remaining = self.scheduledCancellationRemaining,
           let cancellationBarrier = self.scheduledCancellationBarrier
        {
            if remaining == 0 {
                let useTransportCancellation = self.scheduledTransportCancellation
                self.scheduledCancellationRemaining = nil
                self.scheduledCancellationBarrier = nil
                self.scheduledTransportCancellation = false
                await cancellationBarrier.block()
                if useTransportCancellation {
                    throw URLError(.cancelled)
                }
                throw CancellationError()
            }
            self.scheduledCancellationRemaining = remaining - 1
        }
        if self.shouldCancelResolution {
            if self.shouldUseTransportCancellation {
                throw URLError(.cancelled)
            }
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

@MainActor
private final class LifecycleGateProbingBrowserClient: BrowserMCPAuthenticatedSessionEnding, @unchecked Sendable {
    private let gate: MCPToolSnapshotExecutionGate
    private(set) var acquiredLifecycleGate = false

    init(gate: MCPToolSnapshotExecutionGate) {
        self.gate = gate
    }

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
    }

    func connect(channel _: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        await self.status(channel: nil)
    }

    func disconnect() async {}

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        .text("unused")
    }

    func endAuthenticatedBrowserSession() async -> Bool {
        do {
            self.acquiredLifecycleGate = try await BrowserMCPConnectionDeadline.run(
                until: ContinuousClock.now.advanced(by: .milliseconds(100)))
            {
                try await self.gate.acquire()
                await self.gate.release()
                return true
            }
        } catch {
            self.acquiredLifecycleGate = false
        }
        return self.acquiredLifecycleGate
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

private actor CompletionFlag {
    private(set) var finished = false

    func markFinished() {
        self.finished = true
    }
}

private actor ResolutionCounter {
    private(set) var value = 0

    func record() {
        self.value += 1
    }
}

@MainActor
private final class BrowserLaneMutationCoordinator: MCPToolSnapshotMutationCoordinating, @unchecked Sendable {
    private(set) var sharedPrepareCount = 0
    private(set) var maximumConcurrentCount = 0
    private var activeIDs = Set<UUID>()

    func prepareMutation(_: MCPToolSnapshotMutationScope) throws {
        self.sharedPrepareCount += 1
    }

    func prepareConcurrentMutation(_ scope: MCPToolSnapshotMutationScope) throws {
        self.activeIDs.insert(scope.id)
        self.maximumConcurrentCount = max(self.maximumConcurrentCount, self.activeIDs.count)
    }

    func completeMutation(_ scope: MCPToolSnapshotMutationScope, succeeded _: Bool) async -> Bool {
        self.activeIDs.remove(scope.id)
        return true
    }

    func cancelMutation(_ scope: MCPToolSnapshotMutationScope) async -> Bool {
        self.activeIDs.remove(scope.id)
        return true
    }
}

@MainActor
private final class BrowserInvalidationDebtCoordinator: MCPToolSnapshotMutationCoordinating, @unchecked Sendable {
    var completionAllowed = true
    private(set) var completionAttempts = 0

    func prepareConcurrentMutation(_: MCPToolSnapshotMutationScope) throws {}

    func completeMutation(_: MCPToolSnapshotMutationScope, succeeded _: Bool) async -> Bool {
        self.completionAttempts += 1
        return self.completionAllowed
    }
}

private struct BrowserLaneDesktopMutationTool: MCPTool {
    let name = "shell"
    let description = "Desktop mutation exclusion fixture"
    let inputSchema = SchemaBuilder.object(properties: [:])
    let entries: ResolutionCounter
    let barrier: SequenceBarrier

    @MainActor
    func execute(arguments _: ToolArguments) async throws -> ToolResponse {
        await self.entries.record()
        await self.barrier.block()
        return .text("ok")
    }
}

@MainActor
private final class BlockingBrowserCompletionCoordinator: MCPToolSnapshotMutationCoordinating, @unchecked Sendable {
    let barrier: SequenceBarrier
    private var isArmed: Bool

    init(barrier: SequenceBarrier, initiallyArmed: Bool = true) {
        self.barrier = barrier
        self.isArmed = initiallyArmed
    }

    func arm() {
        self.isArmed = true
    }

    func prepareConcurrentMutation(_: MCPToolSnapshotMutationScope) throws {}

    func completeMutation(_: MCPToolSnapshotMutationScope, succeeded _: Bool) async -> Bool {
        guard self.isArmed else { return true }
        await self.barrier.block()
        return true
    }
}
