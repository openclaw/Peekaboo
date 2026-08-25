@testable import PeekabooAgentRuntime

extension BrowserMCPSessionManagerTests {
    static func channelEndpointResolver() -> BrowserMCPChannelEndpointResolver {
        BrowserMCPChannelEndpointResolver { _ in
            BrowserMCPDevToolsEndpoint(
                browserURL: "http://127.0.0.1:9222/",
                webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
                browserID: "browser-a",
                browserVersion: "Chrome/151.0",
                protocolVersion: "1.3")
        }
    }
}
