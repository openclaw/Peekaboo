import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserMCPHandoffSessionTests {
    @Test
    func `root handoff closes source before exact destination setup and mints fresh authority`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let staleCapabilities = try #require(
            fixture.root.authenticatedSession(named: "mcp:claim-a")?.browserCapabilitySession)

        let destination = try await fixture.root.transferConnection(
            toAuthenticatedSessionNamed: "mcp:claim-a",
            authorization: fixture.authorization)

        #expect(fixture.detection.calls == 0)
        #expect(await fixture.events.values == [
            "root.remove",
            "destination.add",
            "destination.execute:list_pages",
        ])
        let config = try #require(destinationProvider.addedConfigs.only)
        #expect(config.args.contains("--wsEndpoint=\(Self.webSocketURL)"))
        #expect(!config.args.contains(where: { $0.contains("9999") }))
        #expect(!config.args.contains("--auto-connect"))
        #expect(!config.args.contains("--isolated"))
        #expect(destination.browserCapabilitySession !== staleCapabilities)
        await #expect(throws: BrowserToolCapabilityError.sessionEnded) {
            try await staleCapabilities.withExclusiveOperation { true }
        }

        let status = await destination.status(channel: nil)
        #expect(status.isConnected)
        #expect(status.connectionReceipt == fixture.sourceBinding.connectionReceipt)
        #expect(status.providerSessionEpoch != fixture.sourceBinding.providerSessionEpoch)
        await fixture.root.endAuthenticatedSession(named: "mcp:claim-a")
    }

    @Test
    func `forged exact receipt refuses before validation teardown or provider setup`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let receipt = fixture.sourceBinding.connectionReceipt
        let forged = BrowserMCPConnectionReceipt(
            channel: receipt.channel,
            processIdentifier: receipt.processIdentifier,
            processStartIdentity: receipt.processStartIdentity,
            bundleIdentifier: receipt.bundleIdentifier,
            browserURL: receipt.browserURL,
            webSocketDebuggerURL: receipt.webSocketDebuggerURL,
            devToolsBrowserID: receipt.devToolsBrowserID,
            browserVersion: "Chrome/forged",
            protocolVersion: receipt.protocolVersion)

        do {
            _ = try await fixture.root.authorizeConnectionHandoff(connectionReceipt: forged)
            Issue.record("Expected a forged receipt to be refused")
        } catch let error as BrowserMCPConnectionError {
            #expect(error == .expectedConnectionReceiptMismatch)
        }
        #expect(await fixture.endpointResolver.calls == 0)
        #expect(await fixture.events.values.isEmpty)
        #expect(fixture.rootProvider.removeCount == 0)
        #expect(destinationProvider.addedConfigs.isEmpty)
        await fixture.root.disconnect()
    }

    @Test
    func `stale authorization cannot drain a reconnected same target provider generation`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        await fixture.root.disconnect()
        let reconnected = try await fixture.root.connect(channel: nil, browserURL: Self.browserURL)
        #expect(reconnected.connectionReceipt == fixture.authorization.connectionReceipt)
        #expect(reconnected.providerSessionEpoch != fixture.sourceBinding.providerSessionEpoch)
        await fixture.events.reset()
        await fixture.endpointResolver.reset()

        do {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:stale-generation",
                authorization: fixture.authorization)
            Issue.record("Expected stale source generation authorization to be refused")
        } catch let error as BrowserMCPConnectionError {
            #expect(error == .expectedProviderSessionEpochMismatch)
        }
        #expect(await fixture.endpointResolver.calls == 0)
        #expect(await fixture.events.values.isEmpty)
        #expect(destinationProvider.addedConfigs.isEmpty)
        await fixture.root.disconnect()
        await fixture.root.endAuthenticatedSession(named: "mcp:stale-generation")
    }

    @Test
    func `nonpristine destination refuses before source validation or teardown`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.configured = true
        destinationProvider.connected = true
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:occupied",
                authorization: fixture.authorization)
        }

        #expect(await fixture.endpointResolver.calls == 0)
        #expect(fixture.rootProvider.removeCount == 0)
        #expect(destinationProvider.addedConfigs.isEmpty)
        await fixture.root.disconnect()
        await fixture.root.endAuthenticatedSession(named: "mcp:occupied")
    }

    @Test
    func `concurrent copied claim stays locked while root teardown is in flight`() async throws {
        let teardownBarrier = HandoffBarrier()
        let rootProvider = HandoffProviderSpy(label: "root")
        rootProvider.removeBarrier = teardownBarrier
        let firstProvider = HandoffProviderSpy(label: "first")
        let copiedProvider = HandoffProviderSpy(label: "copied")
        let fixture = try await Self.fixture(
            rootProvider: rootProvider,
            destinationProviders: [firstProvider, copiedProvider])

        let first = Task { @MainActor in
            try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:first",
                authorization: fixture.authorization)
        }
        await teardownBarrier.waitUntilBlocked()

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:copied",
                authorization: fixture.authorization)
        }
        #expect(await fixture.endpointResolver.calls == 1)
        #expect(copiedProvider.addedConfigs.isEmpty)
        await teardownBarrier.release()
        _ = try await first.value

        await fixture.root.endAuthenticatedSession(named: "mcp:first")
        await fixture.root.endAuthenticatedSession(named: "mcp:copied")
    }

    @Test
    func `partial source teardown rolls ownership back only when the same provider is still live`() async throws {
        let rootProvider = HandoffProviderSpy(label: "root")
        rootProvider.leaveConfiguredAfterRemove = true
        rootProvider.leaveConnectedAfterRemove = true
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let fixture = try await Self.fixture(
            rootProvider: rootProvider,
            destinationProviders: [destinationProvider])

        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:retry-source",
                authorization: fixture.authorization)
        }
        #expect(destinationProvider.addedConfigs.isEmpty)
        #expect(rootProvider.connected)

        rootProvider.leaveConfiguredAfterRemove = false
        rootProvider.leaveConnectedAfterRemove = false
        let destination = try await fixture.root.transferConnection(
            toAuthenticatedSessionNamed: "mcp:retry-source",
            authorization: fixture.authorization)
        #expect(await (destination.status(channel: nil)).isConnected)
        #expect(rootProvider.removeCount == 2)
        await fixture.root.endAuthenticatedSession(named: "mcp:retry-source")
    }

    @Test
    func `indeterminate source teardown remains transition locked`() async throws {
        let rootProvider = HandoffProviderSpy(label: "root")
        rootProvider.leaveConfiguredAfterRemove = true
        rootProvider.leaveConnectedAfterRemove = false
        let firstProvider = HandoffProviderSpy(label: "first")
        let copiedProvider = HandoffProviderSpy(label: "copied")
        let fixture = try await Self.fixture(
            rootProvider: rootProvider,
            destinationProviders: [firstProvider, copiedProvider])

        do {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:source-recovery",
                authorization: fixture.authorization)
            Issue.record("Expected source recovery to be required")
        } catch let error as BrowserMCPConnectionError {
            if case .handoffRecoveryRequired = error {} else {
                Issue.record("Expected handoff recovery error, got \(error)")
            }
        }
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:copied",
                authorization: fixture.authorization)
        }
        #expect(firstProvider.addedConfigs.isEmpty)
        #expect(copiedProvider.addedConfigs.isEmpty)
        await fixture.root.endAuthenticatedSession(named: "mcp:source-recovery")
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:copied",
                authorization: fixture.authorization)
        }
        rootProvider.leaveConfiguredAfterRemove = false
        await fixture.root.endAuthenticatedSession(named: "mcp:source-recovery")
        let recovered = try await fixture.root.connect(channel: nil, browserURL: Self.browserURL)
        #expect(recovered.isConnected)
        await fixture.root.disconnect()
    }

    @Test
    func `cancelled validation leaves root untouched and allows deterministic retry`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let validationBarrier = HandoffBarrier()
        await fixture.endpointResolver.blockNext(at: validationBarrier, thenCancel: true)

        let cancelled = Task { @MainActor in
            try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:cancelled",
                authorization: fixture.authorization)
        }
        await validationBarrier.waitUntilBlocked()
        cancelled.cancel()
        await validationBarrier.release()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }
        #expect(fixture.rootProvider.removeCount == 0)
        #expect(destinationProvider.addedConfigs.isEmpty)

        let destination = try await fixture.root.transferConnection(
            toAuthenticatedSessionNamed: "mcp:cancelled",
            authorization: fixture.authorization)
        #expect(await (destination.status(channel: nil)).isConnected)
        await fixture.root.endAuthenticatedSession(named: "mcp:cancelled")
    }

    @Test
    func `cancellation after source drain rolls destination back for same claim retry`() async throws {
        let addBarrier = HandoffBarrier()
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.addBarrier = addBarrier
        destinationProvider.cancelAddAfterBarrier = true
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])

        let cancelled = Task { @MainActor in
            try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:post-drain-cancel",
                authorization: fixture.authorization)
        }
        await addBarrier.waitUntilBlocked()
        cancelled.cancel()
        await addBarrier.release()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }
        #expect(fixture.rootProvider.removeCount == 1)
        #expect(!destinationProvider.connected)

        destinationProvider.addBarrier = nil
        destinationProvider.cancelAddAfterBarrier = false
        let destination = try await fixture.root.transferConnection(
            toAuthenticatedSessionNamed: "mcp:post-drain-cancel",
            authorization: fixture.authorization)
        #expect(await (destination.status(channel: nil)).isConnected)
        #expect(fixture.rootProvider.removeCount == 1)
        await fixture.root.endAuthenticatedSession(named: "mcp:post-drain-cancel")
    }

    @Test
    func `post claim provider failure rolls back child and retries only for the same caller`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.addError = HandoffFixtureError.provider
        let copiedProvider = HandoffProviderSpy(label: "copied")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider, copiedProvider])
        let staleService = try #require(fixture.root.authenticatedSession(named: "mcp:owner"))

        await #expect(throws: HandoffFixtureError.self) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:owner",
                authorization: fixture.authorization)
        }
        #expect(fixture.rootProvider.removeCount == 1)
        #expect(!destinationProvider.connected)
        await fixture.endpointResolver.reset()

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await staleService.connect(
                channel: nil,
                browserURL: "http://127.0.0.1:9333/")
        }
        #expect(await fixture.endpointResolver.calls == 0)

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:copied",
                authorization: fixture.authorization)
        }
        #expect(await fixture.endpointResolver.calls == 0)
        #expect(copiedProvider.addedConfigs.isEmpty)

        destinationProvider.addError = nil
        let destination = try await fixture.root.transferConnection(
            toAuthenticatedSessionNamed: "mcp:owner",
            authorization: fixture.authorization)
        let status = await destination.status(channel: nil)
        #expect(status.isConnected)
        #expect(status.providerSessionEpoch != fixture.sourceBinding.providerSessionEpoch)
        #expect(fixture.rootProvider.removeCount == 1)
        await fixture.root.endAuthenticatedSession(named: "mcp:owner")
        await fixture.root.endAuthenticatedSession(named: "mcp:copied")
    }

    @Test
    func `indeterminate child cleanup stays locked until owner teardown confirms removal`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.executeError = HandoffFixtureError.provider
        destinationProvider.leaveConfiguredAfterRemove = true
        destinationProvider.leaveConnectedAfterRemove = true
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])

        do {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:destination-recovery",
                authorization: fixture.authorization)
            Issue.record("Expected destination recovery to be required")
        } catch let error as BrowserMCPConnectionError {
            if case .handoffRecoveryRequired = error {} else {
                Issue.record("Expected handoff recovery error, got \(error)")
            }
        }
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.root.connect(channel: nil, browserURL: Self.browserURL)
        }

        destinationProvider.leaveConfiguredAfterRemove = false
        destinationProvider.leaveConnectedAfterRemove = false
        await fixture.root.endAuthenticatedSession(named: "mcp:destination-recovery")
        let reconnected = try await fixture.root.connect(channel: nil, browserURL: Self.browserURL)
        #expect(reconnected.isConnected)
        await fixture.root.disconnect()
    }

    @Test
    func `native handoff revalidates generation signature and listener without browser detection`() async throws {
        let events = HandoffEventLog()
        let rootProvider = HandoffProviderSpy(label: "root")
        rootProvider.events = events
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.events = events
        let browser = DetectedBrowser(
            name: "Google Chrome",
            bundleIdentifier: ChromeChannelIdentity.stable.bundleIdentifier,
            processIdentifier: 421,
            processStartIdentity: 10421,
            version: "151.0",
            channel: .stable)
        let detection = HandoffNativeDetectionSpy(browser: browser)
        let endpoint = BrowserMCPDevToolsEndpoint(
            browserURL: Self.browserURL,
            webSocketDebuggerURL: Self.webSocketURL,
            browserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3",
            listenerIdentity: DarwinProcessLoopbackListenerIdentity(
                processIdentifier: 421,
                processStartIdentity: 10421,
                addressFamily: .ipv4,
                port: 9222,
                kernelSocketAddress: 101,
                kernelProtocolControlBlock: 102,
                kernelGeneration: 103))
        let nativeAuthority = HandoffNativeAuthoritySpy(endpoint: endpoint)
        let externalResolver = HandoffUnexpectedExternalResolverSpy()

        func manager(provider: HandoffProviderSpy) -> BrowserMCPSessionManager {
            BrowserMCPSessionManager(
                serverName: provider.label,
                manager: provider,
                detectedBrowsers: { channel in detection.results(channel: channel) },
                processStartIdentity: { processIdentifier in
                    processIdentifier == 421 ? 10421 : nil
                },
                processBundleIdentifier: { processIdentifier in
                    processIdentifier == 421 ? ChromeChannelIdentity.stable.bundleIdentifier : nil
                },
                processCodeSignatureValidator: { processIdentifier, generation, channel in
                    guard processIdentifier == 421, generation == 10421 else { return nil }
                    return .browserTestIdentity(channel: channel)
                },
                endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                    try await externalResolver.resolve(url)
                },
                channelEndpointResolver: BrowserMCPChannelEndpointResolver(
                    resolveInitial: { _, _ in await nativeAuthority.resolve() },
                    revalidate: { target, expected in
                        try await nativeAuthority.revalidate(target: target, expected: expected)
                    }),
                environment: [:])
        }

        let rootManager = manager(provider: rootProvider)
        let destinationManager = manager(provider: destinationProvider)
        let pool = BrowserMCPAuthenticatedSessionPool { _ in destinationManager }
        let root = BrowserMCPService(
            sessionManager: rootManager,
            authenticatedSessionPool: pool)
        let source = try await root.connect(channel: .stable, browserURL: nil)
        let binding = try BrowserMCPExecutionSessionBinding(
            connectionReceipt: #require(source.connectionReceipt),
            providerSessionEpoch: #require(source.providerSessionEpoch))
        detection.reset()
        await nativeAuthority.reset()
        await externalResolver.reset()
        await events.reset()

        let destination = try await root.transferConnection(
            toAuthenticatedSessionNamed: "mcp:native",
            authorization: root.authorizeConnectionHandoff(
                connectionReceipt: binding.connectionReceipt))

        #expect(detection.calls == 0)
        #expect(await nativeAuthority.revalidationCount == 4)
        #expect(await nativeAuthority.initialResolutionCount == 0)
        #expect(await externalResolver.calls == 0)
        #expect(await events.values == [
            "root.remove",
            "destination.add",
            "destination.execute:list_pages",
        ])
        let config = try #require(destinationProvider.addedConfigs.only)
        #expect(config.args.contains("--wsEndpoint=\(Self.webSocketURL)"))
        let destinationStatus = await destination.status(channel: .stable)
        #expect(destinationStatus.isConnected)
        #expect(destinationStatus.providerSessionEpoch != binding.providerSessionEpoch)
        await root.endAuthenticatedSession(named: "mcp:native")
    }

    private static let browserURL = "http://127.0.0.1:9222/"
    private static let webSocketURL = "ws://127.0.0.1:9222/devtools/browser/browser-a"

    private struct Fixture {
        let root: BrowserMCPService
        let rootProvider: HandoffProviderSpy
        let endpointResolver: HandoffEndpointResolverSpy
        let detection: HandoffDetectionSpy
        let events: HandoffEventLog
        let sourceBinding: BrowserMCPExecutionSessionBinding
        let authorization: BrowserMCPConnectionHandoffAuthorization
    }

    private static func fixture(
        rootProvider: HandoffProviderSpy = HandoffProviderSpy(label: "root"),
        destinationProviders: [HandoffProviderSpy]) async throws -> Fixture
    {
        let events = HandoffEventLog()
        rootProvider.events = events
        for provider in destinationProviders {
            provider.events = events
        }
        let endpointResolver = HandoffEndpointResolverSpy(
            endpoint: BrowserMCPDevToolsEndpoint(
                browserURL: self.browserURL,
                webSocketDebuggerURL: self.webSocketURL,
                browserID: "browser-a",
                browserVersion: "Chrome/151.0",
                protocolVersion: "1.3"))
        let detection = HandoffDetectionSpy()
        let rootManager = self.manager(
            provider: rootProvider,
            endpointResolver: endpointResolver,
            detection: detection,
            environment: [:])
        var destinationManagers = destinationProviders.map { provider in
            self.manager(
                provider: provider,
                endpointResolver: endpointResolver,
                detection: detection,
                environment: [
                    "PEEKABOO_BROWSER_MCP_BROWSER_URL": "http://127.0.0.1:9999",
                    "PEEKABOO_BROWSER_MCP_ISOLATED": "true",
                ])
        }
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            destinationManagers.removeFirst()
        }
        let root = BrowserMCPService(
            sessionManager: rootManager,
            authenticatedSessionPool: pool)
        let source = try await root.connect(channel: nil, browserURL: self.browserURL)
        let sourceBinding = try BrowserMCPExecutionSessionBinding(
            connectionReceipt: #require(source.connectionReceipt),
            providerSessionEpoch: #require(source.providerSessionEpoch))
        let authorization = try await root.authorizeConnectionHandoff(
            connectionReceipt: sourceBinding.connectionReceipt)
        await events.reset()
        await endpointResolver.reset()
        detection.reset()
        return Fixture(
            root: root,
            rootProvider: rootProvider,
            endpointResolver: endpointResolver,
            detection: detection,
            events: events,
            sourceBinding: sourceBinding,
            authorization: authorization)
    }

    private static func manager(
        provider: HandoffProviderSpy,
        endpointResolver: HandoffEndpointResolverSpy,
        detection: HandoffDetectionSpy,
        environment: [String: String]) -> BrowserMCPSessionManager
    {
        BrowserMCPSessionManager(
            serverName: provider.label,
            manager: provider,
            detectedBrowsers: { _ in
                detection.record()
                return []
            },
            processStartIdentity: { _ in nil },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                try await endpointResolver.resolve(url)
            },
            environment: environment)
    }
}

