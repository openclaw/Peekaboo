import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserMCPSessionManagerAuthorityValidationTests {
    @Test
    func `one deadline spans approval and MCP startup then clears late state`() async throws {
        let manager = DeadlineBrowserMCPManager()
        let browser = Self.browser(bundleIdentifier: "com.google.Chrome")
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [browser] },
            processStartIdentity: { _ in 2050 },
            processBundleIdentifier: { _ in "com.google.Chrome" },
            processCodeSignatureValidator: { _, _, channel in Self.signatureIdentity(channel) },
            // The whole target runs concurrently on the main actor. Keep enough budget for this operation to
            // enter provider startup even under the broad suite, then let the deliberately blocked provider prove
            // that the same deadline cancels and tears it down.
            connectionAttempt: { .standalone(timeout: .seconds(2)) },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { _ in Self.endpoint() },
            channelEndpointResolver: BrowserMCPChannelEndpointResolver(
                resolveInitial: { _, attempt in
                    attempt.state.markPermissionDispatchStarted()
                    return Self.endpoint()
                },
                revalidate: { _, _ in }),
            environment: [:])
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await session.connect(channel: .stable)
            Issue.record("Expected shared deadline")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        } catch {
            Issue.record("Expected canonical deadline failure, got \(error)")
        }

        #expect(started.duration(to: clock.now) < .seconds(1))
        #expect(manager.addServerCancellationCount == 1)
        #expect(manager.removeServerCount == 1)
        #expect(await (session.status(channel: .stable)).connectionReceipt == nil)
    }

    @Test
    func `one native approval probe and one MCP child connect while later checks are authority only`() async throws {
        let manager = AuthorityBrowserMCPManager()
        let initialResolutions = AuthorityCounter()
        let revalidations = AuthorityCounter()
        let resolver = BrowserMCPChannelEndpointResolver(
            resolveInitial: { _, attempt in
                initialResolutions.increment()
                attempt.state.markPermissionDispatchStarted()
                return Self.endpoint()
            },
            revalidate: { _, expected in
                revalidations.increment()
                #expect(expected == Self.endpoint())
            })
        let session = Self.session(manager: manager, resolver: resolver)

        _ = try await session.connect(channel: .stable)
        #expect(initialResolutions.value == 1)
        #expect(revalidations.value == 2)

        _ = await session.status(channel: .stable)
        _ = try await session.connect(channel: .stable)
        let receipt = try #require(await (session.status(channel: .stable)).connectionReceipt)
        _ = try await session.executeSequence(
            [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: [:])],
            channel: .stable,
            expectedConnectionReceipt: receipt)

        #expect(initialResolutions.value == 1)
        #expect(revalidations.value >= 5)
        #expect(manager.addServerCount == 1)
        #expect(manager.executedTools == ["list_pages", "take_snapshot"])
    }

    @Test
    func `implicit isolated auto connect timeout remains post dispatch indeterminate`() async {
        let manager = DeadlineBrowserMCPManager()
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            connectionAttempt: { .standalone(timeout: .milliseconds(40)) },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { _ in Self.endpoint() },
            environment: ["PEEKABOO_BROWSER_MCP_ISOLATED": "1"])
        let service = BrowserMCPService(sessionManager: session)

        do {
            _ = try await service.executeSequenceWithOutcome(
                [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: [:])],
                channel: .stable,
                connectionPolicy: .allowAutoConnect)
            Issue.record("Expected implicit MCP startup timeout")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Expected canonical post-dispatch failure, got \(error)")
        }

        #expect(manager.addServerCancellationCount == 1)
        #expect(manager.removeServerCount == 1)
    }

    @Test
    func `non Chrome detected bundle refuses before resolver or MCP`() async {
        let manager = AuthorityBrowserMCPManager()
        let initialResolutions = AuthorityCounter()
        let browser = Self.browser(bundleIdentifier: "com.apple.SafariPlatformSupport.Helper")
        let resolve: BrowserMCPChannelEndpointResolver.Resolve = { _ in
            initialResolutions.increment()
            return Self.endpoint()
        }
        let revalidate: BrowserMCPChannelEndpointResolver.Revalidate = { _, _ in }
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [browser] },
            processStartIdentity: { _ in 2050 },
            processBundleIdentifier: { _ in browser.bundleIdentifier },
            processCodeSignatureValidator: { _, _, channel in Self.signatureIdentity(channel) },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { _ in Self.endpoint() },
            channelEndpointResolver: BrowserMCPChannelEndpointResolver(resolve, revalidate: revalidate),
            environment: [:])

        do {
            _ = try await session.connect(channel: .stable)
            Issue.record("Expected bundle refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
        } catch {
            Issue.record("Expected canonical refusal, got \(error)")
        }
        #expect(initialResolutions.value == 0)
        #expect(manager.addServerCount == 0)
        #expect(manager.executedTools.isEmpty)
    }

    @Test
    func `same PID live bundle drift clears receipt and refuses leaf dispatch`() async throws {
        let manager = AuthorityBrowserMCPManager()
        let bundle = AuthorityBundleBox("com.google.Chrome")
        let session = Self.session(
            manager: manager,
            resolver: BrowserMCPChannelEndpointResolver(
                resolveInitial: { _, attempt in
                    attempt.state.markPermissionDispatchStarted()
                    return Self.endpoint()
                },
                revalidate: { _, _ in }),
            liveBundle: { _ in bundle.value })
        let receipt = try #require(try await session.connect(channel: .stable).connectionReceipt)
        manager.executedTools.removeAll()
        bundle.value = "com.apple.SafariPlatformSupport.Helper"

        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await session.executeSequence(
                [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: [:])],
                channel: .stable,
                expectedConnectionReceipt: receipt)
        }
        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeServerCount == 1)
        #expect(await (session.status(channel: .stable)).connectionReceipt == nil)
    }

    @Test
    func `exact bundle with untrusted signer refuses before endpoint or MCP dispatch`() async {
        let manager = AuthorityBrowserMCPManager()
        let initialResolutions = AuthorityCounter()
        let browser = Self.browser(bundleIdentifier: "com.google.Chrome")
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [browser] },
            processStartIdentity: { _ in 2050 },
            processBundleIdentifier: { _ in "com.google.Chrome" },
            processCodeSignatureValidator: { _, _, _ in nil },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { _ in Self.endpoint() },
            channelEndpointResolver: BrowserMCPChannelEndpointResolver(
                resolveInitial: { _, _ in
                    initialResolutions.increment()
                    return Self.endpoint()
                },
                revalidate: { _, _ in }),
            environment: [:])

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await session.connect(channel: .stable)
        }
        #expect(initialResolutions.value == 0)
        #expect(manager.addServerCount == 0)
        #expect(manager.executedTools.isEmpty)
    }

    @Test
    func `signer drift clears receipt and refuses leaf dispatch`() async throws {
        let manager = AuthorityBrowserMCPManager()
        let signer = AuthoritySignatureBox(Self.signatureIdentity(.stable))
        let session = Self.session(
            manager: manager,
            resolver: BrowserMCPChannelEndpointResolver(
                resolveInitial: { _, attempt in
                    attempt.state.markPermissionDispatchStarted()
                    return Self.endpoint()
                },
                revalidate: { _, _ in }),
            signer: { _, _, _ in signer.value })
        let receipt = try #require(try await session.connect(channel: .stable).connectionReceipt)
        manager.executedTools.removeAll()
        signer.value = Self.signatureIdentity(.stable, codeDirectoryHash: Data([2]))

        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await session.executeSequence(
                [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: [:])],
                channel: .stable,
                expectedConnectionReceipt: receipt)
        }
        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeServerCount == 1)
        #expect(await (session.status(channel: .stable)).connectionReceipt == nil)
    }

    @Test
    func `signer exec drift during listener validation refuses before leaf dispatch`() async throws {
        let manager = AuthorityBrowserMCPManager()
        let signer = AuthoritySignatureBox(Self.signatureIdentity(.stable))
        let driftArmed = AuthorityBoolBox(false)
        let session = Self.session(
            manager: manager,
            resolver: BrowserMCPChannelEndpointResolver(
                resolveInitial: { _, attempt in
                    attempt.state.markPermissionDispatchStarted()
                    return Self.endpoint()
                },
                revalidate: { _, _ in
                    if driftArmed.value {
                        signer.value = Self.signatureIdentity(.stable, codeDirectoryHash: Data([2]))
                    }
                }),
            signer: { _, _, _ in signer.value })
        let receipt = try #require(try await session.connect(channel: .stable).connectionReceipt)
        manager.executedTools.removeAll()
        driftArmed.value = true

        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await session.executeSequence(
                [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: [:])],
                channel: .stable,
                expectedConnectionReceipt: receipt)
        }
        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeServerCount == 1)
    }

    @Test
    func `same PID and port listener reopen refuses before leaf dispatch`() async throws {
        let manager = AuthorityBrowserMCPManager()
        let listener = AuthorityListenerBox(Self.listener(socket: 100))
        let resolver = BrowserMCPChannelEndpointResolver(
            resolveInitial: { _, attempt in
                attempt.state.markPermissionDispatchStarted()
                return Self.endpoint(listenerIdentity: listener.value)
            },
            revalidate: { _, expected in
                guard expected.listenerIdentity == listener.value else {
                    throw BrowserMCPConnectionError.connectionLost("listener authority changed")
                }
            })
        let session = Self.session(manager: manager, resolver: resolver)
        let receipt = try #require(try await session.connect(channel: .stable).connectionReceipt)
        manager.executedTools.removeAll()
        listener.value = Self.listener(socket: 200)

        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await session.executeSequence(
                [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: [:])],
                channel: .stable,
                expectedConnectionReceipt: receipt)
        }

        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeServerCount == 1)
        #expect(await (session.status(channel: .stable)).connectionReceipt == nil)
    }

    @Test
    func `bundle identifier case drift refuses before leaf dispatch`() async throws {
        let manager = AuthorityBrowserMCPManager()
        let bundle = AuthorityBundleBox("com.google.Chrome")
        let session = Self.session(
            manager: manager,
            resolver: BrowserMCPChannelEndpointResolver(
                resolveInitial: { _, attempt in
                    attempt.state.markPermissionDispatchStarted()
                    return Self.endpoint()
                },
                revalidate: { _, _ in }),
            liveBundle: { _ in bundle.value })
        let receipt = try #require(try await session.connect(channel: .stable).connectionReceipt)
        manager.executedTools.removeAll()
        bundle.value = "COM.GOOGLE.CHROME"

        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await session.executeSequence(
                [BrowserMCPMappedCall(toolName: "take_snapshot", arguments: [:])],
                channel: .stable,
                expectedConnectionReceipt: receipt)
        }

        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeServerCount == 1)
    }

    @Test
    func `explicit endpoint receipt cannot satisfy a later native channel connect`() async throws {
        let manager = AuthorityBrowserMCPManager()
        let nativeResolutions = AuthorityCounter()
        let browser = Self.browser(bundleIdentifier: "com.google.Chrome")
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [browser] },
            processStartIdentity: { _ in 2050 },
            processBundleIdentifier: { _ in "com.google.Chrome" },
            processCodeSignatureValidator: { _, _, channel in Self.signatureIdentity(channel) },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { _ in Self.endpoint() },
            channelEndpointResolver: BrowserMCPChannelEndpointResolver(
                resolveInitial: { _, _ in
                    nativeResolutions.increment()
                    return Self.endpoint()
                },
                revalidate: { _, _ in }),
            environment: [:])
        let original = try #require(try await session.connect(
            channel: .stable,
            browserURL: "http://127.0.0.1:9222").connectionReceipt)
        manager.executedTools.removeAll()

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await session.connect(channel: .stable)
        }

        #expect(nativeResolutions.value == 0)
        #expect(manager.addServerCount == 1)
        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeServerCount == 0)
        #expect(await (session.status(channel: .stable)).connectionReceipt == original)
    }

    @Test
    func `repeated isolated connect reuses the exact isolated session`() async throws {
        let manager = AuthorityBrowserMCPManager()
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { _ in Self.endpoint() },
            environment: ["PEEKABOO_BROWSER_MCP_ISOLATED": "1"])
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()

        let repeated = try await session.connectWithOutcome(channel: .stable)

        #expect(repeated.payload.isConnected)
        #expect(repeated.outcome?.state == .confirmedNoChange)
        #expect(manager.addServerCount == 1)
        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeServerCount == 0)
    }

    @Test
    func `isolated session cannot satisfy a later native channel request`() async throws {
        let manager = AuthorityBrowserMCPManager()
        let isolated = AuthorityBoolBox(true)
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [Self.browser(bundleIdentifier: "com.google.Chrome")] },
            processStartIdentity: { _ in 2050 },
            processBundleIdentifier: { _ in "com.google.Chrome" },
            processCodeSignatureValidator: { _, _, channel in Self.signatureIdentity(channel) },
            isolatedConnectionRequested: { isolated.value },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { _ in Self.endpoint() },
            channelEndpointResolver: BrowserMCPChannelEndpointResolver(
                resolveInitial: { _, attempt in
                    attempt.state.markPermissionDispatchStarted()
                    return Self.endpoint()
                },
                revalidate: { _, _ in }),
            environment: [:])
        let original = try #require(try await session.connect(channel: .stable).connectionReceipt)
        manager.executedTools.removeAll()
        isolated.value = false

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await session.connect(channel: .stable)
        }

        #expect(manager.addServerCount == 1)
        #expect(manager.removeServerCount == 0)
        #expect(manager.executedTools.isEmpty)
        #expect(await (session.status(channel: .stable)).connectionReceipt == original)
    }

    @Test
    func `targetless native reconnect retains the existing exact channel`() async throws {
        let manager = AuthorityBrowserMCPManager()
        let initialResolutions = AuthorityCounter()
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [Self.browser(bundleIdentifier: "com.google.Chrome")] },
            processStartIdentity: { _ in 2050 },
            processBundleIdentifier: { _ in "com.google.Chrome" },
            processCodeSignatureValidator: { _, _, channel in Self.signatureIdentity(channel) },
            preferredChannel: { .canary },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { _ in Self.endpoint() },
            channelEndpointResolver: BrowserMCPChannelEndpointResolver(
                resolveInitial: { _, attempt in
                    initialResolutions.increment()
                    attempt.state.markPermissionDispatchStarted()
                    return Self.endpoint()
                },
                revalidate: { _, _ in }),
            environment: [:])
        let original = try #require(try await session.connect(channel: .stable).connectionReceipt)
        manager.executedTools.removeAll()

        let repeated = try await session.connectWithOutcome(channel: nil)

        #expect(repeated.payload.connectionReceipt == original)
        #expect(repeated.outcome?.state == .confirmedNoChange)
        #expect(initialResolutions.value == 1)
        #expect(manager.addServerCount == 1)
        #expect(manager.removeServerCount == 0)
        #expect(manager.executedTools.isEmpty)
    }

    @Test
    func `timed out attempt cleans up before queued connection can publish`() async throws {
        let manager = OrderedCleanupBrowserMCPManager()
        let attempts = OrderedConnectionAttempts()
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            connectionAttempt: { attempts.next() },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { _ in Self.endpoint() },
            environment: [:])

        let first = Task { @MainActor in
            try await session.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        }
        await manager.waitUntilCleanupProbeStarts()
        let second = Task { @MainActor in
            try await session.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        }
        await Task.yield()
        await Task.yield()
        #expect(manager.addServerCount == 1)

        manager.releaseCleanupProbe()
        await #expect(throws: DesktopActionFailure.self) {
            _ = try await first.value
        }
        let connected = try await second.value

        #expect(connected.isConnected)
        #expect(connected.connectionReceipt == Self.externalReceipt())
        #expect(manager.addServerCount == 2)
        #expect(manager.removeServerCount == 1)
        #expect(await (session.status(channel: nil)).connectionReceipt == connected.connectionReceipt)
    }

    private static func session(
        manager: AuthorityBrowserMCPManager,
        resolver: BrowserMCPChannelEndpointResolver,
        liveBundle: @escaping BrowserMCPSessionManager.ProcessBundleIdentifierProvider = { _ in
            "com.google.Chrome"
        },
        signer: @escaping BrowserMCPSessionManager.ProcessCodeSignatureValidator = { _, _, channel in
            Self.signatureIdentity(channel)
        })
        -> BrowserMCPSessionManager
    {
        let browser = Self.browser(bundleIdentifier: "com.google.Chrome")
        return BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [browser] },
            processStartIdentity: { _ in 2050 },
            processBundleIdentifier: liveBundle,
            processCodeSignatureValidator: signer,
            endpointResolver: BrowserMCPDevToolsEndpointResolver { _ in Self.endpoint() },
            channelEndpointResolver: resolver,
            environment: [:])
    }

    private static func browser(bundleIdentifier: String) -> DetectedBrowser {
        DetectedBrowser(
            name: "Google Chrome",
            bundleIdentifier: bundleIdentifier,
            processIdentifier: 50,
            processStartIdentity: 2050,
            version: "151.0",
            channel: .stable)
    }

    private nonisolated static func endpoint(
        listenerIdentity: DarwinProcessLoopbackListenerIdentity? = nil) -> BrowserMCPDevToolsEndpoint
    {
        BrowserMCPDevToolsEndpoint(
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            browserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3",
            listenerIdentity: listenerIdentity)
    }

    private nonisolated static func listener(socket: UInt64) -> DarwinProcessLoopbackListenerIdentity {
        .init(
            processIdentifier: 50,
            processStartIdentity: 2050,
            addressFamily: .ipv4,
            port: 9222,
            kernelSocketAddress: socket,
            kernelProtocolControlBlock: socket + 1,
            kernelGeneration: socket + 2)
    }

    private nonisolated static func externalReceipt() -> BrowserMCPConnectionReceipt {
        BrowserMCPConnectionReceipt(
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
    }

    private nonisolated static func signatureIdentity(
        _ channel: ChromeChannelIdentity,
        codeDirectoryHash: Data = Data([1])) -> ChromeProcessCodeSignatureValidator.Identity
    {
        .init(
            identifier: channel.bundleIdentifier,
            teamIdentifier: ChromeProcessCodeSignatureValidator.googleChromeTeamIdentifier,
            codeDirectoryHash: codeDirectoryHash)
    }
}

