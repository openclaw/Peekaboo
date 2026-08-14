import Foundation

struct BrowserMCPDevToolsEndpoint: Sendable, Equatable {
    let browserURL: String
    let webSocketDebuggerURL: String
    let browserID: String
    let browserVersion: String
    let protocolVersion: String
}

struct BrowserMCPDevToolsEndpointResolver: Sendable {
    let resolve: @Sendable (String) async throws -> BrowserMCPDevToolsEndpoint

    static let live = BrowserMCPDevToolsEndpointResolver { rawBrowserURL in
        let baseURL = try Self.validatedBaseURL(rawBrowserURL)
        let versionURL = baseURL.appending(path: "json/version")
        var request = URLRequest(url: versionURL)
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw BrowserMCPConnectionError.invalidEndpoint("/json/version did not return HTTP success")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let webSocketDebuggerURL = object["webSocketDebuggerUrl"] as? String,
              let browserVersion = object["Browser"] as? String,
              let protocolVersion = object["Protocol-Version"] as? String,
              let webSocketURL = URL(string: webSocketDebuggerURL),
              ["ws", "wss"].contains(webSocketURL.scheme?.lowercased() ?? ""),
              Self.isLoopback(webSocketURL.host),
              webSocketURL.port == baseURL.port,
              webSocketURL.path.hasPrefix("/devtools/browser/")
        else {
            throw BrowserMCPConnectionError
                .invalidEndpoint("/json/version omitted a matching loopback browser endpoint")
        }
        let browserID = String(webSocketURL.path.dropFirst("/devtools/browser/".count))
        guard !browserID.isEmpty, !browserID.contains("/") else {
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
        guard var components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "http",
              self.isLoopback(components.host),
              components.port != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw BrowserMCPConnectionError.invalidEndpoint(
                "expected http://127.0.0.1:<port>, http://[::1]:<port>, or http://localhost:<port>")
        }
        components.path = "/"
        guard let url = components.url else {
            throw BrowserMCPConnectionError.invalidEndpoint("the loopback URL could not be canonicalized")
        }
        return url
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "::1" || host == "localhost"
    }
}
