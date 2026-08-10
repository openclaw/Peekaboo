import AppKit
import AXorcist
import Foundation
import os.log
import PeekabooFoundation

/**
 * Application discovery and management service for macOS automation.
 *
 * Provides intelligent application lookup, window enumeration, and process management.
 * Supports multiple identification formats including PID, bundle ID, application name,
 * and fuzzy matching with defensive programming for app lifecycle complexities.
 *
 * ## Core Capabilities
 * - Application discovery with multiple identifier formats
 * - Window enumeration and counting via accessibility APIs
 * - Process management and focus control
 * - Fuzzy name matching with GUI app preference
 *
 * ## Identification Formats
 * - `"PID:1234"` - Direct process ID lookup
 * - `"com.apple.Safari"` - Bundle identifier matching
 * - `"Safari"` - Name matching (case-insensitive)
 * - `"Saf"` - Fuzzy matching for partial names
 *
 * ## Usage Example
 * ```swift
 * let appService = ApplicationService()
 *
 * // List all applications
 * let result = try await appService.listApplications()
 * for app in result.data.applications {
 *     print("\(app.name): \(app.windowCount) windows")
 * }
 *
 * // Find specific application
 * let safari = try await appService.findApplication(identifier: "Safari")
 * ```
 *
 * - Important: Requires Accessibility permission for window enumeration
 * - Note: Performance 5-200ms depending on operation and system load
 * - Since: PeekabooCore 1.0.0
 */
@MainActor
public final class ApplicationService: ApplicationServiceProtocol {
    public let supportsApplicationLaunchOptions = true
    public let supportsNewApplicationInstanceLaunch = true
    public let supportsApplicationWindowReadiness = true
    public let supportsApplicationRelaunch = true
    public let supportsProcessGenerationPinnedApplicationQuit = true

    struct WindowServerActivationState: Equatable, Sendable {
        let targetHasVisibleWindow: Bool
        let frontmostWindowProcessIdentifier: pid_t?
    }

