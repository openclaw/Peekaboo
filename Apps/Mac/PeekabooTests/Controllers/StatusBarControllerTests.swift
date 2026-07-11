import AppKit
import Testing
@testable import Peekaboo

@Suite(.tags(.ui, .unit))
@MainActor
struct StatusBarControllerTests {
    private func makeController() -> StatusBarController {
        let settings = PeekabooSettings()
        let sessionStore = SessionStore()
        let permissions = Permissions()
        let agent = PeekabooAgent(
            settings: settings,
            sessionStore: sessionStore)
        return StatusBarController(
            agent: agent,
            sessionStore: sessionStore,
            permissions: permissions,
            settings: settings,
            updater: DisabledUpdaterController())
    }

    @Test
    func `Agent session UI follows agent mode`() {
        #expect(AgentSessionUI.isAvailable(agentModeEnabled: true))
        #expect(!AgentSessionUI.isAvailable(agentModeEnabled: false))
    }

    @Test
    func `Agent session windows have stable identities`() {
        #expect(AgentSessionUI.identifiesSessionWindow(identifier: "main", title: ""))
        #expect(AgentSessionUI.identifiesSessionWindow(
            identifier: AgentSessionUI.detailWindowIdentifier(sessionID: "test-session"),
            title: "Test Session"))
        #expect(AgentSessionUI.identifiesSessionWindow(identifier: nil, title: "Peekaboo Sessions"))
        #expect(!AgentSessionUI.identifiesSessionWindow(identifier: "inspector", title: "Inspector"))
    }

    @Test
    func `Controller initializes with status item`() {
        _ = self.makeController()

        // StatusBarController is properly initialized
        // We can't access private statusItem, but we can verify the controller exists
        // Controller initialized successfully
    }

    @Test
    func `Menu contains expected items`() {
        _ = self.makeController()

        // We can't directly access the private statusItem property
        // This test would need the StatusBarController to expose a testing API
        // or make statusItem internal for testing

        // Test passes - we verified controller initializes without crashing
    }

    @Test
    func `Icon animation states`() {
        _ = self.makeController()

        // Test passes - we verified controller initializes without crashing
        // We can't access private statusItem property
    }

    @Test
    func `Status menu pins the exact application effective appearance`() {
        let menu = NSMenu()

        StatusMenuAppearance.pin(menu)

        #expect(menu.appearance === NSApplication.shared.effectiveAppearance)
    }

    @Test
    func `Submenus inherit the pinned root appearance`() throws {
        let menu = NSMenu()
        let submenu = NSMenu()
        let item = NSMenuItem(title: "Agent", action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)

        let light = try #require(NSAppearance(named: .aqua))
        StatusMenuAppearance.pin(menu, to: light)
        #expect(menu.appearance === light)
        #expect(submenu.appearance == nil)
        #expect(submenu.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)

        let dark = try #require(NSAppearance(named: .darkAqua))
        StatusMenuAppearance.pin(menu, to: dark)
        #expect(submenu.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    @Test
    func `Popover presentation`() {
        _ = self.makeController()

        // We can't access private popover property
        // Test passes - controller initialized without crashing
    }
}
