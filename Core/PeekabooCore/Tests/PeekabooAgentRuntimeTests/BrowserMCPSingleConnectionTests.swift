import Foundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserMCPSingleConnectionTests {
    @Test
    func `explicit HTTP discovery launches the verified WebSocket for headless Chromium`() async throws {
        let provider = SingleConnectionProvider()
        provider.product = "HeadlessChrome/152.0"
        let endpoint = BrowserMCPDevToolsEndpoint(
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: SingleConnectionProvider.expectedEndpoint,
            browserID: "fixture",
            browserVersion: provider.product,
            protocolVersion: "1.3")
        let session = BrowserMCPSessionManager(
            serverName: "fixture",
            manager: provider,
            detectedBrowsers: { _ in [] },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { _ in endpoint },
            environment: [:])

        let result = try await session.connect(channel: nil, browserURL: endpoint.browserURL)
        #expect(result.isConnected)
        #expect(result.connectionReceipt?.browserVersion == "HeadlessChrome/152.0")
        let config = try #require(provider.configs.first)
        #expect(config.args.contains("--wsEndpoint=\(endpoint.webSocketDebuggerURL)"))
        #expect(!config.args.contains { $0.hasPrefix("--browserUrl") })
        #expect(provider.calls == ["peekaboo_browser_connect", "list_pages"])
        await session.disconnect()
    }

    @Test
    func `native connect verifies provider once then reuses it for page work`() async throws {
        let provider = SingleConnectionProvider()
        let session = Self.session(provider)
        let result = try await session.connect(channel: .stable)
        #expect(result.isConnected)
        #expect(result.connectionReceipt?.browserVersion == "Chrome/152.0")
        #expect(result.connectionReceipt?.protocolVersion == "1.3")
        #expect(provider.calls == ["peekaboo_browser_connect", "list_pages"])
        _ = try await session.connect(channel: .stable)
        _ = try await session.execute(toolName: "take_snapshot", arguments: [:], channel: .stable)
        #expect(provider.calls == ["peekaboo_browser_connect", "list_pages", "take_snapshot"])
        #expect(provider.starts == 1)
        await session.disconnect()
        #expect(!provider.connected)
    }

    @Test
    func `provider endpoint substitution fails before any page operation`() async {
        let provider = SingleConnectionProvider()
        provider.endpoint = "ws://127.0.0.1:18800/devtools/browser/managed"
        let session = Self.session(provider)
        await #expect(throws: (any Error).self) { _ = try await session.connect(channel: .stable) }
        #expect(provider.calls == ["peekaboo_browser_connect"])
        #expect(!provider.connected)
        #expect(await session.status(channel: .stable).connectionReceipt == nil)
    }

    @Test
    func `post approval listener change fails before any page operation`() async {
        let provider = SingleConnectionProvider()
        let session = Self.session(provider, changedListener: true)
        await #expect(throws: (any Error).self) { _ = try await session.connect(channel: .stable) }
        #expect(provider.calls == ["peekaboo_browser_connect"])
        #expect(!provider.connected)
    }

    @Test
    func `approval refusal cannot publish a receipt or retry`() async {
        let provider = SingleConnectionProvider()
        provider.refuse = true
        let session = Self.session(provider)
        await #expect(throws: (any Error).self) { _ = try await session.connect(channel: .stable) }
        #expect(provider.calls == ["peekaboo_browser_connect"])
        #expect(provider.starts == 1)
        #expect(!provider.connected)
        #expect(await session.status(channel: .stable).connectionReceipt == nil)
    }

    private static func session(
        _ provider: SingleConnectionProvider,
        changedListener: Bool = false) -> BrowserMCPSessionManager
    {
        let endpoint = BrowserMCPDevToolsEndpoint(
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: SingleConnectionProvider.expectedEndpoint,
            browserID: "fixture")
        let resolve: BrowserMCPChannelEndpointResolver.Resolve = { _ in endpoint }
        let revalidate: BrowserMCPChannelEndpointResolver.Revalidate = { _, _ in
            if changedListener {
                throw BrowserMCPConnectionError.connectionLost("listener changed")
            }
        }
        return BrowserMCPSessionManager(
            serverName: "fixture",
            manager: provider,
            detectedBrowsers: { _ in
                [DetectedBrowser(
                    name: "Chrome",
                    bundleIdentifier: "com.google.Chrome",
                    processIdentifier: 81,
                    processStartIdentity: 5081,
                    version: "152.0",
                    channel: .stable)]
            },
            processStartIdentity: { _ in 5081 },
            processBundleIdentifier: { _ in "com.google.Chrome" },
            processCodeSignatureValidator: { _, _, channel in .browserTestIdentity(channel: channel) },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { _ in
                Issue.record("Native channel must never fetch HTTP discovery")
                throw BrowserMCPConnectionError.invalidEndpoint("unexpected HTTP request")
            },
            channelEndpointResolver: BrowserMCPChannelEndpointResolver(resolve, revalidate: revalidate),
            environment: [:])
    }
}

@MainActor
private final class SingleConnectionProvider: BrowserMCPManaging {
    static let expectedEndpoint = "ws://127.0.0.1:9222/devtools/browser/fixture"
    var endpoint = expectedEndpoint
    var connected = false
    var starts = 0
    var configs: [MCPServerConfig] = []
    var product = "Chrome/152.0"
    var calls: [String] = []
    var refuse = false

    func hasServer(name _: String) -> Bool {
        self.connected
    }

    func isServerConnected(name _: String) async -> Bool {
        self.connected
    }

    func serverToolCount(name _: String) async -> Int {
        self.connected ? 30 : 0
    }

    func addServer(name _: String, config: MCPServerConfig) async throws {
        self.configs.append(config)
        self.starts += 1
        self.connected = true
    }

    func removeServer(name _: String) async {
        self.connected = false
    }

    func executeTool(serverName _: String, toolName: String, arguments _: [String: Any]) async throws -> ToolResponse {
        self.calls.append(toolName)
        guard toolName == "peekaboo_browser_connect" else { return .text("ok") }
        if self.refuse {
            return .error("HTTP 403")
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "webSocketDebuggerUrl": self.endpoint, "product": self.product, "protocolVersion": "1.3",
        ])
        return try .text(#require(String(data: data, encoding: .utf8)))
    }
}
