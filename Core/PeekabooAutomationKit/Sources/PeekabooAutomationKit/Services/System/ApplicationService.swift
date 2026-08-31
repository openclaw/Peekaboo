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
public final class ApplicationService: ApplicationServiceProtocol, ApplicationMutationInventoryProviding,
    ApplicationServiceActionResultProviding, ApplicationServiceTargetedActionResultProviding
{
    public let supportsApplicationLaunchOptions = true
    public let supportsSafeBackgroundApplicationLaunchNoOp = true
    public let supportsNewApplicationInstanceLaunch = true
    public let supportsApplicationWindowReadiness = true
    public let supportsApplicationRelaunch = true
    public let supportsProcessGenerationPinnedApplicationQuit = true
    public let supportsProcessGenerationPinnedApplicationActivation = true
    public let supportsProcessGenerationPinnedApplicationHide = true

    struct WindowServerActivationState: Equatable, Sendable {
        let targetHasVisibleWindow: Bool
        let frontmostWindowProcessIdentifier: pid_t?
    }

    struct ApplicationQuitAttempt: Equatable, Sendable {
        let requestAccepted: Bool
        let terminated: Bool
    }

    struct ApplicationActionDispatch: Equatable, Sendable {
        let delivery: DesktopActionOutcome.Delivery
        let unitCount: DesktopActionOutcome.DispatchUnitCount?

        init(
            delivery: DesktopActionOutcome.Delivery,
            unitCount: DesktopActionOutcome.DispatchUnitCount?)
        {
            self.delivery = delivery
            self.unitCount = unitCount
        }

        init?(
            mechanism: DesktopActionOutcome.Delivery.Mechanism?,
            mode: DesktopActionOutcome.Delivery.Mode,
            acceptedRequestCount: Int?)
        {
            guard let mechanism else { return nil }
            self.delivery = DesktopActionOutcome.Delivery(mechanism: mechanism, mode: mode)
            self.unitCount = acceptedRequestCount.flatMap { count in
                DesktopActionOutcome.DispatchUnitCount(count)
            }
        }
    }

    enum ApplicationVisibilityAttempt: Equatable, Sendable {
        case accepted(ApplicationActionDispatch)
        case rejected
        case mayHaveDispatched(
            delivery: DesktopActionOutcome.Delivery?,
            unitCount: DesktopActionOutcome.DispatchUnitCount?,
            causeDescription: String)
    }

    typealias ApplicationOpenHandler = @MainActor (
        _ applicationURL: URL,
        _ openURLs: [URL],
        _ configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication
    typealias DefaultApplicationOpenHandler = @MainActor (
        _ targetURL: URL,
        _ configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication
    typealias RunningApplicationsForURLProvider = @MainActor (_ applicationURL: URL) -> [NSRunningApplication]
    typealias ApplicationSelectorCandidatesProvider = @MainActor () -> [ApplicationIdentifierMatcher.Candidate]
    typealias ApplicationMutationCandidateProvider = @MainActor (_ processIdentifier: pid_t)
        -> ApplicationIdentifierMatcher.Candidate?
    typealias RelaunchTargetResolver = @MainActor (_ identifier: String) async throws -> ServiceApplicationInfo
    typealias RelaunchQuitHandler = @MainActor (_ request: ApplicationQuitRequest) async throws
        -> ApplicationQuitAttempt
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
    typealias ApplicationHiddenProvider = @MainActor (_ application: NSRunningApplication) throws -> Bool
    typealias ApplicationAccessibilityHideHandler = @MainActor (_ application: NSRunningApplication) throws -> Void
    typealias ApplicationNativeVisibilityHandler = @MainActor (
        _ application: NSRunningApplication,
        _ hidden: Bool) -> Bool
    typealias ApplicationVisibilityHandler = @MainActor (
        _ application: NSRunningApplication,
        _ hidden: Bool) throws -> Bool
    typealias ApplicationVisibilitySleepHandler = @MainActor (_ duration: Duration) async throws -> Void
    typealias RunningApplicationProcessIdentifiersProvider = @MainActor () -> [pid_t]
    typealias ApplicationWindowCatalogProvider = @MainActor () -> [WindowIdentityInfo]?
    typealias ApplicationInventoryNowProvider = @MainActor () -> ContinuousClock.Instant
    typealias ApplicationMetadataProvider = @Sendable (
        _ processIdentifier: pid_t,
        _ processStartIdentity: UInt64?,
        _ timeoutSeconds: TimeInterval) async throws -> DetachedApplicationMetadata

    let logger = Logger(subsystem: "boo.peekaboo.core", category: "ApplicationService")
    let windowIdentityService = WindowIdentityService()
    let permissions: PermissionsService
    let feedbackClient: any AutomationFeedbackClient
    let applicationOpenHandler: ApplicationOpenHandler
    let defaultApplicationOpenHandler: DefaultApplicationOpenHandler
    let runningApplicationsForURLProvider: RunningApplicationsForURLProvider
    let applicationSelectorCandidatesProvider: ApplicationSelectorCandidatesProvider
    let applicationMutationCandidateProvider: ApplicationMutationCandidateProvider
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
    let applicationHiddenProvider: ApplicationHiddenProvider
    let applicationAccessibilityHideHandler: ApplicationAccessibilityHideHandler
    let applicationNativeVisibilityHandler: ApplicationNativeVisibilityHandler
    let applicationVisibilityHandler: ApplicationVisibilityHandler?
    let applicationVisibilitySleepHandler: ApplicationVisibilitySleepHandler
    let runningApplicationProcessIdentifiersProvider: RunningApplicationProcessIdentifiersProvider
    let applicationWindowCatalogProvider: ApplicationWindowCatalogProvider
    let applicationInventoryNowProvider: ApplicationInventoryNowProvider
    let applicationMetadataProvider: ApplicationMetadataProvider
    let applicationMetadataTimeout: TimeInterval
    let applicationInventoryOverallTimeout: TimeInterval
    let maximumConcurrentApplicationMetadataReads: Int
    let applicationReadinessTimeout: TimeInterval
    let applicationActivationTimeout: Duration
    let applicationQuitTimeout: TimeInterval
    let applicationVisibilityTimeout: TimeInterval
    let operationLaneCoordinator: DesktopOperationLaneCoordinator

    /// Timeout for accessibility API calls to prevent hangs
    /// AX can be sluggish on some apps (e.g., Arc); allow more headroom.
    static let axTimeout: Float = 10.0

    /// Window inventory is CG-first, so AX is bounded enrichment rather than an authoritative read.
    /// Keep this safely below the Bridge's fixed request deadline so partial CG inventory remains usable.
    static let windowAXEnrichmentTimeout: Float = 2.0

    /// Caller budgets for metadata enrichment, with eight concurrent waits per inventory. The separate
    /// process-wide metadata pool retains at most eight native operations through autorelease cleanup.
    /// Synchronous inventory seed collection and final generation validation are not hard-bound here.
    static let applicationMetadataTimeout: TimeInterval = 0.25
    static let applicationInventoryOverallTimeout: TimeInterval = 1
    static let maximumConcurrentApplicationMetadataReads = 8

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
        runningApplicationsForURLProvider: @escaping RunningApplicationsForURLProvider = {
            ApplicationService.runningApplicationCandidates(for: $0)
        },
        applicationSelectorCandidatesProvider: @escaping ApplicationSelectorCandidatesProvider = {
            NSWorkspace.shared.runningApplications
                .filter { !$0.isTerminated }
                .map(ApplicationService.identifierCandidate)
        },
        applicationMutationCandidateProvider: @escaping ApplicationMutationCandidateProvider = { pid in
            guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
                return nil
            }
            return ApplicationService.identifierCandidate(application)
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
        applicationHiddenProvider: @escaping ApplicationHiddenProvider = { $0.isHidden },
        applicationAccessibilityHideHandler: @escaping ApplicationAccessibilityHideHandler = { application in
            let element = AXApp(application).element
            try ApplicationService.dispatchApplicationAccessibilityHide(
                isSupported: { element.isActionSupported("AXHide") },
                submit: { try element.performAction(Attribute<String>("AXHide")) })
        },
        applicationNativeVisibilityHandler: @escaping ApplicationNativeVisibilityHandler = { application, hidden in
            ApplicationService.submitNativeApplicationVisibility {
                hidden ? application.hide() : application.unhide()
            }
        },
        applicationVisibilityHandler: ApplicationVisibilityHandler? = nil,
        applicationVisibilitySleepHandler: @escaping ApplicationVisibilitySleepHandler = { duration in
            try await Task.sleep(for: duration)
        },
        runningApplicationProcessIdentifiersProvider: @escaping RunningApplicationProcessIdentifiersProvider = {
            NSWorkspace.shared.runningApplications.map(\.processIdentifier)
        },
        applicationWindowCatalogProvider: @escaping ApplicationWindowCatalogProvider = {
            WindowIdentityService().getWindowCatalog()
        },
        applicationInventoryNowProvider: @escaping ApplicationInventoryNowProvider = { ContinuousClock.now },
        applicationMetadataProvider: @escaping ApplicationMetadataProvider = { pid, generation, timeout in
            try await DetachedApplicationMetadataCoordinator.run(
                processIdentifier: pid,
                processStartIdentity: generation,
                timeoutSeconds: timeout)
        },
        applicationMetadataTimeout: TimeInterval = ApplicationService.applicationMetadataTimeout,
        applicationInventoryOverallTimeout: TimeInterval = ApplicationService.applicationInventoryOverallTimeout,
        maximumConcurrentApplicationMetadataReads: Int = ApplicationService.maximumConcurrentApplicationMetadataReads,
        applicationReadinessTimeout: TimeInterval = 10,
        applicationActivationTimeout: Duration = .seconds(2),
        applicationQuitTimeout: TimeInterval = 3,
        applicationVisibilityTimeout: TimeInterval = 1)
    {
        // Set global AX timeout to prevent hangs
        AXTimeoutConfiguration.setGlobalTimeout(Self.axTimeout)
        self.permissions = permissions
        self.feedbackClient = feedbackClient
        self.operationLaneCoordinator = operationLaneCoordinator
        self.applicationOpenHandler = applicationOpenHandler
        self.defaultApplicationOpenHandler = defaultApplicationOpenHandler
        self.runningApplicationsForURLProvider = runningApplicationsForURLProvider
        self.applicationSelectorCandidatesProvider = applicationSelectorCandidatesProvider
        self.applicationMutationCandidateProvider = applicationMutationCandidateProvider
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
        self.applicationHiddenProvider = applicationHiddenProvider
        self.applicationAccessibilityHideHandler = applicationAccessibilityHideHandler
        self.applicationNativeVisibilityHandler = applicationNativeVisibilityHandler
        self.applicationVisibilityHandler = applicationVisibilityHandler
        self.applicationVisibilitySleepHandler = applicationVisibilitySleepHandler
        self.runningApplicationProcessIdentifiersProvider = runningApplicationProcessIdentifiersProvider
        self.applicationWindowCatalogProvider = applicationWindowCatalogProvider
        self.applicationInventoryNowProvider = applicationInventoryNowProvider
        self.applicationMetadataProvider = applicationMetadataProvider
        self.applicationMetadataTimeout = applicationMetadataTimeout
        self.applicationInventoryOverallTimeout = max(0.001, applicationInventoryOverallTimeout)
        self.maximumConcurrentApplicationMetadataReads = max(1, maximumConcurrentApplicationMetadataReads)
        self.applicationReadinessTimeout = applicationReadinessTimeout
        self.applicationActivationTimeout = applicationActivationTimeout
        self.applicationQuitTimeout = max(0, applicationQuitTimeout)
        self.applicationVisibilityTimeout = max(0, applicationVisibilityTimeout)

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
