import Darwin
import Foundation
import MCP
import PeekabooCore
import PeekabooFoundation
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
        await release.value
        #expect(await context.uiSnapshots.getSnapshot(id: ownerSnapshot.id) == nil)
    }

    @Test
    func `production MCP contexts overlap browser mutations on distinct session gates`() async throws {
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
        let firstContext = base
            .scopingBrowserSession(named: "mcp:first")
            .replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        let secondContext = base
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
        let firstBarrier = SequenceBarrier()
        let secondBarrier = SequenceBarrier()
        firstProvider.executeHandler = { toolName, _ in
            if toolName == "navigate_page" {
                await firstBarrier.block()
            }
            return Self.providerPageResponse(id: 7)
        }
        secondProvider.executeHandler = { toolName, _ in
            if toolName == "navigate_page" {
                await secondBarrier.block()
            }
            return Self.providerPageResponse(id: 8)
        }

        let firstMutation = Task { @MainActor in
            try await firstContext.execute(
                tool: BrowserTool(context: firstContext),
                arguments: ToolArguments(raw: [
                    "action": "navigate",
                    "page_id": firstPage,
                    "url": "https://first.example/",
                ]))
        }
        await firstBarrier.waitUntilBlocked()
        let secondMutation = Task { @MainActor in
            try await secondContext.execute(
                tool: BrowserTool(context: secondContext),
                arguments: ToolArguments(raw: [
                    "action": "navigate",
                    "page_id": secondPage,
                    "url": "https://second.example/",
                ]))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(secondProvider.executedTools == ["navigate_page"])
        #expect(coordinator.sharedPrepareCount == 0)
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
        let context = MCPToolContext(
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
        let context = base
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
        let firstContext = base
            .scopingBrowserSession(named: "mcp:debt-first")
            .replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        let secondContext = base
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
        #expect(coordinator.completionAttempts == 2)

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
        #expect(coordinator.completionAttempts == 4)

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
        let coordinator = BlockingBrowserCompletionCoordinator(barrier: completionBarrier)
        let context = MCPToolContext(
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
        await firstRelease.value
        await secondRelease.value
        #expect(provider.removeCount == 1)
        #expect(await context.uiSnapshots.getSnapshot(id: ownerSnapshot.id) == nil)
    }

    @Test
    func `session teardown drains desktop mutation before removing owner`() async throws {
        let root = BrowserMCPService(authenticatedSessionPool: BrowserMCPAuthenticatedSessionPool { _ in
            Self.exactSession(manager: MockBrowserMCPManager())
        })
        let context = MCPToolContext(
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
        await release.value
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
        let context = MCPToolContext(
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
        await release.value
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
        let first = try #require(agent.browserClient(forAgentSessionID: "session-a") as? BrowserMCPService)
        let resumed = try #require(agent.browserClient(forAgentSessionID: "session-a") as? BrowserMCPService)
        let other = try #require(agent.browserClient(forAgentSessionID: "session-b") as? BrowserMCPService)
        let firstCapabilities = try #require(first.browserCapabilitySession)
        let resumedCapabilities = try #require(resumed.browserCapabilitySession)
        let otherCapabilities = try #require(other.browserCapabilitySession)

        #expect(firstCapabilities === resumedCapabilities)
        #expect(firstCapabilities !== otherCapabilities)
        await agent.endBrowserClient(forAgentSessionID: "session-a")
        let restarted = try #require(agent.browserClient(forAgentSessionID: "session-a") as? BrowserMCPService)
        let restartedCapabilities = try #require(restarted.browserCapabilitySession)
        #expect(restartedCapabilities !== firstCapabilities)
        await agent.endBrowserClient(forAgentSessionID: "session-a")
        await agent.endBrowserClient(forAgentSessionID: "session-b")
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
        let first = try #require(agent.browserClient(forAgentSessionID: sessionID) as? BrowserMCPService)
        let firstCapabilities = try #require(first.browserCapabilitySession)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        await agent.cleanup()

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(sessionID).json").path))
        let resumed = try #require(agent.browserClient(forAgentSessionID: sessionID) as? BrowserMCPService)
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
        let context = MCPToolContext(
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
        let context = MCPToolContext(
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

    func set(_ browserID: String, port: Int) {
        self.endpoints[port] = browserID
    }

    func cancelResolution(asTransportError: Bool = false) {
        self.shouldCancelResolution = true
        self.shouldUseTransportCancellation = asTransportError
    }

    func resolve(_ url: String) throws -> BrowserMCPDevToolsEndpoint {
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

    func endAuthenticatedBrowserSession() async {
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

    init(barrier: SequenceBarrier) {
        self.barrier = barrier
    }

    func prepareConcurrentMutation(_: MCPToolSnapshotMutationScope) throws {}

    func completeMutation(_: MCPToolSnapshotMutationScope, succeeded _: Bool) async -> Bool {
        await self.barrier.block()
        return true
    }
}
