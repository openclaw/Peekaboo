import Foundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct BrowserMCPProviderConnectionTests {
    private static let endpoint = "ws://127.0.0.1:9222/devtools/browser/fixture"

    @Test
    func `explicit endpoints retain custom and headless product names`() throws {
        let response = try Self.response(["product": "HeadlessChrome/152.0"])
        let version = try BrowserMCPProviderConnection.version(response, endpoint: Self.endpoint)
        #expect(version.browserVersion == "HeadlessChrome/152.0")
    }

    @Test
    func `provider must identify the same socket and a real Chrome version`() throws {
        let response = try Self.response()
        let version = try BrowserMCPProviderConnection.version(response, endpoint: Self.endpoint)
        #expect(version.browserVersion == "Chrome/152.0")
        #expect(version.protocolVersion == "1.3")
    }

    @Test(arguments: [
        ["product": ""],
        ["protocolVersion": ""],
        ["webSocketDebuggerUrl": "ws://127.0.0.1:18800/devtools/browser/fixture"],
        ["webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/browser/replaced"],
    ])
    func `provider identity drift cannot publish a receipt`(overrides: [String: String]) {
        #expect(throws: BrowserMCPConnectionError.self) {
            try BrowserMCPProviderConnection.version(Self.response(overrides), endpoint: Self.endpoint)
        }
    }

    @Test
    func `invalid and oversized provider responses fail closed`() {
        for response in [
            ToolResponse.text("not JSON"),
            .error("HTTP 403"),
            .text(String(repeating: "x", count: 65537)),
        ] {
            #expect(throws: BrowserMCPConnectionError.self) {
                try BrowserMCPProviderConnection.version(response, endpoint: Self.endpoint)
            }
        }
    }

    private static func response(_ overrides: [String: String] = [:]) throws -> ToolResponse {
        let object = [
            "webSocketDebuggerUrl": Self.endpoint,
            "product": "Chrome/152.0",
            "protocolVersion": "1.3",
        ].merging(overrides, uniquingKeysWith: { _, replacement in replacement })
        let data = try JSONSerialization.data(withJSONObject: object)
        return try .text(#require(String(data: data, encoding: .utf8)))
    }
}