@MainActor
private final class DeadlineBrowserMCPManager: BrowserMCPManaging {
    var connected = false
    var addServerCancellationCount = 0
    var removeServerCount = 0

    func hasServer(name _: String) -> Bool {
        self.connected
    }

    func isServerConnected(name _: String) async -> Bool {
        self.connected
    }

    func serverToolCount(name _: String) async -> Int {
        0
    }

    func addServer(name _: String, config _: MCPServerConfig) async throws {
        self.connected = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            self.addServerCancellationCount += 1
            throw CancellationError()
        }
    }

    func removeServer(name _: String) async {
        self.removeServerCount += 1
        self.connected = false
    }

    func executeTool(
        serverName _: String,
        toolName _: String,
        arguments _: [String: Any]) async throws -> ToolResponse
    {
        .text("unexpected")
    }
}

@MainActor
private final class AuthorityBrowserMCPManager: BrowserMCPManaging {
    var connected = false
    var addServerCount = 0
    var removeServerCount = 0
    var executedTools: [String] = []

    func hasServer(name _: String) -> Bool {
        self.connected
    }

    func isServerConnected(name _: String) async -> Bool {
        self.connected
    }

    func serverToolCount(name _: String) async -> Int {
        self.connected ? 29 : 0
    }

    func addServer(name _: String, config _: MCPServerConfig) async throws {
        self.addServerCount += 1
        self.connected = true
    }