@MainActor
private final class HandoffProviderSpy: BrowserMCPManaging {
    let label: String
    var events: HandoffEventLog?
    var connected = false
    var configured = false
    var addedConfigs: [MCPServerConfig] = []
    var executedTools: [String] = []
    var removeCount = 0
    var addError: (any Error)?
    var executeError: (any Error)?
    var addBarrier: HandoffBarrier?
    var cancelAddAfterBarrier = false
    var removeBarrier: HandoffBarrier?
    var leaveConfiguredAfterRemove = false
    var leaveConnectedAfterRemove = false

    init(label: String) {
        self.label = label
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
        await self.events?.record("\(self.label).add")
        self.addedConfigs.append(config)
        await self.addBarrier?.block()
        if self.cancelAddAfterBarrier {
            try Task.checkCancellation()
        }
        if let addError {
            throw addError
        }
        self.configured = true
        self.connected = true
    }

    func removeServer(name _: String) async {
        await self.events?.record("\(self.label).remove")
        await self.removeBarrier?.block()
        self.removeCount += 1
        self.configured = self.leaveConfiguredAfterRemove
        self.connected = self.leaveConnectedAfterRemove
    }

    func executeTool(
        serverName _: String,
        toolName: String,
        arguments _: [String: Any]) async throws -> ToolResponse
    {
        await self.events?.record("\(self.label).execute:\(toolName)")
        self.executedTools.append(toolName)
        if let executeError {
            throw executeError
        }
        return .text("ok")
    }
}

