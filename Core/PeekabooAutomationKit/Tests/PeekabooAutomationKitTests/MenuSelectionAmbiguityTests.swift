import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct MenuSelectionAmbiguityTests {
    @Test
    func `named selector reports duplicate paths across menu branches`() {
        let structure = self.structure(menus: [
            Menu(title: "File", items: [self.item("Close", path: "File > Close")]),
            Menu(title: "Window", items: [self.item("Close", path: "Window > Close")]),
        ])

        let resolution = MenuService.namedMenuPaths(
            itemName: "Close",
            in: structure,
            maxDepth: 8,
            maxChildren: 100)

        #expect(resolution.paths == ["File > Close", "Window > Close"])
        #expect(!resolution.exhausted)
    }

    @Test
    func `named selector keeps one unique nested path`() {
        let structure = self.structure(menus: [
            Menu(title: "File", items: [
                MenuItem(
                    title: "Recent",
                    submenu: [self.item("Fixture", path: "File > Recent > Fixture")],
                    path: "File > Recent"),
            ]),
        ])

        let resolution = MenuService.namedMenuPaths(
            itemName: "Fixture",
            in: structure,
            maxDepth: 8,
            maxChildren: 100)

        #expect(resolution.paths == ["File > Recent > Fixture"])
    }

    @Test
    func `named selector refuses a boundary match when budget can hide duplicate`() {
        let structure = self.structure(menus: [
            Menu(title: "File", items: [
                self.item("Close", path: "File > Close"),
                self.item("Other", path: "File > Other"),
                self.item("Close", path: "File > Close"),
            ]),
        ])

        let resolution = MenuService.namedMenuPaths(
            itemName: "Close",
            in: structure,
            maxDepth: 8,
            maxChildren: 2)

        #expect(resolution.paths == ["File > Close"])
        #expect(resolution.exhausted)
        do {
            _ = try MenuService.resolvedNamedMenuPath(
                itemName: "Close",
                applicationName: "Fixture",
                resolution: resolution)
            Issue.record("Expected budget-exhausted name resolution to refuse before dispatch")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .invalidRequest)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `explicit path level reports duplicate normalized sibling matches`() {
        let matches = MenuService.menuItemMatchIndexes(
            named: "Open…",
            candidateTitles: [["Open"], ["Open..."], ["Close"]])

        #expect(matches == [0, 1])
    }

    private func structure(menus: [Menu]) -> MenuStructure {
        MenuStructure(
            application: ServiceApplicationInfo(
                processIdentifier: 42,
                processStartIdentity: 99,
                bundleIdentifier: "dev.peekaboo.fixture",
                name: "Fixture"),
            menus: menus)
    }

    private func item(_ title: String, path: String) -> MenuItem {
        MenuItem(title: title, path: path)
    }
}
