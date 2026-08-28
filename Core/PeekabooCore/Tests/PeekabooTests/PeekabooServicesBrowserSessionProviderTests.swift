import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooBridge
@testable import PeekabooCore

@MainActor
@Suite(.serialized)
struct PeekabooServicesBrowserSessionProviderTests {
    @Test
    func `Bridge bootstrap receives concrete provider and empty sessions stay provider free`() async throws {
        let child = HostBrowserProviderSpy(label: "child")
        let fixture = Self.fixture(children: [child])

        #expect(fixture.services.supportsBrowserSessionBootstrap)
        #expect(fixture.services.browserSessionBootstrapProvider != nil)
        let host = PeekabooBridgeBootstrap.makeHost(
            services: fixture.services,
            configuration: .init(
                hostKind: .inProcess,
                socketPath: "/tmp/peekaboo-browser-provider-test.sock",
                allowlistedTeams: [],
                allowlistedBundles: [],
                daemonControl: nil,
                automationActivityObserver: nil,
                allowedOperations: [
                    .browserStatus,
                    .browserConnect,
                    .browserDisconnect,
                    .browserExecute,
                    .browserSessionBootstrap,
                    .browserSessionControl,
                ],
                hostIdentity: nil,
                hostCapabilities: [],
                desktopMutationWatermarkStore: DesktopMutationWatermarkStore(),
                maxMessageBytes: 1024 * 1024,
                requestTimeoutSec: 1,
                requestDrainTimeoutSec: 1,
                screenCaptureKitOwnershipPreparer: {}))
        #expect(host.capabilities.contains(PeekabooBridgeHostCapability.browserConnectionHandoff))

        let sessionID = UUID()
        try await fixture.services.bootstrapBrowserSession(.init(
            sessionID: sessionID,
            claimID: UUID(),
            caller: Self.caller(),
            connectionReceipt: nil))
        let status = try await fixture.services.browserSessionStatus(sessionID: sessionID, channel: nil)

        #expect(status.observation == .confirmed)
        #expect(!status.isConnected)
        #expect(status.toolCount == 0)
        #expect(status.connectionReceipt == nil)
        #expect(status.providerSessionEpoch == nil)
        #expect(child.addedConfigs.isEmpty)
        #expect(fixture.factoryCount.value == 1)

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await fixture.services.browserSessionStatus(sessionID: UUID(), channel: nil)
        }
        #expect(fixture.factoryCount.value == 1)
        #expect(await fixture.services.invalidateBrowserSession(sessionID))
    }

    @Test
    func `authorized handoff preserves order epoch preflight and exact execution result`() async throws {
        let child = HostBrowserProviderSpy(label: "child")
        child.executeHandler = { toolName, _ in
            guard toolName == "take_snapshot" else { return .text("ok") }
            return ToolResponse(
                content: [.text(text: "uid=1_0 button \"Current\"", annotations: nil, _meta: nil)],
                structuredContent: .object([
                    "snapshot": .object([
                        "id": .string("1_0"),
                        "role": .string("button"),
                        "name": .string("Current"),
                    ]),
                ]))
        }
        let fixture = Self.fixture(children: [child])
        let connected = try await fixture.services.browserConnectResult(
            channel: nil,
            browserURL: Self.browserURL)
        let sourceReceipt = try #require(connected.payload.connectionReceipt)
        let sourceEpoch = try #require(connected.payload.providerSessionEpoch)
        let authorizationID = try await fixture.services.authorizeBrowserConnectionHandoff(sourceReceipt)
        fixture.events.values.removeAll()

        let sessionID = UUID()
        try await fixture.services.bootstrapBrowserSession(.init(
            sessionID: sessionID,
            claimID: UUID(),
            caller: Self.caller(),
            connectionReceipt: sourceReceipt,
            handoffAuthorizationID: authorizationID))

        #expect(fixture.events.values == [
            "root.remove",
            "child.add",
            "child.execute:list_pages",
        ])
        let scoped = try await fixture.services.browserSessionStatus(sessionID: sessionID, channel: nil)
        let scopedEpoch = try #require(scoped.providerSessionEpoch)
        #expect(scoped.observation == .confirmed)
        #expect(scoped.isConnected)
        #expect(scoped.connectionReceipt == sourceReceipt)
        #expect(scopedEpoch != sourceEpoch)

        child.executedTools.removeAll()
        child.executedArguments.removeAll()
        let request = PeekabooBridgeBrowserExecuteRequest(
            toolName: "click",
            arguments: [
                "pageId": .int(7),
                "uid": .string("1_0"),
            ],
            expectedConnectionReceipt: sourceReceipt,
            connectionPolicy: .requireExistingLiveReceipt,
            sessionID: sessionID,
            expectedProviderSessionEpoch: scopedEpoch,
            elementPreflight: .init(providerPageID: 7, providerUIDs: ["1_0"]))
        let result = try await fixture.services.browserSessionExecute(
            sessionID: sessionID,
            request: request,
            expectedConnectionReceipt: sourceReceipt)

        #expect(result.connectionReceipt == sourceReceipt)
        #expect(result.providerSessionEpoch == scopedEpoch)
        #expect(result.completedCallCount == 1)
        #expect(result.dispatchedCallCount == 1)
        #expect(result.actionFailure == nil)
        #expect(!result.response.isError)
        #expect(child.executedTools == ["take_snapshot", "click"])
        #expect(child.executedArguments.first?["pageId"] as? Int == 7)
        #expect(child.executedArguments.last?["uid"] as? String == "1_0")

        try await fixture.services.disconnectBrowserSession(sessionID)
        let disconnected = try await fixture.services.browserSessionStatus(sessionID: sessionID, channel: nil)
        #expect(disconnected.observation == .confirmed)
        #expect(!disconnected.isConnected)
        #expect(disconnected.connectionReceipt == nil)
        #expect(disconnected.providerSessionEpoch == nil)
        #expect(await fixture.services.invalidateBrowserSession(sessionID))
    }

    @Test
    func `remote Browser tool retains its exact binding until Bridge confirms provider cleanup`() async throws {
        let child = HostBrowserProviderSpy(label: "child")
        child.executeHandler = { toolName, _ in
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
                    content: [.text(
                        text: "uid=1_0 button \"Continue\"",
                        annotations: nil,
                        _meta: nil)],
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
        let fixture = Self.fixture(children: [child])
        let socketPath = "/tmp/peekaboo-browser-disconnect-confirmation-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: fixture.services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [
                .browserStatus,
                .browserConnect,
                .browserDisconnect,
                .browserExecute,
                .browserSessionBootstrap,
                .browserSessionControl,
            ],
            browserSessionBootstrapProvider: fixture.services.browserSessionBootstrapProvider)
        let authority = try PeekabooBridgeOperationReceiptAuthority(socketPath: socketPath)
        let operationSession = try await OperationReceiptSessionFixture.make(
            authority: authority,
            peer: Self.approvedPeer())
        let bridge = DirectBridgeBrowserSessionClient(
            server: server,
            authority: authority,
            operationSession: operationSession)
        let remoteRoot = RemoteBrowserMCPClient(
            client: PeekabooBridgeClient(socketPath: "/tmp/peekaboo-unused-root-\(UUID().uuidString).sock"),
            sessionTransport: PeekabooBridgeRemoteBrowserSessionTransport(client: bridge))
        let context = try await MCPToolContext(
            services: fixture.services,
            browser: remoteRoot,
            executionPolicy: .foregroundAllowed)
            .openingBrowserSession(named: "mcp:bridge-disconnect-confirmation")
        let connector = try #require(context.browser as? any BrowserMCPConnectionResultProviding)
        let connected = try await connector.connectWithOutcome(
            channel: nil,
            browserURL: Self.browserURL)
        #expect(connected.payload.connectionReceipt != nil)
        let tool = BrowserTool(context: context)

        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try #require(
            listed.structuredContent?.objectValue?["pages"]?.arrayValue?.first?
                .objectValue?["id"]?.stringValue)
        let originalStatus = await context.browser.status(channel: nil)
        let receipt = try #require(originalStatus.connectionReceipt)
        let epoch = try #require(originalStatus.providerSessionEpoch)
        child.leaveProviderAfterRemove = true

        let unconfirmed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "disconnect"]))

        #expect(unconfirmed.isError)
        #expect(Self.responseText(unconfirmed).contains("completion is unknown"))
        #expect(!Self.responseText(unconfirmed).contains("Disconnected Chrome DevTools MCP"))
        #expect(unconfirmed.meta?.objectValue?["state"] == .string("indeterminate"))
        #expect(unconfirmed.meta?.objectValue?["retry_safe"] == .bool(false))
        #expect(child.removeCount == 1)
        #expect(child.connected)
        #expect(bridge.disconnectFailureObserved)
        #expect(!bridge.disconnectReturnedOK)

        let binding = BrowserMCPExecutionSessionBinding(
            connectionReceipt: receipt,
            providerSessionEpoch: epoch)
        let retainedCapability = try await context.browserCapabilities.resolve(
            action: .snapshot,
            arguments: ToolArguments(raw: ["page_id": pageReference]),
            sessionBinding: binding)
        #expect(retainedCapability.providerPageID == 7)
        let atomicClient = try #require(context.browser as? any BrowserMCPAtomicSessionActionProviding)
        await #expect(throws: (any Error).self) {
            _ = try await atomicClient.executeSequenceWithOutcome(
                [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: ["pageId": 7])],
                channel: nil,
                expectedSessionBinding: binding,
                elementPreflight: nil)
        }
        let retainedRequest = try #require(bridge.executeRequests.last)
        #expect(retainedRequest.expectedConnectionReceipt == Self.bridgeReceipt(receipt))
        #expect(retainedRequest.expectedProviderSessionEpoch == epoch.rawValue)

        let removalAttemptsBeforeRetry = child.removeCount
        child.leaveProviderAfterRemove = false
        let confirmed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "disconnect"]))
        #expect(!confirmed.isError)
        #expect(Self.responseText(confirmed) == "Disconnected Chrome DevTools MCP.")
        #expect(child.removeCount == removalAttemptsBeforeRetry + 1)
        let disconnected = await context.browser.status(channel: nil)
        #expect(disconnected.observation == .confirmed)
        #expect(!disconnected.isConnected)
        #expect(disconnected.connectionReceipt == nil)
        #expect(disconnected.providerSessionEpoch == nil)
        let executeCount = child.executedTools.count
        let stale = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        #expect(stale.isError)
        #expect(child.executedTools.count == executeCount)
        #expect(await context.releaseSnapshotOwner())
    }

    @Test
    func `status execute and control never create an unknown provider session`() async throws {
        let fixture = Self.fixture(children: [HostBrowserProviderSpy(label: "child")])
        let unknown = UUID()

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await fixture.services.browserSessionStatus(sessionID: unknown, channel: nil)
        }
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await fixture.services.disconnectBrowserSession(unknown)
        }
        let receipt = PeekabooBridgeBrowserConnectionReceipt(
            browserURL: Self.browserURL,
            webSocketDebuggerURL: Self.webSocketURL,
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let request = PeekabooBridgeBrowserExecuteRequest(
            toolName: "list_pages",
            arguments: [:],
            expectedConnectionReceipt: receipt,
            connectionPolicy: .requireExistingLiveReceipt,
            sessionID: unknown,
            expectedProviderSessionEpoch: UUID())
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await fixture.services.browserSessionExecute(
                sessionID: unknown,
                request: request,
                expectedConnectionReceipt: receipt)
        }

        #expect(fixture.factoryCount.value == 0)
        #expect(fixture.root.existingAuthenticatedSession(named: "bridge:\(unknown.uuidString.lowercased())") == nil)
    }

    @Test
    func `indeterminate cleanup returns false and retains the exact session for retry`() async throws {
        let child = HostBrowserProviderSpy(label: "child")
        let fixture = Self.fixture(children: [child])
        let sessionID = UUID()
        try await fixture.services.bootstrapBrowserSession(.init(
            sessionID: sessionID,
            claimID: UUID(),
            caller: Self.caller(),
            connectionReceipt: nil))
        _ = try await fixture.services.browserSessionConnect(
            sessionID: sessionID,
            channel: nil,
            browserURL: Self.browserURL)
        child.leaveProviderAfterRemove = true

        #expect(await fixture.services.invalidateBrowserSession(sessionID) == false)
        #expect(child.removeCount == 1)
        child.leaveProviderAfterRemove = false
        #expect(await fixture.services.invalidateBrowserSession(sessionID))
        #expect(child.removeCount == 2)
        #expect(await fixture.services.invalidateBrowserSession(sessionID))
    }

    @Test
    func `host reaper releases an abandoned child and its exact target without another Bridge request`() async throws {
        let child = HostBrowserProviderSpy(label: "child")
        let fixture = Self.fixture(children: [child])
        let caller = Self.caller()
        let life = HostBrowserOwnerLife(
            startIdentity: caller.process.processStartIdentity,
            presence: true)
        let socketPath = "/tmp/peekaboo-browser-target-reaper-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: fixture.services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [
                .browserStatus,
                .browserConnect,
                .browserDisconnect,
                .browserExecute,
                .browserSessionBootstrap,
                .browserSessionControl,
            ],
            hostIdentity: nil,
            servingSocketPath: socketPath,
            screenCaptureKitProcessCapabilityRegistrar: {},
            screenCaptureKitOwnershipPreparer: {},
            processStartIdentityProvider: { _ in life.startIdentity },
            processPresenceProvider: { _ in life.presence },
            browserSessionBootstrapProvider: fixture.services.browserSessionBootstrapProvider)
        #expect(server.supportsBrowserHandoffMaintenance)
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server)
        await host.setBrowserHandoffMaintenanceIntervalForTesting(milliseconds: 10)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let response = try await server.browserHandoffGrantRegistry.bootstrap(
            request: .init(claimID: UUID()),
            authority: PeekabooBridgeOperationReceiptAuthority(
                socketPath: "/tmp/peekaboo-browser-target-reaper-authority-\(UUID().uuidString).sock"),
            caller: caller)
        _ = try await fixture.services.browserSessionConnect(
            sessionID: response.sessionID,
            channel: nil,
            browserURL: Self.browserURL)
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.root.connectWithOutcome(channel: nil, browserURL: Self.browserURL)
        }

        life.presence = false
        let sessionName = "bridge:\(response.sessionID.uuidString.lowercased())"
        #expect(await Self.waitUntil {
            child.removeCount == 1 && fixture.root.existingAuthenticatedSession(named: sessionName) == nil
        })
        _ = try await fixture.root.connectWithOutcome(channel: nil, browserURL: Self.browserURL)
        await fixture.root.disconnect()
        #expect(await host.stop() == .stopped)
    }

    @Test
    func `discarded authorization cannot bootstrap or create a session`() async throws {
        let child = HostBrowserProviderSpy(label: "child")
        let fixture = Self.fixture(children: [child])
        let connected = try await fixture.services.browserConnectResult(
            channel: nil,
            browserURL: Self.browserURL)
        let receipt = try #require(connected.payload.connectionReceipt)
        let authorizationID = try await fixture.services.authorizeBrowserConnectionHandoff(receipt)
        await fixture.services.discardBrowserConnectionHandoffAuthorization(authorizationID)
        let sessionID = UUID()

        await #expect(throws: BrowserMCPConnectionError.invalidHandoffAuthorization) {
            try await fixture.services.bootstrapBrowserSession(.init(
                sessionID: sessionID,
                claimID: UUID(),
                caller: Self.caller(),
                connectionReceipt: receipt,
                handoffAuthorizationID: authorizationID))
        }
        #expect(fixture.root.existingAuthenticatedSession(named: "bridge:\(sessionID.uuidString.lowercased())") == nil)
        #expect(child.addedConfigs.isEmpty)
        await fixture.root.disconnect()
    }

    @Test
    func `concurrent authorization capture cannot exceed bounded root storage`() async throws {
        let fixture = Self.fixture(children: [])
        let connected = try await fixture.services.browserConnectResult(
            channel: nil,
            browserURL: Self.browserURL)
        let receipt = try #require(connected.payload.connectionReceipt)
        await fixture.authorizationBarrier.arm()
        let tasks = (0..<129).map { _ in
            Task { @MainActor in
                do {
                    return try await Result<UUID, BrowserMCPConnectionError>.success(
                        fixture.root.storeConnectionHandoffAuthorization(
                            connectionReceipt: Self.runtimeReceipt(receipt)))
                } catch let error as BrowserMCPConnectionError {
                    return .failure(error)
                } catch {
                    Issue.record("Unexpected authorization error: \(error)")
                    return .failure(.connectionLost(error.localizedDescription))
                }
            }
        }
        await fixture.authorizationBarrier.waitUntilBlocked()
        await Task.yield()
        await Task.yield()
        await fixture.authorizationBarrier.release()
        var authorizationIDs: [UUID] = []
        var capacityFailures = 0
        for task in tasks {
            switch await task.value {
            case let .success(authorizationID):
                authorizationIDs.append(authorizationID)
            case .failure(.handoffAuthorizationCapacityExceeded):
                capacityFailures += 1
            case let .failure(error):
                Issue.record("Unexpected authorization result: \(error)")
            }
        }

        #expect(authorizationIDs.count == 128)
        #expect(Set(authorizationIDs).count == 128)
        #expect(capacityFailures == 1)
        for authorizationID in authorizationIDs {
            fixture.root.discardConnectionHandoffAuthorization(authorizationID)
        }
        await fixture.root.disconnect()
    }

    private static let browserURL = "http://127.0.0.1:9222/"
    private static let webSocketURL = "ws://127.0.0.1:9222/devtools/browser/browser-a"

    private struct Fixture {
        let services: PeekabooServices
        let root: BrowserMCPService
        let events: HostBrowserEventLog
        let factoryCount: HostBrowserFactoryCount
        let authorizationBarrier: HostAuthorizationBarrier
    }

    private static func fixture(children: [HostBrowserProviderSpy]) -> Fixture {
        let events = HostBrowserEventLog()
        let authorizationBarrier = HostAuthorizationBarrier()
        let rootProvider = HostBrowserProviderSpy(label: "root", events: events)
        for child in children {
            child.events = events
        }
        let rootManager = self.manager(provider: rootProvider, authorizationBarrier: authorizationBarrier)
        var childManagers = children.map {
            self.manager(provider: $0, authorizationBarrier: HostAuthorizationBarrier())
        }
        let factoryCount = HostBrowserFactoryCount()
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            factoryCount.value += 1
            return childManagers.removeFirst()
        }
        let root = BrowserMCPService(
            sessionManager: rootManager,
            authenticatedSessionPool: pool)
        return Fixture(
            services: self.services(browser: root),
            root: root,
            events: events,
            factoryCount: factoryCount,
            authorizationBarrier: authorizationBarrier)
    }

    private static func manager(
        provider: HostBrowserProviderSpy,
        authorizationBarrier: HostAuthorizationBarrier) -> BrowserMCPSessionManager
    {
        let browserURL = self.browserURL
        let webSocketURL = self.webSocketURL
        return BrowserMCPSessionManager(
            serverName: provider.label,
            manager: provider,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { rawURL in
                await authorizationBarrier.blockIfArmed()
                guard BrowserLoopbackEndpoint(browserURL: rawURL)?.canonicalBrowserURL == browserURL else {
                    throw BrowserMCPConnectionError.invalidEndpoint("unexpected endpoint")
                }
                return BrowserMCPDevToolsEndpoint(
                    browserURL: browserURL,
                    webSocketDebuggerURL: webSocketURL,
                    browserID: "browser-a",
                    browserVersion: "Chrome/151.0",
                    protocolVersion: "1.3")
            },
            environment: [:])
    }

    private static func services(browser: BrowserMCPService) -> PeekabooServices {
        let base = PeekabooServices(initializeAgentService: false)
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

    private static func caller() -> PeekabooBridgeBrowserSessionCaller {
        PeekabooBridgeBrowserSessionCaller(
            operationClientInstanceID: UUID(),
            process: .init(
                processIdentifier: 501,
                processStartIdentity: 1501,
                codeSignatureHash: "test-signature"),
            processIdentifierVersion: 501,
            effectiveUserIdentifier: 501,
            bundleIdentifier: "test.browser.provider",
            teamIdentifier: "TESTTEAM")
    }

    private static func approvedPeer() throws -> PeekabooBridgePeer {
        let base = try OperationReceiptSessionFixture.currentPeer()
        guard let identity = base.liveIdentity else { throw HostBrowserTestFailure() }
        return PeekabooBridgePeer(
            liveIdentity: identity,
            bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
            teamIdentifier: "FWJYW4S8P8")
    }

    private static func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: () -> Bool) async -> Bool
    {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    private static func runtimeReceipt(
        _ receipt: PeekabooBridgeBrowserConnectionReceipt) -> BrowserMCPConnectionReceipt
    {
        BrowserMCPConnectionReceipt(
            channel: receipt.channel.flatMap(BrowserMCPChannel.init(rawValue:)),
            processIdentifier: receipt.processIdentifier,
            processStartIdentity: receipt.processStartIdentity,
            bundleIdentifier: receipt.bundleIdentifier,
            browserURL: receipt.browserURL,
            webSocketDebuggerURL: receipt.webSocketDebuggerURL,
            devToolsBrowserID: receipt.devToolsBrowserID,
            browserVersion: receipt.browserVersion,
            protocolVersion: receipt.protocolVersion)
    }

    private static func bridgeReceipt(
        _ receipt: BrowserMCPConnectionReceipt) -> PeekabooBridgeBrowserConnectionReceipt
    {
        PeekabooBridgeBrowserConnectionReceipt(
            channel: receipt.channel?.rawValue,
            processIdentifier: receipt.processIdentifier,
            processStartIdentity: receipt.processStartIdentity,
            bundleIdentifier: receipt.bundleIdentifier,
            browserURL: receipt.browserURL,
            webSocketDebuggerURL: receipt.webSocketDebuggerURL,
            devToolsBrowserID: receipt.devToolsBrowserID,
            browserVersion: receipt.browserVersion,
            protocolVersion: receipt.protocolVersion)
    }

    private static func responseText(_ response: ToolResponse) -> String {
        guard case let .text(text, _, _)? = response.content.first else { return "" }
        return text
    }
}

