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
        self.expectStructuredCapabilityArguments(config.args)
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
        self.expectStructuredCapabilityArguments(config.args)
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

    @Test
    func `Explicit browser URL config retains structured capability arguments`() {
        let config = BrowserMCPService.chromeDevToolsConfig(
            browserURL: "http://127.0.0.1:9222/",
            headless: false)

        self.expectStructuredCapabilityArguments(config.args)
        #expect(config.args.contains("--browserUrl=http://127.0.0.1:9222/"))
    }

    private func expectStructuredCapabilityArguments(_ arguments: [String]) {
        #expect(Array(arguments.prefix(4)) == [
            "-y",
            "chrome-devtools-mcp@1.6.0",
            "--experimentalPageIdRouting",
            "--experimentalStructuredContent",
        ])
        #expect(arguments.count { $0 == "--experimentalPageIdRouting" } == 1)
        #expect(arguments.count { $0 == "--experimentalStructuredContent" } == 1)
    }
}
