import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserMCPSessionManagerChannelRefusalTests {
    @Test
    func `channel WebSocket refusal cannot reach MCP spawn or probe`() async {
        let manager = RefusingChannelBrowserMCPManager()
        let browser = DetectedBrowser(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            processIdentifier: 50,
            processStartIdentity: 2050,
            version: "151.0",
            channel: .stable)
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [browser] },
            processStartIdentity: { _ in 2050 },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { _ in
                throw BrowserMCPConnectionError.invalidEndpoint("unexpected HTTP resolution")
            },
            channelEndpointResolver: BrowserMCPChannelEndpointResolver { target in
                throw BrowserMCPConnectionError.channelEndpointUnavailable(target.channel, "HTTP 403")
            },
            environment: [:])

        await #expect(throws: BrowserMCPConnectionError.channelEndpointUnavailable(.stable, "HTTP 403")) {
            _ = try await session.connect(channel: .stable)
        }
        #expect(manager.addServerCount == 0)
        #expect(manager.executeCount == 0)
        #expect(manager.removeServerCount == 0)
    }
}

@MainActor
private final class RefusingChannelBrowserMCPManager: BrowserMCPManaging {
    var addServerCount = 0
    var executeCount = 0
    var removeServerCount = 0

    func hasServer(name _: String) -> Bool {
        false
    }

    func isServerConnected(name _: String) async -> Bool {
        false
    }

    func serverToolCount(name _: String) async -> Int {
        0
    }

    func addServer(name _: String, config _: MCPServerConfig) async throws {
        self.addServerCount += 1
    }

    func removeServer(name _: String) async {
        self.removeServerCount += 1
    }

    func executeTool(
        serverName _: String,
        toolName _: String,
        arguments _: [String: Any]) async throws -> ToolResponse
    {
        self.executeCount += 1
        return ToolResponse.text("unexpected")
    }
}
