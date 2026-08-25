import PeekabooFoundation
import Testing
@testable import PeekabooAgentRuntime

struct BrowserMCPChannelInferenceTests {
    @Test
    func `exact Chrome bundle identifiers select every supported channel`() {
        let fixtures: [(String, String, BrowserMCPChannel)] = [
            ("com.google.Chrome", "Unexpected Stable Name", .stable),
            ("com.google.Chrome.beta", "Unexpected Beta Name", .beta),
            ("com.google.Chrome.dev", "Unexpected Dev Name", .dev),
            ("com.google.Chrome.canary", "Google Chrome Canary", .canary),
        ]

        for (bundleIdentifier, applicationName, channel) in fixtures {
            #expect(BrowserMCPChannel.infer(
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName) == channel)
        }
    }

    @Test
    func `non Chrome bundle identifiers cannot inherit a channel from an app owned service name`() {
        let liveHostiles = [
            (
                "com.apple.SafariPlatformSupport.Helper",
                "AutoFill (Google Chrome Canary)"),
            (
                "com.apple.appkit.xpc.ThemeWidgetControlViewService",
                "ThemeWidgetControlViewService (Google Chrome Canary)"),
        ]

        for (bundleIdentifier, applicationName) in liveHostiles {
            #expect(BrowserMCPChannel.infer(
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName) == nil)
        }
    }

    @Test
    func `bundle lookalikes cannot use exact or substring Chrome names`() {
        let lookalikes = [
            "com.google.Chrome.helper",
            "com.google.Chrome.canary.helper",
            "org.example.Chrome.canary",
        ]

        for bundleIdentifier in lookalikes {
            #expect(BrowserMCPChannel.infer(
                bundleIdentifier: bundleIdentifier,
                applicationName: "Google Chrome Canary") == nil)
        }
    }

    @Test
    func `bundle identifier case variants are not Chrome channels`() {
        for channel in BrowserMCPChannel.allCases {
            let bundleIdentifier = ChromeChannelIdentity(rawValue: channel.rawValue)?.bundleIdentifier
            #expect(BrowserMCPChannel.infer(
                bundleIdentifier: bundleIdentifier?.uppercased(),
                applicationName: "Google Chrome") == nil)
        }
    }

    @Test
    func `missing bundle identity cannot fall back to an exact or substring name`() {
        #expect(BrowserMCPChannel.infer(
            bundleIdentifier: "",
            applicationName: "Google Chrome Canary") == nil)
        #expect(BrowserMCPChannel.infer(
            bundleIdentifier: nil,
            applicationName: "Google Chrome Canary") == nil)
        #expect(BrowserMCPChannel.infer(
            bundleIdentifier: nil,
            applicationName: "AutoFill (Google Chrome Canary)") == nil)
    }
}
