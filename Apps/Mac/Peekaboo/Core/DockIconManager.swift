import AppKit
import os.log

@MainActor
protocol DockIconPreferences: AnyObject {
    var showInDock: Bool { get }
}

extension PeekabooSettings: DockIconPreferences {}

/// Owns activation policy from the Dock preference and unattended-host presentation state.
/// Window visibility and keyboard focus do not determine Dock or Command-Tab presence.
@MainActor
final class DockIconManager {
    /// Shared instance
    static let shared = DockIconManager(
        isBackgroundBridgeHost: PeekabooAppLaunchPolicy.current.isBackgroundBridgeHost,
        applyActivationPolicy: { policy in
            NSApp?.setActivationPolicy(policy)
        })

    private let logger = Logger(subsystem: "boo.peekaboo", category: "DockIconManager")
    private let applyActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    private var settings: (any DockIconPreferences)?
    private var isBackgroundBridgeHost: Bool
    private var didAcceptExplicitPresentation = false

    init(
        isBackgroundBridgeHost: Bool,
        applyActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void)
    {
        self.isBackgroundBridgeHost = isBackgroundBridgeHost
        self.applyActivationPolicy = applyActivationPolicy
        self.updateDockVisibility()
    }

    // MARK: - Public Methods

    /// Connect to settings instance for preference changes
    func connectToSettings(_ settings: any DockIconPreferences) {
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
        if self.isBackgroundBridgeHost, !self.didAcceptExplicitPresentation {
            self.logger.debug("Keeping background Bridge host out of the Dock")
            self.applyActivationPolicy(.accessory)
            return
        }

        let userWantsDockShown = self.settings?.showInDock ?? true // Default to showing
        self.logger.debug("Updating Dock visibility - User wants shown: \(userWantsDockShown)")
        self.applyActivationPolicy(userWantsDockShown ? .regular : .accessory)
    }

    /// Accept an explicit window request without overriding the user's Dock preference.
    /// Callers still own opening and focusing the requested window, including in accessory mode.
    func prepareForPresentation() {
        self.didAcceptExplicitPresentation = true
        self.updateDockVisibility()
    }
}
