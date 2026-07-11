import AppKit
import os.log
import PeekabooCore
import SwiftUI

enum AgentSessionUI {
    static let mainWindowIdentifier = "main"
    static let mainWindowTitle = "Peekaboo Sessions"
    private static let detailWindowIdentifierPrefix = "agent-session:"

    static func isAvailable(agentModeEnabled: Bool) -> Bool {
        agentModeEnabled
    }

    static func detailWindowIdentifier(sessionID: String) -> String {
        "\(self.detailWindowIdentifierPrefix)\(sessionID)"
    }

    static func identifiesSessionWindow(identifier: String?, title: String) -> Bool {
        identifier == self.mainWindowIdentifier ||
            identifier?.hasPrefix(self.detailWindowIdentifierPrefix) == true ||
            title == self.mainWindowTitle
    }
}

/// Pins status bar menus to the app's effective appearance.
///
/// Menus popped from a status item inherit the menu bar's vibrant appearance, which is derived
/// from the wallpaper behind it rather than the system light/dark mode. Pinning the exact
/// effective appearance (not just its name) keeps accessibility attributes intact; submenus
/// inherit it automatically.
@MainActor
enum StatusMenuAppearance {
    static func pin(_ menu: NSMenu) {
        self.pin(menu, to: NSApplication.shared.effectiveAppearance)
    }

    static func pin(_ menu: NSMenu, to appearance: NSAppearance) {
        menu.appearance = appearance
    }
}

