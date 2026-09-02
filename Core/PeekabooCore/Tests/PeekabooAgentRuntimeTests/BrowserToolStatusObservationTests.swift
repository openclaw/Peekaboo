import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserToolStatusObservationTests {
    @Test(arguments: [false, true])
    func `confirmed status preserves connection and discovery reporting`(isConnected: Bool) async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: isConnected,
            toolCount: isConnected ? 29 : 0,
            detectedBrowsers: [DetectedBrowser(
                name: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                processIdentifier: 4242,
                version: "151.0",
                channel: .stable)]))
        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted).execute(
            arguments: ToolArguments(raw: ["action": "status"]))
        let text = response.content.compactMap { item -> String? in
            guard case let .text(value, _, _) = item else { return nil }
            return value
        }.joined(separator: "\n")
        #expect(text.contains(isConnected ? "Connected: yes" : "Connected: no"))
        #expect(text.contains(isConnected ? "Tools: 29" : "Tools: 0"))
        #expect(text.contains("Google Chrome 151.0 [stable] pid=4242"))
        #expect(text.contains("To enable browser control:") == !isConnected)
        #expect(response.meta?.objectValue?["status_observation"] == .string("confirmed"))
        #expect(response.meta?.objectValue?["connected"] == .bool(isConnected))
        #expect(response.meta?.objectValue?["tool_count"] == .int(isConnected ? 29 : 0))
        #expect(response.meta?.objectValue?["browser_count"] == .int(1))
        #expect(response.meta?.objectValue?["channels"] == .array([.string("stable")]))
    }

    @Test(arguments: [false, true])
    func `indeterminate status does not claim disconnection or fresh browser discovery`(
        hasCachedBrowser: Bool) async throws
    {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: hasCachedBrowser ? [DetectedBrowser(
                name: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                processIdentifier: 4242,
                version: "151.0",
                channel: .stable)] : [],
            connectionReceipt: BrowserMCPConnectionReceipt(
                browserURL: "http://127.0.0.1:9222/",
                webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
                devToolsBrowserID: "browser-a"),
            providerSessionEpoch: BrowserMCPProviderSessionEpoch(),
            error: CancellationError().localizedDescription,
            observation: .indeterminate))
        let tool = BrowserTool(client: client, executionPolicy: .unrestricted)

        let response = try await tool.execute(arguments: ToolArguments(raw: ["action": "status"]))

        #expect(!response.isError)
        let text = response.content.compactMap { item in
            guard case let .text(value, _, _) = item else { return nil }
            return value
        }.joined(separator: "\n")
        #expect(text.contains("Connected: unknown"))
        #expect(text.contains("Tools: unknown"))
        #expect(text.contains("Observation: indeterminate"))
        #expect(text.contains("Detected Chrome: unknown"))
        #expect(!text.contains("Detected Chrome: none"))
        #expect(!text.contains("pid=4242"))
        #expect(!text.contains("To enable browser control:"))
        #expect(response.meta?.objectValue?["connected"] == .null)
        #expect(response.meta?.objectValue?["tool_count"] == .null)
        #expect(response.meta?.objectValue?["browser_count"] == .null)
        #expect(response.meta?.objectValue?["channels"] == .null)
        #expect(response.meta?.objectValue?["status_observation"] == .string("indeterminate"))
    }
}
