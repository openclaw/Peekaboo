import Foundation
import PeekabooFoundation

struct BrowserMCPDevToolsEndpoint: Sendable, Equatable {
    let browserURL: String
    let webSocketDebuggerURL: String
    let browserID: String
    let browserVersion: String
    let protocolVersion: String
}

struct BrowserMCPDevToolsEndpointResolver: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let resolve: @Sendable (String) async throws -> BrowserMCPDevToolsEndpoint

    static let live = BrowserMCPDevToolsEndpointResolver { rawBrowserURL in
        try await Self.resolveEndpoint(rawBrowserURL) { request in
            try await BrowserMCPNoRedirectURLSession.shared.data(for: request)
        }
    }

    static func resolveEndpoint(
        _ rawBrowserURL: String,
        fetch: Fetch) async throws -> BrowserMCPDevToolsEndpoint
    {
        let baseURL = try Self.validatedBaseURL(rawBrowserURL)
        let versionURL = baseURL.appending(path: "json/version")
        var request = URLRequest(url: versionURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 3
        let (data, response) = try await fetch(request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.url == versionURL,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw BrowserMCPConnectionError.invalidEndpoint(
                "/json/version did not return direct HTTP success from the exact loopback endpoint")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let webSocketDebuggerURL = object["webSocketDebuggerUrl"] as? String,
              let browserVersion = object["Browser"] as? String,
              let protocolVersion = object["Protocol-Version"] as? String,
              let baseEndpoint = BrowserLoopbackEndpoint(browserURL: baseURL.absoluteString),
              let webSocketURL = URL(string: webSocketDebuggerURL),
              webSocketURL.path.hasPrefix("/devtools/browser/")
        else {
            throw BrowserMCPConnectionError
                .invalidEndpoint("/json/version omitted a matching loopback browser endpoint")
        }
        let browserID = String(webSocketURL.path.dropFirst("/devtools/browser/".count))
        guard baseEndpoint.matchesWebSocketDebuggerURL(
            webSocketDebuggerURL,
            browserID: browserID)
        else {
            throw BrowserMCPConnectionError.invalidEndpoint("the DevTools browser identity was malformed")
        }
        return BrowserMCPDevToolsEndpoint(
            browserURL: baseURL.absoluteString,
            webSocketDebuggerURL: webSocketDebuggerURL,
            browserID: browserID,
            browserVersion: browserVersion,
            protocolVersion: protocolVersion)
    }

    private static func validatedBaseURL(_ rawValue: String) throws -> URL {
        guard let endpoint = BrowserLoopbackEndpoint(browserURL: rawValue),
              let url = URL(string: endpoint.canonicalBrowserURL)
        else {
            throw BrowserMCPConnectionError.invalidEndpoint(
                "expected http://127.0.0.1:<port>, http://[::1]:<port>, or http://localhost:<port>")
        }
        return url
    }
}

final class BrowserMCPNoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}

private enum BrowserMCPNoRedirectURLSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration,
            delegate: BrowserMCPNoRedirectURLSessionDelegate(),
            delegateQueue: nil)
    }()
}
