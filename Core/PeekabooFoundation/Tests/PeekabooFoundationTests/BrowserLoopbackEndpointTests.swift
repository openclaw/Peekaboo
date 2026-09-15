import Testing
@testable import PeekabooFoundation

struct BrowserLoopbackEndpointTests {
    @Test
    func `normalization stays idempotent across sampled TCP ports and host families`() throws {
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            for port in stride(from: 1, through: 65535, by: 257) {
                let endpoint = try #require(BrowserLoopbackEndpoint(browserURL: "HTTP://\(host):\(port)"))
                #expect(BrowserLoopbackEndpoint(browserURL: endpoint.canonicalBrowserURL) == endpoint)
                #expect(endpoint.matchesWebSocketDebuggerURL(
                    "ws://\(host):\(port)/devtools/browser/fixture", browserID: "fixture"))
            }
        }
    }

    @Test(arguments: ["0", "65536", "70000", "18446744073709551615"])
    func `invalid TCP ports cannot become canonical browser endpoints`(port: String) {
        #expect(BrowserLoopbackEndpoint(browserURL: "http://127.0.0.1:\(port)") == nil)
        #expect(BrowserLoopbackEndpoint(browserURL: "http://localhost:\(port)") == nil)
        #expect(BrowserLoopbackEndpoint(browserURL: "http://[::1]:\(port)") == nil)
    }

    @Test(arguments: [1, 9222, 65535])
    func `IPv6 loopback preserves a usable URL and exact WebSocket identity`(port: Int) throws {
        let endpoint = try #require(BrowserLoopbackEndpoint(browserURL: "http://[::1]:\(port)"))
        #expect(endpoint.normalizedHost == "::1")
        #expect(endpoint.port == port)
        #expect(endpoint.canonicalBrowserURL == "http://[::1]:\(port)/")
        #expect(endpoint.matchesWebSocketDebuggerURL(
            "ws://[::1]:\(port)/devtools/browser/fixture",
            browserID: "fixture"))
        #expect(!endpoint.matchesWebSocketDebuggerURL(
            "ws://127.0.0.1:\(port)/devtools/browser/fixture",
            browserID: "fixture"))
        #expect(!endpoint.matchesWebSocketDebuggerURL(
            "ws://localhost:\(port)/devtools/browser/fixture",
            browserID: "fixture"))
        #expect(BrowserLoopbackEndpoint(browserURL: endpoint.canonicalBrowserURL) == endpoint)
    }

    @Test(arguments: ["localhost", "127.0.0.1"])
    func `IPv4 and localhost retain TCP boundary ports and distinct identities`(host: String) throws {
        for port in [1, 65535] {
            let endpoint = try #require(BrowserLoopbackEndpoint(browserURL: "http://\(host):\(port)"))
            #expect(endpoint.port == port)
            #expect(endpoint.matchesWebSocketDebuggerURL(
                "ws://\(host):\(port)/devtools/browser/fixture",
                browserID: "fixture"))
        }
        #expect(BrowserLoopbackEndpoint(browserURL: "http://localhost:9222") !=
            BrowserLoopbackEndpoint(browserURL: "http://127.0.0.1:9222"))
    }

    @Test(arguments: ["http://[::2]:9222", "http://[::1%25lo0]:9222", "http://::1:9222"])
    func `other IPv6 addresses scopes and malformed hosts remain refused`(url: String) {
        #expect(BrowserLoopbackEndpoint(browserURL: url) == nil)
    }
}