private actor HandoffEndpointResolverSpy {
    let endpoint: BrowserMCPDevToolsEndpoint
    private(set) var calls = 0
    private var nextBarrier: HandoffBarrier?
    private var cancelAfterBarrier = false

    init(endpoint: BrowserMCPDevToolsEndpoint) {
        self.endpoint = endpoint
    }

    func resolve(_ url: String) async throws -> BrowserMCPDevToolsEndpoint {
        self.calls += 1
        guard BrowserLoopbackEndpoint(browserURL: url)?.canonicalBrowserURL == self.endpoint.browserURL else {
            throw BrowserMCPConnectionError.invalidEndpoint("unexpected endpoint")
        }
        if let nextBarrier = self.nextBarrier {
            self.nextBarrier = nil
            await nextBarrier.block()
            if self.cancelAfterBarrier {
                self.cancelAfterBarrier = false
                try Task.checkCancellation()
                throw CancellationError()
            }
        }
        return self.endpoint
    }

    func blockNext(at barrier: HandoffBarrier, thenCancel: Bool) {
        self.nextBarrier = barrier
        self.cancelAfterBarrier = thenCancel
    }

    func reset() {
        self.calls = 0
    }
}

@MainActor
private final class HandoffDetectionSpy {
    private(set) var calls = 0

