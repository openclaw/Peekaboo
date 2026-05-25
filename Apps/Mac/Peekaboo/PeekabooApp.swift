import AppKit
import KeyboardShortcuts
import os.log
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import SwiftUI
import Tachikoma

@main
struct PeekabooApp: App {
    // Test comment for Poltergeist Mac build v12 - Testing Mac app rebuild detection again
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    @State private var services = PeekabooServices(snapshotManager: InMemorySnapshotManager())
    // Core state - initialized together for proper dependencies
    @State private var settings = PeekabooSettings()
    @State private var sessionStore = SessionStore()
    @State private var permissions = Permissions()

    @State private var agent: PeekabooAgent?

    /// Control Inspector window creation
    @AppStorage("inspectorWindowRequested") private var inspectorRequested = false

    /// Logger
    private let logger = Logger(subsystem: "boo.peekaboo.app", category: "PeekabooApp")

    /// Configure Tachikoma with API keys from settings
    private func configureTachikomaWithSettings() {
        // Use TachikomaConfiguration profile-based loading (env/credentials).
        // Only override when user explicitly enters values in settings.
        if !self.settings.openAIAPIKey.isEmpty { TachikomaConfiguration.current.setAPIKey(
            self.settings.openAIAPIKey,
            for: .openai) }
        if !self.settings.anthropicAPIKey.isEmpty { TachikomaConfiguration.current.setAPIKey(
            self.settings.anthropicAPIKey,
            for: .anthropic) }
        if !self.settings.grokAPIKey.isEmpty { TachikomaConfiguration.current.setAPIKey(
            self.settings.grokAPIKey,
            for: .grok) }
        if !self.settings.googleAPIKey.isEmpty { TachikomaConfiguration.current.setAPIKey(
            self.settings.googleAPIKey,
            for: .google) }
        if !self.settings.miniMaxAPIKey.isEmpty { TachikomaConfiguration.current.setAPIKey(
            self.settings.miniMaxAPIKey,
            for: .minimax) }
        if !self.settings.miniMaxChinaAPIKey.isEmpty { TachikomaConfiguration.current.setAPIKey(
            self.settings.miniMaxChinaAPIKey,
            for: .minimaxCN) }
        if self.settings.ollamaBaseURL != "http://localhost:11434" { TachikomaConfiguration.current.setBaseURL(
            self.settings.ollamaBaseURL,
            for: .ollama) }
    }

    /// Load API keys from credentials file if settings are empty
    private func loadAPIKeysFromCredentials() {
        // Don't load from environment/credentials into settings
        // This allows proper environment variable detection in the UI
        // Tachikoma will handle environment variables directly
    }

    var body: some Scene {
        // Hidden window to make Settings work in MenuBarExtra apps
        // This is a workaround for FB10184971
        WindowGroup("HiddenWindow") {
            HiddenWindowView()
                .task {
                    self.services.installAgentRuntimeDefaults()
                    self.settings.connectServices(self.services)

                    if self.agent == nil {
                        self.agent = PeekabooAgent(
                            settings: self.settings,
                            sessionStore: self.sessionStore,
                            services: self.services)
                    }

                    // Configure Tachikoma with API keys from settings
                    self.configureTachikomaWithSettings()

                    // Set up window opening handler
                    self.appDelegate.windowOpener = { windowId in
                        Task { @MainActor in
                            self.openWindow(id: windowId)
                        }
                    }

                    // Connect app delegate to state
                    let context = AppStateConnectionContext(
                        services: self.services,
                        settings: self.settings,
                        sessionStore: self.sessionStore,
                        permissions: self.permissions,
                        agent: self.agent!)
                    self.appDelegate.connectToState(context)

                    // Check permissions
                    await self.permissions.check()
                    self.appDelegate.maybeShowPermissionsOnboardingIfNeeded()
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 64, height: 64)
        .windowStyle(.hiddenTitleBar)
        .commandsRemoved() // Remove from File menu

        // Main window - Powerful debugging and development interface
        WindowGroup("Peekaboo Sessions", id: "main") {
            SessionMainWindow()
                .environment(self.settings)
                .environment(self.sessionStore)
                .environment(self.permissions)
                .environment(
                    self.agent ?? PeekabooAgent(
                        settings: self.settings,
                        sessionStore: self.sessionStore,
                        services: self.services))
                .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                    // Window will automatically open when this notification is received
                    DispatchQueue.main.async {
                        self.openWindow(id: "main")
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .startNewSession)) { _ in
                    // Handle new session request
                    _ = self.sessionStore.createSession(title: "New Session")
                }
                .onAppear {
                    // Make sure window has proper identifier
                    if let window = NSApp.keyWindow {
                        window.identifier = NSUserInterfaceItemIdentifier("main")
                    }
                }
        }
        .windowResizability(.automatic)
        .defaultSize(width: 900, height: 700)

        // Inspector window
        WindowGroup("Inspector", id: "inspector") {
            if self.inspectorRequested {
                InspectorWindow()
                    .environment(self.settings)
                    .environment(self.permissions)
            } else {
                // Placeholder view until Inspector is actually requested
                Color.clear
                    .frame(width: 1, height: 1)
                    .onAppear {
                        self.logger.info("Inspector window created but not yet requested")
                    }
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 450, height: 700)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))