@MainActor
private final class DirectBridgeBrowserSessionClient: PeekabooBridgeBrowserSessionClientProviding,
    @unchecked Sendable
{
    private let server: PeekabooBridgeServer
    private let authority: PeekabooBridgeOperationReceiptAuthority
    private let operationSession: OperationReceiptSessionFixture
    private var sequence: UInt64 = 0
    private(set) var disconnectFailureObserved = false
    private(set) var disconnectReturnedOK = false
    private(set) var executeRequests: [PeekabooBridgeBrowserExecuteRequest] = []

    init(
        server: PeekabooBridgeServer,
        authority: PeekabooBridgeOperationReceiptAuthority,
        operationSession: OperationReceiptSessionFixture)
    {
        self.server = server
        self.authority = authority
        self.operationSession = operationSession
    }

    func browserSessionBootstrap(
        receiptBundle: PeekabooBridgeOperationReceiptBundle?,
        claimID: UUID) async throws -> PeekabooBridgeBrowserSessionBootstrapResponse
    {
        let handled = try await self.handle(.browserSessionBootstrap(.init(
            receiptBundle: receiptBundle,
            claimID: claimID)))
        guard case let .browserSessionBootstrap(response) = handled.response else {
            return try Self.throwUnexpected(handled.response)
        }
        return response
    }

    func browserStatus(channel: String?, sessionID: UUID?) async throws -> PeekabooBridgeBrowserStatus {
        let handled = try await self.handle(.browserStatus(.init(channel: channel, sessionID: sessionID)))
        guard case let .browserStatus(status) = handled.response else {
            return try Self.throwUnexpected(handled.response)
        }
        return status
    }

    func browserConnectResult(
        sessionID: UUID,
        channel: String?,
        browserURL: String?) async throws -> DesktopActionResult<PeekabooBridgeBrowserStatus>
    {
        let handled = try await self.handle(.projectedAction(.init(request: .browserConnect(.init(
            channel: channel,
            browserURL: browserURL,
            sessionID: sessionID)))))
        guard case let .browserStatus(status) = handled.response else {
            return try Self.throwUnexpected(handled.response)
        }
        return DesktopActionResult(payload: status, outcome: handled.outcome)
    }

    func browserExecuteResult(_ request: PeekabooBridgeBrowserExecuteRequest) async throws
        -> DesktopActionResult<PeekabooBridgeBrowserToolResponse>
    {
        self.executeRequests.append(request)
        let handled = try await self.handle(.browserExecute(request))
        guard case let .browserToolResponse(response) = handled.response else {
            return try Self.throwUnexpected(handled.response)
        }
        return DesktopActionResult(payload: response, outcome: handled.outcome)
    }

    func browserSessionDisconnect(_ sessionID: UUID) async throws {
        do {
            let handled = try await self.handle(.browserSessionControl(.init(
                sessionID: sessionID,
                action: .disconnect)))
            if case .ok = handled.response {
                self.disconnectReturnedOK = true
            }
            try Self.requireOK(handled.response)
        } catch {
            self.disconnectFailureObserved = true
            throw error
        }
    }

    func browserSessionEnd(_ sessionID: UUID) async throws {
        let handled = try await self.handle(.browserSessionControl(.init(
            sessionID: sessionID,
            action: .end)))
        try Self.requireOK(handled.response)
    }

    private func handle(_ request: PeekabooBridgeRequest) async throws
        -> (response: PeekabooBridgeResponse, outcome: DesktopActionOutcome?)
    {
        let payload = self.operationSession.request(
            authority: self.authority,
            sequence: self.sequence,
            request: request)
        self.sequence += 1
        let data = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(self.authority) {
            try await self.server.handleAttestedOperation(payload, peer: self.operationSession.peer)
        }
        let wire = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
        guard case let .attestedOperation(envelope) = wire else { throw HostBrowserTestFailure() }
        let response: PeekabooBridgeResponse
        let projectedOutcome: DesktopActionOutcome?
        if case let .projectedAction(projected) = envelope.response {
            response = projected.response
            projectedOutcome = projected.outcome?.outcome
        } else {
            response = envelope.response
            projectedOutcome = nil
        }
        return (response, envelope.receipt.payload.outcome?.outcome ?? projectedOutcome)
    }

    private static func throwUnexpected<T>(_ response: PeekabooBridgeResponse) throws -> T {
        if case let .error(envelope) = response {
            throw envelope
        }
        throw HostBrowserTestFailure()
    }

    private static func requireOK(_ response: PeekabooBridgeResponse) throws {
        guard case .ok = response else {
            if case let .error(envelope) = response {
                throw envelope
            }
            throw HostBrowserTestFailure()
        }
    }
}