    func record() {
        self.calls += 1
    }

    func reset() {
        self.calls = 0
    }
}

@MainActor
private final class HandoffNativeDetectionSpy {
    private let browser: DetectedBrowser
    private(set) var calls = 0

    init(browser: DetectedBrowser) {
        self.browser = browser
    }

    func results(channel: BrowserMCPChannel?) -> [DetectedBrowser] {
        self.calls += 1
        guard channel == nil || channel == self.browser.channel else { return [] }
        return [self.browser]
    }

    func reset() {
        self.calls = 0
    }
}

private actor HandoffNativeAuthoritySpy {
    let endpoint: BrowserMCPDevToolsEndpoint
    private(set) var initialResolutionCount = 0
    private(set) var revalidationCount = 0

    init(endpoint: BrowserMCPDevToolsEndpoint) {
        self.endpoint = endpoint
    }

    func resolve() -> BrowserMCPDevToolsEndpoint {
        self.initialResolutionCount += 1
        return self.endpoint
    }

    func revalidate(
        target: BrowserMCPChannelProcessTarget,
        expected: BrowserMCPDevToolsEndpoint) throws
    {
        self.revalidationCount += 1
        guard target.processIdentifier == 421,
              target.processStartIdentity == 10421,
              target.bundleIdentifier == ChromeChannelIdentity.stable.bundleIdentifier,
              expected == self.endpoint
        else {
            throw BrowserMCPConnectionError.connectionLost("native authority changed")
        }
    }

    func reset() {
        self.initialResolutionCount = 0
        self.revalidationCount = 0
    }
}

private actor HandoffUnexpectedExternalResolverSpy {
    private(set) var calls = 0

    func resolve(_: String) throws -> BrowserMCPDevToolsEndpoint {
        self.calls += 1
        throw BrowserMCPConnectionError.invalidEndpoint("external resolver must not run")
    }

    func reset() {
        self.calls = 0
    }
}

private actor HandoffEventLog {
    private(set) var values: [String] = []

    func record(_ value: String) {
        self.values.append(value)
    }

    func reset() {
        self.values.removeAll()
    }
}

private actor HandoffBarrier {
    private var isBlocked = false
    private var isReleased = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        self.isBlocked = true
        self.blockedWaiters.forEach { $0.resume() }
        self.blockedWaiters.removeAll()
        guard !self.isReleased else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard !self.isBlocked else { return }
        await withCheckedContinuation { continuation in
            self.blockedWaiters.append(continuation)
        }
    }

    func release() {
        self.isReleased = true
        self.releaseWaiters.forEach { $0.resume() }
        self.releaseWaiters.removeAll()
    }
}

private enum HandoffFixtureError: Error {
    case provider
}

extension Array {
    fileprivate var only: Element? {
        self.count == 1 ? self[0] : nil
    }
}