    typealias ApplicationOpenHandler = @MainActor (
        _ applicationURL: URL,
        _ openURLs: [URL],
        _ configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication
    typealias DefaultApplicationOpenHandler = @MainActor (
        _ targetURL: URL,
        _ configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication
    typealias RelaunchTargetResolver = @MainActor (_ identifier: String) async throws -> ServiceApplicationInfo
    typealias RelaunchQuitHandler = @MainActor (_ request: ApplicationQuitRequest) async throws -> Bool
    typealias RelaunchRunningHandler = @MainActor (_ identifier: String) async throws -> Bool
    typealias ApplicationReadinessHandler = @MainActor (_ application: NSRunningApplication) -> Bool
    typealias ApplicationActivationHandler = @MainActor (_ application: NSRunningApplication) -> Bool
    typealias ApplicationAccessibilityActivationHandler = @MainActor (_ processIdentifier: pid_t) -> Bool
    typealias ApplicationActiveProvider = @MainActor (_ application: NSRunningApplication) -> Bool
    typealias FrontmostProcessIdentifierProvider = @MainActor () -> pid_t?
    typealias WindowServerActivationStateProvider = @MainActor (_ processIdentifier: pid_t)
        -> WindowServerActivationState
    typealias ApplicationActivationSleepHandler = @MainActor (_ duration: Duration) async throws -> Void
    typealias ProcessStartIdentityProvider = @MainActor (_ processIdentifier: pid_t) -> UInt64?
    typealias ApplicationQuitHandler = @MainActor (_ application: NSRunningApplication, _ force: Bool) -> Bool
    typealias BackgroundActivationLeaseFactory = @MainActor (
        _ activationGraceDuration: Duration,
        _ restorationDependencies: BackgroundRestorationDependencies) -> BackgroundLaunchActivationLease

    let logger = Logger(subsystem: "boo.peekaboo.core", category: "ApplicationService")
    let windowIdentityService = WindowIdentityService()
    let permissions: PermissionsService
    let feedbackClient: any AutomationFeedbackClient
    let applicationOpenHandler: ApplicationOpenHandler
    let defaultApplicationOpenHandler: DefaultApplicationOpenHandler
    let relaunchTargetResolver: RelaunchTargetResolver?
    let relaunchQuitHandler: RelaunchQuitHandler?
    let relaunchRunningHandler: RelaunchRunningHandler?
    let applicationReadinessHandler: ApplicationReadinessHandler
    let applicationActivationHandler: ApplicationActivationHandler
    let applicationAccessibilityActivationHandler: ApplicationAccessibilityActivationHandler
    let applicationActiveProvider: ApplicationActiveProvider
    let frontmostProcessIdentifierProvider: FrontmostProcessIdentifierProvider
    let windowServerActivationStateProvider: WindowServerActivationStateProvider
    let applicationActivationSleepHandler: ApplicationActivationSleepHandler
    let processStartIdentityProvider: ProcessStartIdentityProvider
    let applicationQuitHandler: ApplicationQuitHandler
    let applicationReadinessTimeout: TimeInterval
    let applicationActivationTimeout: Duration
    let backgroundLaunchActivationGraceDuration: Duration
    let backgroundOpenActivationGraceDuration: Duration
    let backgroundActivationLeaseFactory: BackgroundActivationLeaseFactory
    let operationLaneCoordinator: DesktopOperationLaneCoordinator

    /// Timeout for accessibility API calls to prevent hangs
    /// AX can be sluggish on some apps (e.g., Arc); allow more headroom.
    static let axTimeout: Float = 10.0

    /// Window inventory is CG-first, so AX is bounded enrichment rather than an authoritative read.
    /// Keep this safely below the Bridge's fixed request deadline so partial CG inventory remains usable.
    static let windowAXEnrichmentTimeout: Float = 2.0

    public convenience init(
        permissions: PermissionsService = PermissionsService(),
        feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient())
    {
        self.init(
            permissions: permissions,
            feedbackClient: feedbackClient,
            operationLaneCoordinator: .shared,
            applicationOpenHandler: { applicationURL, openURLs, configuration in
                if openURLs.isEmpty {
                    return try await NSWorkspace.shared.openApplication(
                        at: applicationURL,
                        configuration: configuration)
                }
                return try await NSWorkspace.shared.open(
                    openURLs,
                    withApplicationAt: applicationURL,
                    configuration: configuration)
            },
            applicationReadinessHandler: Self.isReadyForAutomation)
    }

    init(
        permissions: PermissionsService = PermissionsService(),
        feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient(),
        operationLaneCoordinator: DesktopOperationLaneCoordinator = .shared,
        applicationOpenHandler: @escaping ApplicationOpenHandler,
        defaultApplicationOpenHandler: @escaping DefaultApplicationOpenHandler = { targetURL, configuration in
            try await NSWorkspace.shared.open(targetURL, configuration: configuration)
        },
        relaunchTargetResolver: RelaunchTargetResolver? = nil,
        relaunchQuitHandler: RelaunchQuitHandler? = nil,
        relaunchRunningHandler: RelaunchRunningHandler? = nil,
        applicationReadinessHandler: @escaping ApplicationReadinessHandler = ApplicationService.isReadyForAutomation,
        applicationActivationHandler: @escaping ApplicationActivationHandler = { application in
            application.activate(options: [.activateAllWindows])
        },
        applicationAccessibilityActivationHandler: @escaping ApplicationAccessibilityActivationHandler =
            ApplicationService.requestAccessibilityActivation,
        applicationActiveProvider: @escaping ApplicationActiveProvider = { $0.isActive },
        frontmostProcessIdentifierProvider: @escaping FrontmostProcessIdentifierProvider = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        windowServerActivationStateProvider: @escaping WindowServerActivationStateProvider =
            ApplicationService.windowServerActivationState,
        applicationActivationSleepHandler: @escaping ApplicationActivationSleepHandler = { duration in
            try await Task.sleep(for: duration)
        },
        processStartIdentityProvider: @escaping ProcessStartIdentityProvider = SystemIdentityResolver
            .processStartIdentity,
        applicationQuitHandler: @escaping ApplicationQuitHandler = { application, force in
            force ? application.forceTerminate() : application.terminate()
        },
        applicationReadinessTimeout: TimeInterval = 10,
        applicationActivationTimeout: Duration = .seconds(2),
        backgroundLaunchActivationGraceDuration: Duration = .milliseconds(500),
        backgroundOpenActivationGraceDuration: Duration = .seconds(2),
        backgroundActivationLeaseFactory: @escaping BackgroundActivationLeaseFactory = { duration, dependencies in
            BackgroundLaunchActivationLease(
                activationGraceDuration: duration,
                restorationDependencies: dependencies)
        })
    {
        // Set global AX timeout to prevent hangs
        AXTimeoutConfiguration.setGlobalTimeout(Self.axTimeout)
        self.permissions = permissions
        self.feedbackClient = feedbackClient
        self.operationLaneCoordinator = operationLaneCoordinator
        self.applicationOpenHandler = applicationOpenHandler
        self.defaultApplicationOpenHandler = defaultApplicationOpenHandler
        self.relaunchTargetResolver = relaunchTargetResolver
        self.relaunchQuitHandler = relaunchQuitHandler
        self.relaunchRunningHandler = relaunchRunningHandler
        self.applicationReadinessHandler = applicationReadinessHandler
        self.applicationActivationHandler = applicationActivationHandler
        self.applicationAccessibilityActivationHandler = applicationAccessibilityActivationHandler
        self.applicationActiveProvider = applicationActiveProvider
        self.frontmostProcessIdentifierProvider = frontmostProcessIdentifierProvider
        self.windowServerActivationStateProvider = windowServerActivationStateProvider
        self.applicationActivationSleepHandler = applicationActivationSleepHandler
        self.processStartIdentityProvider = processStartIdentityProvider
        self.applicationQuitHandler = applicationQuitHandler
        self.applicationReadinessTimeout = applicationReadinessTimeout
        self.applicationActivationTimeout = applicationActivationTimeout
        self.backgroundLaunchActivationGraceDuration = backgroundLaunchActivationGraceDuration
        self.backgroundOpenActivationGraceDuration = backgroundOpenActivationGraceDuration
        self.backgroundActivationLeaseFactory = backgroundActivationLeaseFactory

        // Connect to visual feedback if available.
        let isMacApp = Bundle.main.bundleIdentifier?.hasPrefix("boo.peekaboo.mac") == true
        if !isMacApp {
            self.logger.debug("Connecting to visualizer service (running as CLI/external tool)")
            self.feedbackClient.connect()
        } else {
            self.logger.debug("Skipping visualizer connection (running inside Mac app)")
        }
    }
}
