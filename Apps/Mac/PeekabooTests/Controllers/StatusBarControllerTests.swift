import AppKit
import Testing
@testable import Peekaboo
@testable import PeekabooCore

@Suite(.tags(.ui, .unit))
@MainActor
struct StatusBarControllerTests {
    private final class AvailableUpdater: UpdaterProviding {
        var automaticallyChecksForUpdates = false
        let isAvailable = true
        func checkForUpdates(_: Any?) {}
    }

    private final class MockPermissionsService: ObservablePermissionsServiceProtocol {
        var screenRecordingStatus: ObservablePermissionsService.PermissionState = .authorized
        var accessibilityStatus: ObservablePermissionsService.PermissionState = .authorized
        var appleScriptStatus: ObservablePermissionsService.PermissionState = .notDetermined
        var postEventStatus: ObservablePermissionsService.PermissionState = .notDetermined

        var hasAllPermissions: Bool {
            self.screenRecordingStatus == .authorized && self.accessibilityStatus == .authorized
        }

        func checkPermissions(includeOptionalPermissions _: Bool, forceScreenRecordingProbe _: Bool) async {}
        func requestScreenRecording() async {}
        func requestAccessibility() async {}
        func requestAppleScript() async {}
        func requestPostEvent() async {}
    }

    private func makeController(
        permissionsService: MockPermissionsService = MockPermissionsService(),
        updater: any UpdaterProviding = DisabledUpdaterController()) -> StatusBarController
    {
        let settings = makeTestSettings()
        let sessionStore = SessionStore(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("StatusBarControllerTests-\(UUID().uuidString).json"))
        let permissions = Permissions(permissionsService: permissionsService)
        let agent = PeekabooAgent(
            settings: settings,
            sessionStore: sessionStore)
        return StatusBarController(
            agent: agent,
            sessionStore: sessionStore,
            permissions: permissions,
            settings: settings,
            updater: updater)
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
    func `Menu follows the frozen item order`() throws {
        let controller = self.makeController()
        defer { controller.removeStatusItem() }
        let sessions = (1...6).map {
            ConversationSession(id: "session-\($0)", title: "Session \($0)")
        }

        let menu = controller.makeContextMenu(agentModeEnabled: true, sessions: sessions)
        controller.menuWillOpen(menu)

        #expect(menu.items.map(self.visibleTitle) == [
            "Ready",
            "<separator>",
            "Open Peekaboo",
            "Inspector",
            "Recent Sessions",
            "<separator>",
            "Permissions…",
            "<separator>",
            "Settings…",
            "About Peekaboo",
            "<separator>",
            "Quit Peekaboo",
        ])

        let recentSessionsItem = try #require(menu.items.first(where: { $0.title == "Recent Sessions" }))
        let recentSessionsMenu = try #require(recentSessionsItem.submenu)
        #expect(recentSessionsMenu.items.map(\.title) == [
            "Session 1", "Session 2", "Session 3", "Session 4", "Session 5",
        ])

        let openItem = try #require(menu.items.first(where: { $0.title == "Open Peekaboo" }))
        #expect(openItem.keyEquivalent == "p")
        #expect(openItem.keyEquivalentModifierMask == [.command, .shift])

        let inspectorItem = try #require(menu.items.first(where: { $0.title == "Inspector" }))
        #expect(inspectorItem.keyEquivalent == "i")
        #expect(inspectorItem.keyEquivalentModifierMask == [.command, .shift])

        let settingsItem = try #require(menu.items.first(where: { $0.title.hasPrefix("Settings…") }))
        #expect(settingsItem.title == "Settings…\u{200B}")
        #expect(settingsItem.attributedTitle?.string == "Settings…\u{200B}")
        #expect(settingsItem.keyEquivalent == ",")
        #expect(settingsItem.keyEquivalentModifierMask == .command)

        let quitItem = try #require(menu.items.first(where: { $0.title == "Quit Peekaboo" }))
        #expect(quitItem.keyEquivalent == "q")
        #expect(quitItem.keyEquivalentModifierMask == .command)
    }

    @Test
    func `Update action is shown only when the updater is available`() {
        let disabled = self.makeController()
        let available = self.makeController(updater: AvailableUpdater())
        defer {
            disabled.removeStatusItem()
            available.removeStatusItem()
        }

        let disabledMenu = disabled.makeContextMenu(agentModeEnabled: false, sessions: [])
        let availableMenu = available.makeContextMenu(agentModeEnabled: false, sessions: [])

        #expect(!disabledMenu.items.contains(where: { $0.title == "Check for Updates…" }))
        #expect(availableMenu.items.contains(where: { $0.title == "Check for Updates…" }))
    }

    @Test
    func `Recent sessions only appear for enabled agent mode with sessions`() {
        let controller = self.makeController()
        defer { controller.removeStatusItem() }
        let sessions = [ConversationSession(id: "session-1", title: "Session 1")]

        let disabledMenu = controller.makeContextMenu(agentModeEnabled: false, sessions: sessions)
        let emptyMenu = controller.makeContextMenu(agentModeEnabled: true, sessions: [])

        #expect(!disabledMenu.items.contains(where: { $0.title == "Recent Sessions" }))
        #expect(!emptyMenu.items.contains(where: { $0.title == "Recent Sessions" }))
        #expect(
            !disabledMenu.items.contains(where: { $0.title == "Open Peekaboo" }),
            "Open Peekaboo no-ops without agent mode, so it must be hidden")
        #expect(disabledMenu.items.contains(where: { $0.title == "Inspector" }))
        #expect(emptyMenu.items.contains(where: { $0.title == "Open Peekaboo" }))
    }

    @Test
    func `Permission status refreshes when the menu opens`() throws {
        let permissionsService = MockPermissionsService()
        permissionsService.screenRecordingStatus = .denied
        let controller = self.makeController(permissionsService: permissionsService)
        defer { controller.removeStatusItem() }
        let menu = controller.makeContextMenu(agentModeEnabled: false, sessions: [])

        controller.refreshPermissionsStatus(in: menu)

        let statusItem = try #require(menu.items.first)
        #expect(statusItem.title == "Permissions required — open checklist")
        #expect(statusItem.isEnabled)
        #expect(statusItem.action != nil)

        permissionsService.screenRecordingStatus = .authorized
        permissionsService.accessibilityStatus = .authorized
        controller.refreshPermissionsStatus(in: menu)

        #expect(statusItem.title == "Ready")
        #expect(!statusItem.isEnabled)
        #expect(statusItem.action == nil)
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
        let item = NSMenuItem(title: "Recent Sessions", action: nil, keyEquivalent: "")
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

    private func visibleTitle(_ item: NSMenuItem) -> String {
        if item.isSeparatorItem {
            return "<separator>"
        }
        return item.title.replacingOccurrences(of: "\u{200B}", with: "")
    }
}
