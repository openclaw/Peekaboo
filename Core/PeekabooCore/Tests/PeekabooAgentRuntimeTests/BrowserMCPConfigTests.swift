import Testing
@testable import PeekabooAgentRuntime

struct BrowserMCPConfigTests {
    @Test
    func `Chrome DevTools config can launch isolated headless browser for deterministic tests`() {
        let config = BrowserMCPService.isolatedChromeDevToolsConfig(
            channel: .stable,
            headless: true)

        #expect(!config.args.contains("--auto-connect"))
        #expect(config.args.contains("--isolated"))
        #expect(config.args.contains("--headless"))
        #expect(config.args.contains("--channel=stable"))
        #expect(config.args.contains("--experimentalPageIdRouting"))
        #expect(config.args.contains("--no-usage-statistics"))
        #expect(config.args.contains("--no-performance-crux"))
    }

    @Test
    func `Chrome DevTools config can target an exact WebSocket`() {
        let config = BrowserMCPService.chromeDevToolsConfig(
            webSocketEndpoint: "ws://127.0.0.1:9222/devtools/browser/browser-a")

        #expect(!config.args.contains("--auto-connect"))
        #expect(!config.args.contains("--channel=canary"))
        #expect(config.args.contains(
            "--wsEndpoint=ws://127.0.0.1:9222/devtools/browser/browser-a"))
        #expect(config.args.contains("--experimentalPageIdRouting"))
        #expect(config.args.contains("--no-usage-statistics"))
        #expect(config.args.contains("--no-performance-crux"))
    }

    @Test
    func `headless launch option cannot retarget an existing exact WebSocket`() {
        let config = BrowserMCPService.chromeDevToolsConfig(
            target: .exactWebSocket("ws://127.0.0.1:9222/devtools/browser/browser-a"),
            headless: true)

        #expect(config.args.contains(
            "--wsEndpoint=ws://127.0.0.1:9222/devtools/browser/browser-a"))
        #expect(!config.args.contains("--headless"))
        #expect(!config.args.contains("--auto-connect"))
        #expect(!config.args.contains("--isolated"))
    }
}
