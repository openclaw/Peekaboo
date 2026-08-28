import Foundation
import MCP
import PeekabooAutomationKit
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
}

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
