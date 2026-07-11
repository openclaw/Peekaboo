import PeekabooAutomationKit
import Testing
@testable import PeekabooCLI

struct MenuBarItemMatcherTests {
    @Test func `hyphen-folded menu bar title matches`() throws {
        let item = MenuBarItemInfo(title: "WiFi", index: 0)

        let matched = try #require(matchMenuBarItem(named: "Wi-Fi", items: [item]))

        #expect(matched.index == 0)
    }

    @Test func `exact menu bar title wins over earlier folded match`() throws {
        let folded = MenuBarItemInfo(title: "WiFi", index: 0)
        let exact = MenuBarItemInfo(title: "Wi-Fi", index: 1)

        let matched = try #require(matchMenuBarItem(named: "Wi-Fi", items: [folded, exact]))

        #expect(matched.index == 1)
    }
}
