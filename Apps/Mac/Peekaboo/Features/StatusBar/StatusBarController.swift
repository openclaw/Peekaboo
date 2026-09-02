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
    private struct ResolvedAutomationTarget {
        let target: AutomationTarget
        let icon: NSImage
    }

    private static let permissionsStatusItemIdentifier = NSUserInterfaceItemIdentifier(
        "boo.peekaboo.statusMenu.permissionsStatus")
    private static let statusIconSize = NSSize(width: 18, height: 18)
    private static let statusIconSpacing: CGFloat = 3

    private let logger = Logger(subsystem: "boo.peekaboo.app", category: "StatusBar")
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    // State connections
    private let agent: PeekabooAgent
    private let sessionStore: SessionStore
    private let permissions: Permissions
    private let settings: PeekabooSettings
    private let updater: any UpdaterProviding
    private let automationTargetTracker: AutomationTargetTracker
    private var latestGhostIcon: NSImage?
    private var resolvedAutomationTargets: [ResolvedAutomationTarget] = []
    private var appearanceObservation: NSKeyValueObservation?

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
        automationTargetTracker: AutomationTargetTracker = AutomationTargetTracker(),
        updater: any UpdaterProviding)
    {
        self.agent = agent
        self.sessionStore = sessionStore
        self.permissions = permissions
        self.settings = settings
        self.automationTargetTracker = automationTargetTracker
        self.updater = updater

        // Create status item
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        self.setupStatusItem()
        self.setupPopover()
        self.setupAnimationController()
        self.observeEffectiveAppearance()
        self.observeAgentState()
        self.automationTargetTracker.setEnabled(self.settings.showAutomationTargetIcons)
        self.updateAutomationTargets(self.automationTargetTracker.activeTargets)
        self.observeAutomationTargetIcons()
        self.observeAutomationTargetIconSetting()
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
            self.latestGhostIcon = menuIcon
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
            self.latestGhostIcon = fallbackIcon
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
            guard let self else { return }
            self.latestGhostIcon = icon
            self.renderStatusItem()
        }

        // Force initial render
        self.animationController.forceRender()
    }

    private func observeAutomationTargetIcons() {
        withObservationTracking {
            _ = self.automationTargetTracker.activeTargets
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateAutomationTargets(self.automationTargetTracker.activeTargets)
                self.observeAutomationTargetIcons()
            }
        }
    }

    private func observeAutomationTargetIconSetting() {
        withObservationTracking {
            _ = self.settings.showAutomationTargetIcons
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.automationTargetTracker.setEnabled(self.settings.showAutomationTargetIcons)
                self.updateAutomationTargets(self.automationTargetTracker.activeTargets)
                self.observeAutomationTargetIconSetting()
            }
        }
    }

    private func observeEffectiveAppearance() {
        let application = NSApplication.shared
        self.appearanceObservation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.renderStatusItem()
            }
        }
    }

    private func updateAutomationTargets(_ targets: [AutomationTarget]) {
        self.resolvedAutomationTargets = targets.compactMap { target -> ResolvedAutomationTarget? in
            guard let icon = self.automationTargetIcon(for: target) else { return nil }
            return ResolvedAutomationTarget(target: target, icon: icon)
        }
        let resolvedTargetCount = self.resolvedAutomationTargets.count
        self.logger.debug("Rendering status item with \(resolvedTargetCount) target icons (\(targets.count) tracked)")
        self.renderStatusItem()
    }

    private func renderStatusItem() {
        guard let button = self.statusItem.button, let ghostIcon = self.latestGhostIcon else { return }

        guard !self.resolvedAutomationTargets.isEmpty else {
            ghostIcon.isTemplate = true
            button.image = ghostIcon
            button.toolTip = "Peekaboo"
            button.setAccessibilityLabel("Peekaboo")
            return
        }

        let appearance = button.effectiveAppearance
        let targetCount = self.resolvedAutomationTargets.count
        let imageWidth = Self.statusIconSize.width * CGFloat(targetCount + 1) +
            Self.statusIconSpacing * CGFloat(targetCount)
        let compositeIcon = NSImage(
            size: NSSize(width: imageWidth, height: Self.statusIconSize.height),
            flipped: false)
        { [resolvedAutomationTargets = self.resolvedAutomationTargets] _ in
            let ghostRect = NSRect(origin: .zero, size: Self.statusIconSize)
            ghostIcon.draw(in: ghostRect)

            let context = NSGraphicsContext.current!.cgContext
            context.saveGState()
            context.setBlendMode(.sourceIn)
            appearance.performAsCurrentDrawingAppearance {
                context.setFillColor(NSColor.labelColor.cgColor)
                context.fill(ghostRect)
            }
            context.restoreGState()

            for (index, resolvedTarget) in resolvedAutomationTargets.enumerated() {
                let x = Self.statusIconSize.width + Self.statusIconSpacing +
                    CGFloat(index) * (Self.statusIconSize.width + Self.statusIconSpacing)
                let iconRect = NSRect(
                    x: x,
                    y: 0,
                    width: Self.statusIconSize.width,
                    height: Self.statusIconSize.height)
                resolvedTarget.icon.draw(in: iconRect)
            }
            return true
        }
        compositeIcon.isTemplate = false
        button.image = compositeIcon

        let names = self.resolvedAutomationTargets.map(\.target.name).joined(separator: ", ")
        let description = "Peekaboo is automating \(names)"
        button.toolTip = description
        button.setAccessibilityLabel(description)

        let frame = button.window?.frame ?? .zero
        self.logger.debug(
            "Status item visible=\(self.statusItem.isVisible) frame=\(String(describing: frame), privacy: .public)")
    }

    private func automationTargetIcon(for target: AutomationTarget) -> NSImage? {
        let sourceIcon: NSImage? = if let runningIcon = NSRunningApplication(processIdentifier: target
            .processIdentifier)?.icon
        {
            runningIcon
        } else if let bundleIdentifier = target.bundleIdentifier,
                  let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        {
            NSWorkspace.shared.icon(forFile: applicationURL.path)
        } else {
            nil
        }

        guard let icon = sourceIcon?.copy() as? NSImage else { return nil }
        icon.size = Self.statusIconSize
        icon.isTemplate = false
        return icon
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
        // Kick off a passive permission check so the status line self-corrects by the next open;
        // deliberately not refresh(): a forced check unlocks the ScreenCaptureKit probe, which
        // may present the system prompt — opening the menu is not grant intent.
        Task { await self.permissions.check() }

        let menu = self.makeContextMenu(
            agentModeEnabled: self.settings.agentModeEnabled,
            sessions: self.sessionStore.sessions)
        self.refreshPermissionsStatus(in: menu)

        // macOS may apply “standard” images for common items (Settings/Quit).
        // Strip any images right before display.
        Self.stripMenuItemImages(menu)

        // Follow the system light/dark mode instead of the menu bar's wallpaper-tinted appearance.
        StatusMenuAppearance.pin(menu)

        // Native status-item anchoring: attach the menu just for this click so AppKit positions it
        // exactly like a system status menu on every display and scale factor, then detach so
        // left-click keeps opening the popover. AppKit's standard-image injection for attached
        // menus is defended twice: menuWillOpen strips images, and “Settings…​” carries a
        // zero-width space so the gear heuristic never matches.
        guard let button = self.statusItem.button else { return }
        self.statusItem.menu = menu
        button.performClick(nil)
        self.statusItem.menu = nil
    }

    func makeContextMenu(agentModeEnabled: Bool, sessions: [ConversationSession]) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.showsStateColumn = false

        let statusItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        statusItem.identifier = Self.permissionsStatusItemIdentifier
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // "Open Peekaboo" is agent-mode-only: openMainWindow no-ops when the agent session UI
        // is unavailable, so showing it for default users would be a dead primary item.
        if agentModeEnabled {
            menu.addItem(NSMenuItem(
                title: "Open Peekaboo",
                action: #selector(self.openMainWindow),
                keyEquivalent: "p").with { $0.keyEquivalentModifierMask = [.command, .shift] })
        }

        menu.addItem(NSMenuItem(
            title: "Inspector",
            action: #selector(self.openInspector),
            keyEquivalent: "i").with { $0.keyEquivalentModifierMask = [.command, .shift] })

        if agentModeEnabled, !sessions.isEmpty {
            let sessionsMenu = NSMenu()

            for session in sessions.prefix(5) {
                let item = NSMenuItem(
                    title: session.title,
                    action: #selector(self.openSession(_:)),
                    keyEquivalent: "")
                item.representedObject = session.id
                item.target = self
                sessionsMenu.addItem(item)
            }

            let sessionsItem = NSMenuItem(title: "Recent Sessions", action: nil, keyEquivalent: "")
            sessionsItem.submenu = sessionsMenu
            menu.addItem(sessionsItem)
        }

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Permissions…",
            action: #selector(self.openPermissions),
            keyEquivalent: ""))

        menu.addItem(.separator())

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

        if self.updater.isAvailable {
            menu.addItem(NSMenuItem(
                title: "Check for Updates…",
                action: #selector(self.checkForUpdates),
                keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem(
            title: "About Peekaboo",
            action: #selector(self.showAbout),
            keyEquivalent: ""))

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Peekaboo", action: #selector(self.quit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        // Configure actionable root items; submenu items already target the controller above.
        for item in menu.items where item.action != nil {
            item.target = self
        }

        return menu
    }

    /// AppKit forbids mutating menu items from menuWillOpen/menuDidClose; the status line is
    /// populated in showContextMenu before the menu is attached. Only image stripping (a
    /// presentation concern AppKit itself introduces late) happens here.
    func menuWillOpen(_ menu: NSMenu) {
        Self.stripMenuItemImages(menu)
    }

    func refreshPermissionsStatus(in menu: NSMenu) {
        guard let statusItem = menu.items.first(where: {
            $0.identifier == Self.permissionsStatusItemIdentifier
        }) else { return }

        let requiredPermissionsAuthorized = self.permissions.screenRecordingStatus == .authorized &&
            self.permissions.accessibilityStatus == .authorized

        if requiredPermissionsAuthorized {
            statusItem.title = "Ready"
            statusItem.action = nil
            statusItem.target = nil
            statusItem.isEnabled = false
        } else {
            statusItem.title = "Permissions required — open checklist"
            statusItem.action = #selector(self.openPermissions)
            statusItem.target = self
            statusItem.isEnabled = true
        }
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
        DockIconManager.shared.prepareForPresentation()
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
        DockIconManager.shared.prepareForPresentation()
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
