import Foundation
import os.log
import PeekabooFoundation

/**
 * Primary UI automation service orchestrating specialized automation components.
 *
 * Provides unified interface for UI interactions including element detection, clicking, typing,
 * scrolling, and gestures. Delegates to specialized services while managing snapshots and
 * providing visual feedback integration.
 *
 * ## Core Operations
 * - Element detection using AI-powered recognition
 * - Click, type, scroll, hotkey, and gesture operations
 * - Snapshot management for stateful automation workflows
 * - Visual feedback via PeekabooVisualizer integration
 *
 * ## Usage Example
 * ```swift
 * let automation = UIAutomationService()
 *
 * // Detect elements in screenshot
 * let elements = try await automation.detectElements(
 *     in: imageData,
 *     snapshotId: "snapshot_123",
 *     windowContext: windowContext
 * )
 *
 * // Perform automation
 * try await automation.click(
 *     target: .elementId(button.id), clickType: .single, snapshotId: "snapshot_123")
 * try await automation.type(
 *     text: "Hello World", target: textField.id, clearExisting: true, snapshotId: "snapshot_123")
 * ```
 *
 * - Important: Requires Screen Recording and Accessibility permissions
 * - Note: All operations run on MainActor, performance varies 10-800ms by operation
 * - Since: PeekabooCore 1.0.0
 */
@MainActor
public final class UIAutomationService: TargetedHotkeyServiceProtocol, TargetedTypeServiceProtocol,
ExactWindowTargetedClickServiceProtocol {
    let logger = Logger(subsystem: "boo.peekaboo.core", category: "UIAutomationService")
    let snapshotManager: any SnapshotManagerProtocol

    // Specialized services
    let elementDetectionService: ElementDetectionService
    let clickService: ClickService
    let typeService: TypeService
    let scrollService: ScrollService
    let hotkeyService: HotkeyService
    let gestureService: GestureService
    let screenCaptureService: ScreenCaptureService

    let feedbackClient: any AutomationFeedbackClient
    public let inputPolicy: UIInputPolicy
    let actionInputDriver: any ActionInputDriving
    let syntheticInputDriver: any SyntheticInputDriving
    let automationElementResolver: any AutomationElementResolving

    // Search constraints to prevent unbounded AX traversals
    var searchLimits: UIAutomationSearchLimits
    public private(set) var searchPolicy: SearchPolicy

    /**
     * Initialize the UI automation service with optional dependency injection.
     *
     * Creates a new automation service instance with all specialized services properly configured.
     * The service automatically detects its runtime environment and configures visualizer integration
     * appropriately (disabled when running inside the Mac app, enabled for CLI tools).
     *
     * - Parameters:
     *   - snapshotManager: Snapshot manager for state tracking (creates default if nil)
     *   - loggingService: Logging service for debug output (creates default if nil)
     *
     * ## Service Initialization
     * The constructor initializes these specialized services:
     * - `ElementDetectionService` with AX traversal collaborators
     * - `ClickService` for precise mouse interactions
     * - `TypeService` for intelligent text input (note: clickService parameter is nil to avoid circular dependency)
     * - `ScrollService` for smooth scrolling operations
     * - `HotkeyService` for system-level keyboard shortcuts
     * - `GestureService` for complex mouse gestures and drag operations
     * - `ScreenCaptureService` with logging integration
     *
     * ## Visualizer Integration
     * Automatically connects to PeekabooVisualizer for real-time feedback unless running
     * inside the Mac app (bundle ID: "boo.peekaboo.mac"). This prevents the Mac app from
     * trying to connect to itself as a visualizer client.
     *
     * ## Example
     * ```swift
     * // Default initialization
     * let automation = UIAutomationService()
     *
     * // With custom snapshot manager
     * let customSnapshot = SnapshotManager()
     * let automation = UIAutomationService(snapshotManager: customSnapshot)
     * ```
     *
     * - Important: All services are initialized on the main thread due to UI automation requirements
     * - Note: The visualizer connection is established asynchronously and failures are logged but not thrown
     */
    public convenience init(
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        loggingService: (any LoggingServiceProtocol)? = nil,
        searchPolicy: SearchPolicy = .balanced,
        inputPolicy: UIInputPolicy = .currentBehavior,
        feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient())
    {
        self.init(
            snapshotManager: snapshotManager,
            loggingService: loggingService,
            searchPolicy: searchPolicy,
            inputPolicy: inputPolicy,
            actionInputDriver: ActionInputDriver(),
            syntheticInputDriver: SyntheticInputDriver(),
            automationElementResolver: AutomationElementResolver(),
            feedbackClient: feedbackClient)
    }

    init(
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        loggingService: (any LoggingServiceProtocol)? = nil,
        searchPolicy: SearchPolicy = .balanced,
        inputPolicy: UIInputPolicy = .currentBehavior,
        actionInputDriver: any ActionInputDriving,
        syntheticInputDriver: any SyntheticInputDriving = SyntheticInputDriver(),
        automationElementResolver: any AutomationElementResolving,
        feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient())
    {
        let manager = snapshotManager ?? SnapshotManager()
        self.snapshotManager = manager

        let logger = loggingService ?? LoggingService()

        self.searchPolicy = searchPolicy
        self.searchLimits = UIAutomationSearchLimits.from(policy: searchPolicy)
        self.inputPolicy = inputPolicy
        self.actionInputDriver = actionInputDriver
        self.syntheticInputDriver = syntheticInputDriver
        self.automationElementResolver = automationElementResolver
        self.feedbackClient = feedbackClient

        // Initialize specialized services
        self.elementDetectionService = ElementDetectionService(snapshotManager: manager)
        self.clickService = ClickService(
            snapshotManager: manager,
            inputPolicy: inputPolicy,
            actionInputDriver: actionInputDriver,
            syntheticInputDriver: syntheticInputDriver,
            automationElementResolver: automationElementResolver)
        self.typeService = TypeService(
            snapshotManager: manager,
            clickService: nil,
            inputPolicy: inputPolicy,
            actionInputDriver: actionInputDriver,
            syntheticInputDriver: syntheticInputDriver,
            automationElementResolver: automationElementResolver)
        self.scrollService = ScrollService(
            snapshotManager: manager,
            clickService: nil,
            inputPolicy: inputPolicy,
            actionInputDriver: actionInputDriver,
            syntheticInputDriver: syntheticInputDriver,
            automationElementResolver: automationElementResolver)
        self.hotkeyService = HotkeyService(
            inputPolicy: inputPolicy,
            actionInputDriver: actionInputDriver)
        self.gestureService = GestureService()
        let baseCaptureDeps = ScreenCaptureService.Dependencies.live()
        let captureDeps = ScreenCaptureService.Dependencies(
            feedbackClient: feedbackClient,
            permissionEvaluator: baseCaptureDeps.permissionEvaluator,
            fallbackRunner: baseCaptureDeps.fallbackRunner,
            applicationResolver: baseCaptureDeps.applicationResolver,
            makeFrameSource: baseCaptureDeps.makeFrameSource,
            makeModernOperator: baseCaptureDeps.makeModernOperator,
            makeLegacyOperator: baseCaptureDeps.makeLegacyOperator)
        self.screenCaptureService = ScreenCaptureService(loggingService: logger, dependencies: captureDeps)

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
