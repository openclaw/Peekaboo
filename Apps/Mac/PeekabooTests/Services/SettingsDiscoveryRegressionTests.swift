import Foundation
import Testing
@testable import Peekaboo

@MainActor
struct SettingsDiscoveryRegressionTests {
    @Test
    func `Settings window lookup excludes an unrelated document`() {
        #expect(SettingsOpener.matchesSettingsWindow(
            identifier: "com_apple_SwiftUI_Settings_window",
            contentControllerTypeName: "EditorController"))
        #expect(SettingsOpener.matchesSettingsWindow(
            identifier: "document",
            contentControllerTypeName: "SettingsHostingController"))
        #expect(!SettingsOpener.matchesSettingsWindow(
            identifier: "document",
            contentControllerTypeName: "EditorController"))
    }

    @Test
    func `Ollama discovery reads each selected host and rejects stale or failed results`() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaTagsFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let first = await AgentSettingsView.probeOllamaModels(
            baseURL: "http://alpha.invalid", session: session, isCurrent: { true })
        #expect(first.map(\.id) == ["alpha.invalid"])
        let second = await AgentSettingsView.probeOllamaModels(
            baseURL: "http://beta.invalid", session: session, isCurrent: { true })
        #expect(second.map(\.id) == ["beta.invalid"])
        let stale = await AgentSettingsView.probeOllamaModels(
            baseURL: "http://alpha.invalid", session: session, isCurrent: { false })
        #expect(stale.isEmpty)
        let failed = await AgentSettingsView.probeOllamaModels(
            baseURL: "http://failed.invalid", session: session, isCurrent: { true })
        #expect(failed.isEmpty)
    }
}

private nonisolated class OllamaTagsFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".invalid") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = self.request.url, let host = url.host,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: host == "failed.invalid" ? 500 : 200,
                  httpVersion: nil,
                  headerFields: nil)
        else { return }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data("{\"models\":[{\"name\":\"\(host)\"}]}".utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