private struct HostBrowserTestFailure: Error {}

@MainActor
private final class HostBrowserProviderSpy: BrowserMCPManaging {
    let label: String
    var events: HostBrowserEventLog?
    var connected = false
    var configured = false
    var leaveProviderAfterRemove = false
    var addedConfigs: [MCPServerConfig] = []
    var executedTools: [String] = []
    var executedArguments: [[String: Any]] = []
    var removeCount = 0
    var executeHandler: (@MainActor (String, [String: Any]) async throws -> ToolResponse)?

    init(label: String, events: HostBrowserEventLog? = nil) {
        self.label = label
        self.events = events
    }

    func hasServer(name _: String) -> Bool {
        self.configured
    }

    func isServerConnected(name _: String) async -> Bool {
        self.connected
    }

    func serverToolCount(name _: String) async -> Int {
        self.connected ? 29 : 0
    }

    func addServer(name _: String, config: MCPServerConfig) async throws {
        self.events?.values.append("\(self.label).add")
        self.addedConfigs.append(config)
        self.configured = true
        self.connected = true
    }

    func removeServer(name _: String) async {
        self.events?.values.append("\(self.label).remove")
        self.removeCount += 1
        self.configured = self.leaveProviderAfterRemove
        self.connected = self.leaveProviderAfterRemove
    }

    func executeTool(
        serverName _: String,
        toolName: String,
        arguments: [String: Any]) async throws -> ToolResponse
    {
        self.events?.values.append("\(self.label).execute:\(toolName)")
        self.executedTools.append(toolName)
        self.executedArguments.append(arguments)
        return try await self.executeHandler?(toolName, arguments) ?? .text("ok")
    }
}

@MainActor
private final class HostBrowserEventLog {
    var values: [String] = []
}

@MainActor
private final class HostBrowserFactoryCount {
    var value = 0
}

private final class HostBrowserOwnerLife: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStartIdentity: UInt64?
    private var storedPresence: Bool?

    init(startIdentity: UInt64?, presence: Bool?) {
        self.storedStartIdentity = startIdentity
        self.storedPresence = presence
    }

    var startIdentity: UInt64? {
        self.lock.withLock { self.storedStartIdentity }
    }

    var presence: Bool? {
        get { self.lock.withLock { self.storedPresence } }
        set { self.lock.withLock { self.storedPresence = newValue } }
    }
}

private actor HostAuthorizationBarrier {
    private var armed = false
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arm() {
        self.armed = true
        self.blocked = false
        self.released = false
    }

    func blockIfArmed() async {
        guard self.armed else { return }
        self.armed = false
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
