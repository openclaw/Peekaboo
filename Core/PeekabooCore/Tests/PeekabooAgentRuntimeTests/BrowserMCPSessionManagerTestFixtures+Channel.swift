@testable import PeekabooAgentRuntime

extension BrowserMCPSessionManagerTests {
    static func channelEndpointResolver() -> BrowserMCPChannelEndpointResolver {
        let endpoint = BrowserMCPDevToolsEndpoint(
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            browserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let resolve: BrowserMCPChannelEndpointResolver.Resolve = { _ in endpoint }
        let revalidate: BrowserMCPChannelEndpointResolver.Revalidate = { _, expected in
            guard expected == endpoint else {
                throw BrowserMCPConnectionError.connectionLost("fixture endpoint drift")
            }
        }
        return BrowserMCPChannelEndpointResolver(resolve, revalidate: revalidate)
    }
}
