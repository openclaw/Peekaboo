import Foundation
import Testing
@testable import PeekabooAgentRuntime

struct BrowserMCPDevToolsEndpointResolverTests {
    @Test
    func `direct exact loopback response resolves`() async throws {
        let endpoint = try await BrowserMCPDevToolsEndpointResolver.resolveEndpoint(
            "http://127.0.0.1:9222")
        { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:9222/json/version")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            return try Self.response(
                url: #require(request.url),
                webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a")
        }

        #expect(endpoint.browserURL == "http://127.0.0.1:9222/")
        #expect(endpoint.browserID == "browser-a")
    }

    @Test
    func `DevTools WebSocket must retain the exact normalized listener host and port`() async throws {
        for webSocketDebuggerURL in [
            "ws://127.0.0.1:9333/devtools/browser/browser-a",
            "ws://localhost:9222/devtools/browser/browser-a",
            "wss://127.0.0.1:9222/devtools/browser/browser-a",
        ] {
            await #expect(throws: BrowserMCPConnectionError.self) {
                _ = try await BrowserMCPDevToolsEndpointResolver.resolveEndpoint(
                    "HTTP://127.0.0.1:9222")
                { request in
                    try Self.response(
                        url: #require(request.url),
                        webSocketDebuggerURL: webSocketDebuggerURL)
                }
            }
        }
    }

    @Test(arguments: [
        "http://127.0.0.1:9333/json/version",
        "https://example.com/json/version",
    ])
    func `redirected final response URL is refused`(finalURL: String) async throws {
        await #expect(throws: BrowserMCPConnectionError.invalidEndpoint(
            "/json/version did not return direct HTTP success from the exact loopback endpoint"))
        {
            _ = try await BrowserMCPDevToolsEndpointResolver.resolveEndpoint(
                "http://127.0.0.1:9222")
            { _ in
                try Self.response(
                    url: #require(URL(string: finalURL)),
                    webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a")
            }
        }
    }

    @Test
    func `fetch cancellation remains cancellation`() async {
        await #expect(throws: CancellationError.self) {
            _ = try await BrowserMCPDevToolsEndpointResolver.resolveEndpoint(
                "http://127.0.0.1:9222")
            { _ in
                throw CancellationError()
            }
        }
    }

    @Test
    func `URL session delegate refuses redirects`() async throws {
        let delegate = BrowserMCPNoRedirectURLSessionDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let redirectURL = try #require(URL(string: "https://example.com/json/version"))
        let sourceURL = try #require(URL(string: "http://127.0.0.1:9222/json/version"))
        let request = URLRequest(url: redirectURL)
        let task = session.dataTask(with: request)
        let response = try #require(HTTPURLResponse(
            url: sourceURL,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": redirectURL.absoluteString]))

        let redirectedRequest = await withCheckedContinuation { continuation in
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: request,
                completionHandler: { continuation.resume(returning: $0) })
        }

        #expect(redirectedRequest == nil)
    }

    private static func response(
        url: URL,
        webSocketDebuggerURL: String) throws -> (Data, URLResponse)
    {
        let data = try JSONSerialization.data(withJSONObject: [
            "Browser": "Chrome/151.0",
            "Protocol-Version": "1.3",
            "webSocketDebuggerUrl": webSocketDebuggerURL,
        ])
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil))
        return (data, response)
    }
}