        // Settings scene
        Settings {
            SettingsWindow(updater: self.appDelegate.updaterController)
                .environment(self.settings)
                .environment(self.permissions)
                .environment(self.appDelegate.visualizerCoordinator ?? VisualizerCoordinator())
                .onAppear {
                    // Ensure visualizer coordinator is available
                    if self.appDelegate.visualizerCoordinator == nil {
                        self.logger.error("VisualizerCoordinator not initialized in AppDelegate")
                    }
                }
        }
    }
}

// MARK: - App Delegate

private struct AppStateConnectionContext {
    let services: PeekabooServices
    let settings: PeekabooSettings
    let sessionStore: SessionStore
    let permissions: Permissions
    let agent: PeekabooAgent
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "boo.peekaboo.app", category: "App")
    private var statusBarController: StatusBarController?
    let updaterController: any UpdaterProviding = makeUpdaterController()
    var windowOpener: ((String) -> Void)?
    private var bridgeHost: PeekabooBridgeHost?
    private var didSchedulePermissionsOnboarding = false

    // State connections
    private var settings: PeekabooSettings?
    private var sessionStore: SessionStore?
    private var permissions: Permissions?
    private var agent: PeekabooAgent?

    // Visualizer components
    var visualizerCoordinator: VisualizerCoordinator?
    private var visualizerEventReceiver: VisualizerEventReceiver?
    private var didConnectDockIconManager = false
    private var didConnectVisualizerSettings = false
    private var didSetupKeyboardShortcuts = false
    private var didSetupNotificationObservers = false

    func applicationDidFinishLaunching(_: Notification) {
        self.logger.info("Peekaboo launching... (Poltergeist test)")
        NSLog("PeekabooApp: applicationDidFinishLaunching")

        // Initialize dock icon manager (it will set the activation policy based on settings) - Test!
        // Don't set activation policy here - let DockIconManager handle it

        // Initialize visualizer components
        self.visualizerCoordinator = VisualizerCoordinator()
        if let coordinator = self.visualizerCoordinator {
            self.visualizerEventReceiver = VisualizerEventReceiver(visualizerCoordinator: coordinator)
        }

        // Status bar will be created after state is connected
    }

    fileprivate func connectToState(_ context: AppStateConnectionContext) {
        self.settings = context.settings
        self.sessionStore = context.sessionStore
        self.permissions = context.permissions
        self.agent = context.agent

        if self.statusBarController == nil {
            self.statusBarController = StatusBarController(
                agent: context.agent,
                sessionStore: context.sessionStore,
                permissions: context.permissions,
                settings: context.settings,
                updater: self.updaterController)
        }

        // Connect dock icon manager to settings
        if !self.didConnectDockIconManager {
            DockIconManager.shared.connectToSettings(context.settings)
            self.didConnectDockIconManager = true
        }

        // Connect visualizer coordinator to settings
        if !self.didConnectVisualizerSettings, let coordinator = self.visualizerCoordinator {
            coordinator.connectSettings(context.settings)
            self.didConnectVisualizerSettings = true
        }

        // Setup keyboard shortcuts
        if !self.didSetupKeyboardShortcuts {
            self.setupKeyboardShortcuts()
            self.didSetupKeyboardShortcuts = true
        }

        // Setup notification observers
        if !self.didSetupNotificationObservers {
            self.setupNotificationObservers()
            self.didSetupNotificationObservers = true
        }

        if self.bridgeHost == nil {
            self.startBridgeHost(services: context.services)
        }

        // Show onboarding if needed
        if self.settings?.agentModeEnabled == true, self.settings?.hasValidAPIKey != true {
            self.showMainWindow()
        }
    }

    func maybeShowPermissionsOnboardingIfNeeded() {
        guard !self.didSchedulePermissionsOnboarding else { return }
        self.didSchedulePermissionsOnboarding = true

        guard let permissions = self.permissions else { return }

        let seenVersion = UserDefaults.standard.integer(forKey: permissionsOnboardingVersionKey)
        let hasSeen = UserDefaults.standard.bool(forKey: permissionsOnboardingSeenKey)
        let shouldShow = seenVersion < currentPermissionsOnboardingVersion || !hasSeen
        guard shouldShow else { return }

        guard !permissions.hasAllPermissions else {
            UserDefaults.standard.set(true, forKey: permissionsOnboardingSeenKey)
            UserDefaults.standard.set(currentPermissionsOnboardingVersion, forKey: permissionsOnboardingVersionKey)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            PermissionsOnboardingController.shared.show(permissions: permissions)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false // Menu bar app stays running
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            self.showMainWindow()
        }
        return false
    }

    func applicationWillTerminate(_: Notification) {
        self.statusBarController?.removeStatusItem()
        self.statusBarController = nil

        if let bridgeHost = self.bridgeHost {
            Task { await bridgeHost.stop() }
        }
    }

    // MARK: - Window Management

    func showMainWindow() {
        self.logger.info("showMainWindow called")

        // Ensure dock icon is visible
        DockIconManager.shared.temporarilyShowDock()

        // Activate the app first
        NSApp.activate(ignoringOtherApps: true)

        // Find or create the main window
        DispatchQueue.main.async {
            self.logger.info("Looking for existing main window...")

            // First try to find an existing main window by identifier
            if let existingWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                self.logger.info("Found existing main window by identifier, bringing to front")
                existingWindow.makeKeyAndOrderFront(nil)
                return
            }

            // Also check by title as fallback
            if let existingWindow = NSApp.windows.first(where: { $0.title == "Peekaboo Sessions" }) {
                self.logger.info("Found existing main window by title, bringing to front")
                existingWindow.makeKeyAndOrderFront(nil)
                return
            }

            self.logger.info("No existing main window found, creating new one")

            // Use the window opener if available
            if let opener = self.windowOpener {
                self.logger.info("Using windowOpener to create main window")
                opener("main")
            } else {
                self.logger.info("No windowOpener available, posting notification")
                // Post notification to open window
                NotificationCenter.default.post(name: .openMainWindow, object: nil)
            }
        }
    }

    func showSettings() {
        SettingsOpener.openSettings()
    }

    func showInspector() {
        self.logger.info("showInspector called")

        // Mark that Inspector has been requested
        UserDefaults.standard.set(true, forKey: "inspectorWindowRequested")

        // Open the inspector window
        self.openWindow(id: "inspector")
    }

    private func openWindow(id: String) {
        self.logger.info("openWindow called with id: \(id)")

        // Ensure dock icon is visible
        DockIconManager.shared.temporarilyShowDock()

        // Use the window opener if available
        if let opener = self.windowOpener {
            self.logger.info("Using windowOpener to open window: \(id)")
            opener(id)
        } else {
            self.logger.info("WindowOpener not available, posting notification")
            // Post notification as fallback
            NotificationCenter.default.post(name: .openWindow(id: id), object: nil)
        }

        // Activate the app
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Notifications

    private func setupNotificationObservers() {
        // Listen for Inspector window request
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.handleShowInspector),
            name: .showInspector,
            object: nil)

        // Listen for keyboard shortcut changes
        // Keyboard shortcuts are now handled automatically by the KeyboardShortcuts library
    }

    @objc private func handleShowInspector() {
        self.logger.info("Received ShowInspector notification")
        // Mark that Inspector has been requested
        UserDefaults.standard.set(true, forKey: "inspectorWindowRequested")
        self.showInspector()
    }

    // MARK: - Keyboard Shortcuts

    private func setupKeyboardShortcuts() {
        // Set up global keyboard shortcuts using KeyboardShortcuts library
        KeyboardShortcuts.onKeyDown(for: .togglePopover) { [weak self] in
            self?.logger.info("Global shortcut triggered: togglePopover")
            self?.statusBarController?.togglePopover()
        }

        KeyboardShortcuts.onKeyDown(for: .showMainWindow) { [weak self] in
            self?.logger.info("Global shortcut triggered: showMainWindow")
            self?.showMainWindow()
        }

        KeyboardShortcuts.onKeyDown(for: .showInspector) { [weak self] in
            self?.logger.info("Global shortcut triggered: showInspector")
            self?.showInspector()
        }
    }

    private func startBridgeHost(services: PeekabooServices) {
        let allowlistedBundles: Set = [
            "boo.peekaboo.peekaboo", // CLI
            "boo.peekaboo.mac", // GUI
        ]
        let allowlistedTeams: Set = ["Y5PE65HELJ"]

        self.logger.info("Starting Peekaboo Bridge at \(PeekabooBridgeConstants.peekabooSocketPath, privacy: .public)")
        self.bridgeHost = PeekabooBridgeBootstrap.startHost(
            services: services,
            hostKind: .gui,
            socketPath: PeekabooBridgeConstants.peekabooSocketPath,
            allowlistedTeams: allowlistedTeams,
            allowlistedBundles: allowlistedBundles,
            allowedOperations: PeekabooBridgeOperation.remoteDefaultAllowlist)
    }

    // MARK: - Public Access

    // Returns the visualizer coordinator for preview functionality
}

// Test comment to trigger build - Wed Jul 30 02:14:41 CEST 2025