    func removeServer(name _: String) async {
        self.removeServerCount += 1
        self.connected = false
    }

    func executeTool(
        serverName _: String,
        toolName: String,
        arguments _: [String: Any]) async throws -> ToolResponse
    {
        self.executedTools.append(toolName)
        return .text("ok")
    }
}

private final class AuthorityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}

private final class AuthorityBundleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    init(_ value: String?) {
        self.storedValue = value
    }

    var value: String? {
        get { self.lock.withLock { self.storedValue } }
        set { self.lock.withLock { self.storedValue = newValue } }
    }
}

private final class AuthorityListenerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: DarwinProcessLoopbackListenerIdentity

    init(_ value: DarwinProcessLoopbackListenerIdentity) {
        self.storedValue = value
    }

    var value: DarwinProcessLoopbackListenerIdentity {
        get { self.lock.withLock { self.storedValue } }
        set { self.lock.withLock { self.storedValue = newValue } }
    }
}

private final class AuthoritySignatureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: ChromeProcessCodeSignatureValidator.Identity?

    init(_ value: ChromeProcessCodeSignatureValidator.Identity?) {
        self.storedValue = value
    }

    var value: ChromeProcessCodeSignatureValidator.Identity? {
        get { self.lock.withLock { self.storedValue } }
        set { self.lock.withLock { self.storedValue = newValue } }
    }
}

