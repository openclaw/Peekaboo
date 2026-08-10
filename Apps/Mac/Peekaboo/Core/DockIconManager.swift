import AppKit
import os.log

/// Centralized manager for dock icon visibility.
///
/// This manager ensures the dock icon is shown whenever any window is visible,
/// regardless of user preference. It uses KVO to monitor NSApplication.windows
/// and only hides the dock icon when no windows are open AND the user preference
/// is set to hide the dock icon.
///
/// Based on VibeTunnel's implementation, adapted for Peekaboo.
@MainActor
final class DockIconManager: NSObject {
    /// Shared instance
    static let shared = DockIconManager()

    private var windowsObservation: NSKeyValueObservation?
    private let logger = Logger(subsystem: "boo.peekaboo", category: "DockIconManager")
    private var settings: PeekabooSettings?
    private var isBackgroundBridgeHost = false
    private var didAcceptExplicitPresentation = false

    override private init() {
        self.isBackgroundBridgeHost = PeekabooAppLaunchPolicy.current.isBackgroundBridgeHost
        super.init()
        self.setupObservers()
        self.updateDockVisibility()
    }

    deinit {
        self.windowsObservation?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public Methods

    /// Connect to settings instance for preference changes
    func connectToSettings(_ settings: PeekabooSettings) {
        self.settings = settings
        self.updateDockVisibility()
    }

    /// Pins an unattended Bridge host to accessory mode regardless of persisted UI preferences.
    func setBackgroundBridgeHostMode(_ enabled: Bool) {
        self.isBackgroundBridgeHost = enabled
        if !enabled {
            self.didAcceptExplicitPresentation = false
        }
        self.updateDockVisibility()
    }

    /// Update dock visibility based on current state.
    /// Call this when user preferences change or when you need to ensure proper state.
    func updateDockVisibility() {
        // Ensure NSApp is available before proceeding
        guard NSApp != nil else {
            self.logger.warning("NSApp not available yet, skipping dock visibility update")
            return
        }

        if self.isBackgroundBridgeHost, !self.didAcceptExplicitPresentation {
            self.logger.debug("Keeping background Bridge host out of the Dock")
            NSApp.setActivationPolicy(.accessory)
            return
        }

        let userWantsDockShown = self.settings?.showInDock ?? true // Default to showing

        // Count visible windows (excluding panels and hidden windows)
        let visibleWindows = NSApp.windows.filter { window in
            window.isVisible &&
                window.frame.width > 1 && window.frame.height > 1 && // settings window hack
                !window.isKind(of: NSPanel.self) &&
                window.contentViewController != nil &&
                // Exclude the hidden window
                !(window.identifier?.rawValue.contains("HiddenWindow") ?? false)
        }

        let hasVisibleWindows = !visibleWindows.isEmpty

        let message =
            "Updating dock visibility - User wants shown: \(userWantsDockShown), " +
            "Visible windows: \(visibleWindows.count)"
        self.logger.debug("\(message, privacy: .public)")

        // Show dock if user wants it shown OR if any windows are open
        if userWantsDockShown || hasVisibleWindows {
            self.logger.debug("Showing dock icon")
            NSApp.setActivationPolicy(.regular)
        } else {
            self.logger.debug("Hiding dock icon")
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Force show the dock icon temporarily (e.g., when opening a window).
    /// The dock visibility will be properly managed automatically via KVO.
    func temporarilyShowDock() {
        guard NSApp != nil else {
            self.logger.warning("NSApp not available, cannot temporarily show dock")
            return
        }
        self.didAcceptExplicitPresentation = true
        NSApp.setActivationPolicy(.regular)
    }

    // MARK: - Private Methods

    private func setupObservers() {
        // Ensure NSApp is available before setting up observers
        guard NSApp != nil else {
            self.logger.warning("NSApp not available, delaying observer setup")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                self.setupObservers()
            }
            return
        }

        // Observe changes to NSApp.windows using KVO
        if let app = NSApp {
            self.windowsObservation = app.observe(\.windows, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    // Add a small delay to let window state settle
                    try? await Task.sleep(for: .milliseconds(50))
                    self?.updateDockVisibility()
                }
            }
        }

        // Also observe individual window visibility changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.windowVisibilityChanged),
            name: NSWindow.didBecomeKeyNotification,
            object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.windowVisibilityChanged),
            name: NSWindow.didResignKeyNotification,
            object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.windowVisibilityChanged),
            name: NSWindow.willCloseNotification,
            object: nil)
    }

    @objc
    private func windowVisibilityChanged(_: Notification) {
        self.updateDockVisibility()
    }
}