/// Controls the Peekaboo status bar item and popover interface.
///
/// Manages the macOS status bar integration with animated icon states and popover UI.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let logger = Logger(subsystem: "boo.peekaboo.app", category: "StatusBar")
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    // State connections
    private let agent: PeekabooAgent
    private let sessionStore: SessionStore
    private let permissions: Permissions
    private let settings: PeekabooSettings
    private let updater: any UpdaterProviding

    /// Icon animation
    private let animationController = MenuBarAnimationController()

    func removeStatusItem() {
        NSStatusBar.system.removeStatusItem(self.statusItem)
    }

    init(
        agent: PeekabooAgent,
        sessionStore: SessionStore,
        permissions: Permissions,
        settings: PeekabooSettings,
        updater: any UpdaterProviding)
    {
        self.agent = agent
        self.sessionStore = sessionStore
        self.permissions = permissions
        self.settings = settings
        self.updater = updater

        // Create status item
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        self.setupStatusItem()
        self.setupPopover()
        self.setupAnimationController()
        self.observeAgentState()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        guard let button = statusItem.button else {
            self.logger.error("StatusBar button is nil - cannot setup status item")
            return
        }

        button.toolTip = "Peekaboo"
        button.title = "Peekaboo"
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("Peekaboo")
        button.setAccessibilityIdentifier("boo.peekaboo.statusItem")

        // Use the MenuIcon asset
        let menuIcon = NSImage(named: "MenuIcon")
        if let menuIcon {
            self.logger.info("MenuIcon loaded successfully: \(menuIcon.size.width)x\(menuIcon.size.height)")
            button.image = menuIcon
            button.image?.isTemplate = true
        } else {
            self.logger.error("Failed to load MenuIcon - using fallback")
            // Create a simple fallback icon
            let fallbackIcon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                NSColor.controlAccentColor.set()
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
                path.fill()
                return true
            }
            fallbackIcon.isTemplate = true
            button.image = fallbackIcon
        }

        button.action = #selector(self.statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        self.logger.info("Status bar button setup complete")
    }

    private func setupAnimationController() {
        // Pass agent reference to animation controller
        self.animationController.setAgent(self.agent)

        // Set up callback to update icon when animation renders new frame
        self.animationController.onIconUpdateNeeded = { [weak self] icon in
            self?.statusItem.button?.image = icon
        }

        // Force initial render
        self.animationController.forceRender()
    }

    private func setupPopover() {
        // Keep the menu bar popover compact and native-looking.
        self.popover.contentSize = NSSize(width: 360, height: 520)
        self.popover.behavior = .transient
        self.popover.animates = false

        let baseView = MenuBarStatusView()
            .environment(self.agent)
            .environment(self.sessionStore)
            .environment(self.settings)

        self.popover.contentViewController = NSHostingController(rootView: baseView)
    }

    // MARK: - Actions

    @objc private func statusItemClicked(_: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            self.showContextMenu(anchorEvent: event)
            return
        }

        if self.settings.agentModeEnabled {
            self.togglePopover()
        } else {
            self.showContextMenu(anchorEvent: event)
        }
    }

    func togglePopover() {
        guard AgentSessionUI.isAvailable(agentModeEnabled: self.settings.agentModeEnabled) else {
            self.dismissAgentUI()
            return
        }

        if self.popover.isShown {
            self.popover.performClose(nil)
        } else {
            guard let button = statusItem.button else { return }
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func dismissAgentUI() {
        if self.popover.isShown {
            self.popover.performClose(nil)
        }
    }

    private func showContextMenu(anchorEvent _: NSEvent) {
        let menu = NSMenu()
        menu.delegate = self
        menu.showsStateColumn = false

        // macOS may inject a “standard” gear icon for a Settings… item in AppKit menus.
        // That icon causes the whole menu to reserve an (empty) image column.
        // Keep the visible title as “Settings…”, but tweak the internal title so the heuristic won’t match.
        let settingsItem = NSMenuItem(
            title: "Settings…\u{200B}",
            action: #selector(self.openSettings),
            keyEquivalent: ",")
        // Some macOS releases appear to key off `attributedTitle` too, so keep the same invisible marker.
        settingsItem.attributedTitle = NSAttributedString(string: "Settings…\u{200B}")
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(
            title: "About Peekaboo",
            action: #selector(self.showAbout),
            keyEquivalent: "")
        menu.addItem(aboutItem)

        let updatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(self.checkForUpdates),
            keyEquivalent: "")
        menu.addItem(updatesItem)

        menu.addItem(NSMenuItem(
            title: "Permissions…",
            action: #selector(self.openPermissions),
            keyEquivalent: ""))

        menu.addItem(NSMenuItem(
            title: "Permissions Onboarding…",
            action: #selector(self.showPermissionsOnboarding),
            keyEquivalent: ""))

        if self.settings.agentModeEnabled {
            let agentMenu = NSMenu()

            if !self.sessionStore.sessions.isEmpty {
                let headerItem = NSMenuItem(title: "Recent Sessions", action: nil, keyEquivalent: "")
                headerItem.isEnabled = false
                agentMenu.addItem(headerItem)

                for session in self.sessionStore.sessions.prefix(5) {
                    let item = NSMenuItem(
                        title: session.title,
                        action: #selector(self.openSession(_:)),
                        keyEquivalent: "")
                    item.representedObject = session.id
                    item.target = self
                    agentMenu.addItem(item)
                }

                agentMenu.addItem(.separator())
            }

            agentMenu.addItem(NSMenuItem(
                title: "Open Peekaboo",
                action: #selector(self.openMainWindow),
                keyEquivalent: "p").with { $0.keyEquivalentModifierMask = [.command, .shift] })

            agentMenu.addItem(NSMenuItem(
                title: "Inspector",
                action: #selector(self.openInspector),
                keyEquivalent: "i").with { $0.keyEquivalentModifierMask = [.command, .shift] })

            let agentItem = NSMenuItem(title: "Agent", action: nil, keyEquivalent: "")
            agentItem.submenu = agentMenu
            menu.addItem(agentItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(self.quit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        // Configure menu items (except quit which needs NSApp as target)
        for item in menu.items where item.action != nil {
            item.target = self
        }

        // macOS may apply “standard” images for common items (Settings/Quit).
        // Strip any images right before display.
        Self.stripMenuItemImages(menu)

        // Follow the system light/dark mode instead of the menu bar's wallpaper-tinted appearance.
        StatusMenuAppearance.pin(menu)

        // Avoid temporarily attaching `statusItem.menu` (which can cause AppKit to inject standard item images,
        // notably for “Settings…”). Instead, pop up the menu directly anchored to the status item button.
        guard let button = self.statusItem.button else { return }
        button.highlight(true)
        defer { button.highlight(false) }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Self.stripMenuItemImages(menu)
    }

    private nonisolated static func stripMenuItemImages(_ menu: NSMenu) {
        for item in menu.items {
            item.image = nil
            item.onStateImage = nil
            item.offStateImage = nil
            item.mixedStateImage = nil
        }
    }

    // MARK: - Menu Actions

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard AgentSessionUI.isAvailable(agentModeEnabled: self.settings.agentModeEnabled),
              let sessionId = sender.representedObject as? String,
              let session = sessionStore.sessions.first(where: { $0.id == sessionId }) else { return }

        // Open session detail window
        NSApp.activate(ignoringOtherApps: true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)

        window.title = session.title
        window.identifier = NSUserInterfaceItemIdentifier(AgentSessionUI.detailWindowIdentifier(sessionID: session.id))
        window.center()
        let rootView = SessionMainWindow()
            .environment(self.sessionStore)
            .environment(self.agent)

        window.contentView = NSHostingView(rootView: rootView)

        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openMainWindow() {
        guard AgentSessionUI.isAvailable(agentModeEnabled: self.settings.agentModeEnabled) else { return }

        self.logger.info("openMainWindow action triggered from menu")

        // First ensure the app is active
        NSApp.activate(ignoringOtherApps: true)

        // Post notification to open main window
        self.logger.info("Posting OpenWindow.main notification")
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
    }

    @objc private func openSettings() {
        SettingsOpener.openSettings()
    }

    @objc private func openPermissions() {
        SettingsOpener.openSettings(tab: .permissions)
    }

    @objc private func showPermissionsOnboarding() {
        PermissionsOnboardingController.shared.show(permissions: self.permissions)
    }

    @objc private func openInspector() {
        self.logger.info("openInspector action triggered from menu")

        // First ensure the app is active
        NSApp.activate(ignoringOtherApps: true)

        // Post notification to trigger window opening
        // The AppDelegate listens for this notification and calls showInspector
        self.logger.info("Posting ShowInspector notification")
        NotificationCenter.default.post(name: .showInspector, object: nil)
    }

    @objc private func showAbout() {
        SettingsOpener.openSettings(tab: .about)
    }

    @objc private func checkForUpdates() {
        self.updater.checkForUpdates(nil)
    }

    // MARK: - Icon Animation

    private func observeAgentState() {
        withObservationTracking {
            // Observe multiple properties to ensure we catch all changes
            _ = self.agent.isProcessing
            _ = self.agent.toolExecutionHistory.count
            _ = self.sessionStore.currentSession?.messages.count ?? 0
        } onChange: {
            Task { @MainActor in
                // Update animation state based on agent processing
                self.animationController.updateAnimationState()

                // The MenuBarStatusView already observes these properties internally
                // so we don't need to refresh the entire popover content
                self.observeAgentState() // Continue observing
            }
        }
    }
}

// MARK: - NSMenuItem Extension

extension NSMenuItem {
    func with(_ configure: (NSMenuItem) -> Void) -> NSMenuItem {
        configure(self)
        return self
    }
}
