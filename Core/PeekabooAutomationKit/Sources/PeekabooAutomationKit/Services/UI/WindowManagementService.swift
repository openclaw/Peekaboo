import AppKit
import Foundation
import os.log
import PeekabooFoundation

/**
 * Window management service providing window control operations using AXorcist.
 *
 * Handles window positioning, resizing, state changes (close/minimize/maximize), and focus
 * management with visual feedback integration. Built on AXorcist accessibility framework
 * for type-safe window operations across applications.
 *
 * ## Core Operations
 * - Window state: close, minimize, maximize, focus
 * - Positioning: move windows to specific coordinates
 * - Resizing: resize windows to specific dimensions
 * - Multi-window support with index-based targeting
 *
 * ## Usage Example
 * ```swift
 * let windowService = WindowManagementService()
 *
 * // Close specific window
 * try await windowService.closeWindow(
 *     target: WindowTarget(appIdentifier: "Safari", windowIndex: 1)
 * )
 *
 * // Move and resize window
 * try await windowService.moveWindow(
 *     target: WindowTarget(appIdentifier: "Terminal"),
 *     position: CGPoint(x: 100, y: 100)
 * )
 * ```
 *
 * - Important: Requires Accessibility permission for window operations
 * - Note: Performance varies 10-200ms depending on operation and application
 * - Since: PeekabooCore 1.0.0
 */
@MainActor
public final class WindowManagementService: WindowManagementServiceProtocol,
    WindowMutationInventoryProviding,
    WindowManagementActionOutcomeProviding,
    WindowManagementActionResultProviding,
    WindowManagementPinnedFocusActionResultProviding
{
    let applicationService: any ApplicationServiceProtocol
    let windowIdentityService = WindowIdentityService()
    let cgInfoLookup: WindowCGInfoLookup
    let logger = Logger(subsystem: "boo.peekaboo.core", category: "WindowManagementService")
    let feedbackClient: any AutomationFeedbackClient
    let operationLaneCoordinator: DesktopOperationLaneCoordinator

    public convenience init(
        applicationService: (any ApplicationServiceProtocol)? = nil,
        feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient())
    {
        self.init(
            applicationService: applicationService,
            feedbackClient: feedbackClient,
            operationLaneCoordinator: .shared)
    }

    init(
        applicationService: (any ApplicationServiceProtocol)? = nil,
        feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient(),
        operationLaneCoordinator: DesktopOperationLaneCoordinator)
    {
        self.applicationService = applicationService ?? ApplicationService()
        self.cgInfoLookup = WindowCGInfoLookup(windowIdentityService: self.windowIdentityService)
        self.feedbackClient = feedbackClient
        self.operationLaneCoordinator = operationLaneCoordinator

        // Only connect to visualizer if we're not running inside the Mac app
        // The Mac app provides the visualizer service, not consumes it
        let isMacApp = Bundle.main.bundleIdentifier?.hasPrefix("boo.peekaboo.mac") == true
        if !isMacApp {
            self.logger.debug("Connecting to visualizer service (running as CLI/external tool)")
            self.feedbackClient.connect()
        } else {
            self.logger.debug("Skipping visualizer connection (running inside Mac app)")
        }
    }
}
