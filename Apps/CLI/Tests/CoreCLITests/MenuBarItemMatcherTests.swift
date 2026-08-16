import PeekabooAutomationKit
import Testing
@testable import PeekabooCLI

struct MenuBarItemMatcherTests {
    @Test func `hyphen-folded menu bar title matches`() throws {
        let item = MenuBarItemInfo(title: "WiFi", index: 0)

        let matched = try #require(try matchMenuBarItem(named: "Wi-Fi", items: [item]))

        #expect(matched.index == 0)
    }

    @Test func `exact menu bar title wins over earlier folded match`() throws {
        let folded = MenuBarItemInfo(title: "WiFi", index: 0)
        let exact = MenuBarItemInfo(title: "Wi-Fi", index: 1)

        let matched = try #require(try matchMenuBarItem(named: "Wi-Fi", items: [folded, exact]))

        #expect(matched.index == 1)
    }

    @Test func `ambiguous exact menu bar titles fail closed`() {
        let first = MenuBarItemInfo(title: "Clock", index: 0)
        let second = MenuBarItemInfo(title: "Clock", index: 1)

        #expect(throws: DesktopLeafSelectionError.self) {
            try matchMenuBarItem(named: "Clock", items: [first, second])
        }
    }

    @Test func `ambiguous partial menu bar titles fail closed`() {
        let first = MenuBarItemInfo(title: "Control Center", index: 0)
        let second = MenuBarItemInfo(title: "Control Strip", index: 1)

        #expect(throws: DesktopLeafSelectionError.self) {
            try matchMenuBarItem(named: "Control", items: [first, second])
        }
    }

    @Test func `menu bar matching is invariant under reordering`() throws {
        let partial = MenuBarItemInfo(title: "Wi-Fi Details", index: 0)
        let exact = MenuBarItemInfo(title: "Wi-Fi", index: 1)

        for items in [[partial, exact], [exact, partial]] {
            #expect(try matchMenuBarItem(named: "Wi-Fi", items: items)?.index == 1)
        }
    }
}
