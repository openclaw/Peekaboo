import Foundation

/// Canonical identity for one explicitly addressed loopback browser listener.
///
/// Host aliases intentionally remain distinct: `localhost`, IPv4 loopback, and IPv6 loopback can
/// resolve to different listeners even when their ports match.
public struct BrowserLoopbackEndpoint: Equatable, Sendable {
    public let normalizedHost: String
    public let port: Int
    public let canonicalBrowserURL: String

    public init?(browserURL: String) {
        guard var components = URLComponents(string: browserURL),
              components.scheme?.lowercased() == "http",
              let normalizedHost = Self.normalizedLoopbackHost(components.host),
              let port = components.port,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            return nil
        }
        components.scheme = "http"
        components.host = normalizedHost
        components.path = "/"
        guard let canonicalBrowserURL = components.url?.absoluteString else { return nil }
        self.normalizedHost = normalizedHost
        self.port = port
        self.canonicalBrowserURL = canonicalBrowserURL
    }

    public func matchesWebSocketDebuggerURL(_ rawValue: String, browserID: String) -> Bool {
        guard !browserID.isEmpty,
              browserID == browserID.trimmingCharacters(in: .whitespacesAndNewlines),
              !browserID.contains("/"),
              let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "ws",
              Self.normalizedLoopbackHost(components.host) == self.normalizedHost,
              components.port == self.port,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path == "/devtools/browser/\(browserID)"
        else {
            return false
        }
        return true
    }

    private static func normalizedLoopbackHost(_ rawHost: String?) -> String? {
        switch rawHost?.lowercased() {
        case "localhost": "localhost"
        case "127.0.0.1": "127.0.0.1"
        case "::1": "::1"
        default: nil
        }
    }
}
