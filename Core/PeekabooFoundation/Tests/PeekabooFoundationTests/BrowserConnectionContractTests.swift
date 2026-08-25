import Testing
@testable import PeekabooFoundation

struct BrowserConnectionContractTests {
    @Test
    func `Chrome channels map only exact bundle identifiers`() {
        for channel in ChromeChannelIdentity.allCases {
            #expect(ChromeChannelIdentity(exactBundleIdentifier: channel.bundleIdentifier) == channel)
            #expect(!channel.matches(bundleIdentifier: channel.bundleIdentifier.uppercased()))
            #expect(!channel.matches(bundleIdentifier: "\(channel.bundleIdentifier).helper"))
        }

        #expect(ChromeChannelIdentity(exactBundleIdentifier: nil) == nil)
        #expect(ChromeChannelIdentity(exactBundleIdentifier: "") == nil)
        #expect(ChromeChannelIdentity(exactBundleIdentifier: " com.google.Chrome ") == nil)
        #expect(ChromeChannelIdentity(exactBundleIdentifier: "com.apple.SafariPlatformSupport.Helper") == nil)
    }

    @Test
    func `browser connection timing retains MCP startup after approval`() {
        #expect(BrowserConnectionTiming.endToEndTimeoutSeconds > BrowserConnectionTiming.approvalTimeoutSeconds)
        #expect(BrowserConnectionTiming.bridgeTransportTimeoutSeconds >
            BrowserConnectionTiming.endToEndTimeoutSeconds)
    }
}