private final class AuthorityBoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        self.storedValue = value
    }

    var value: Bool {
        get { self.lock.withLock { self.storedValue } }
        set { self.lock.withLock { self.storedValue = newValue } }
    }
}

@MainActor
private final class OrderedCleanupBrowserMCPManager: BrowserMCPManaging {
    var addServerCount = 0
    var removeServerCount = 0
    private var connected = false
    private var cleanupProbeContinuation: CheckedContinuation<Void, Never>?
    private var cleanupProbeStartedContinuation: CheckedContinuation<Void, Never>?
    private var cleanupProbeStarted = false

    func hasServer(name _: String) -> Bool {
        false
    }

    func isServerConnected(name _: String) async -> Bool {
        if self.removeServerCount == 0, self.addServerCount == 1 {
            self.cleanupProbeStarted = true
            self.cleanupProbeStartedContinuation?.resume()
            self.cleanupProbeStartedContinuation = nil
            await withCheckedContinuation { continuation in
                self.cleanupProbeContinuation = continuation
            }
        }
        return self.connected
    }

    func serverToolCount(name _: String) async -> Int {
        self.connected ? 29 : 0
    }

    func addServer(name _: String, config _: MCPServerConfig) async throws {
        self.addServerCount += 1
        self.connected = true
        if self.addServerCount == 1 {
            try await Task.sleep(for: .seconds(30))
        }
    }

    func removeServer(name _: String) async {
        self.removeServerCount += 1
        self.connected = false
    }

    func executeTool(
        serverName _: String,
        toolName _: String,
        arguments _: [String: Any]) async throws -> ToolResponse
    {
        .text("ok")
    }

    func waitUntilCleanupProbeStarts() async {
        guard !self.cleanupProbeStarted else { return }
        await withCheckedContinuation { continuation in
            self.cleanupProbeStartedContinuation = continuation
        }
    }

    func releaseCleanupProbe() {
        self.cleanupProbeContinuation?.resume()
        self.cleanupProbeContinuation = nil
    }
}

private final class OrderedConnectionAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> BrowserMCPConnectionAttempt {
        self.lock.withLock {
            self.count += 1
            return .standalone(timeout: self.count == 1 ? .milliseconds(40) : .seconds(2))
        }
    }
}
