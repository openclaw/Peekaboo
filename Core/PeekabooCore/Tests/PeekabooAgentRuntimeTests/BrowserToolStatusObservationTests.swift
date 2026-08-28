import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserToolStatusObservationTests {
    @Test
    func `indeterminate status does not claim disconnection or a zero tool count`() async throws {
        let client = MockBrowserMCPClient(status: BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: [],
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
        #expect(!text.contains("To enable browser control:"))
        #expect(response.meta?.objectValue?["connected"] == .null)
        #expect(response.meta?.objectValue?["tool_count"] == .null)
        #expect(response.meta?.objectValue?["status_observation"] == .string("indeterminate"))
    }
}
