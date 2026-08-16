import CoreGraphics
import Foundation
import PeekabooFoundation

/**
 * Screen and window capture service with dual API support.
 *
 * Provides fast screen capture using ScreenCaptureKit (modern) or CGWindowList (legacy) APIs.
 * Automatically handles API selection, permission management, and retry logic with visual
 * feedback integration.
 *
 * ## Core Capabilities
 * - Screen capture for specific displays or main display
 * - Window capture with application targeting
 * - Dual API architecture with automatic fallback
 * - Built-in retry logic and permission validation
 *
 * ## Usage Example
 * ```swift
 * let captureService = ScreenCaptureService(loggingService: logger)
 *
 * // Capture main screen
 * let screenResult = try await captureService.captureScreen(displayIndex: nil)
 *
 * // Capture application window
 * let windowResult = try await captureService.captureWindow(
 *     appIdentifier: "Safari",
 *     windowIndex: 0
 * )
 * ```
 *
 * ## API Control
 * Use `PEEKABOO_CAPTURE_ENGINE=auto|modern|sckit|classic|cg` (preferred) or
 * `PEEKABOO_USE_MODERN_CAPTURE=true/false` (legacy) to control engine selection.
 *
 * - Important: Requires Screen Recording permission
 * - Note: Performance 20-150ms depending on operation and display size
 * - Since: PeekabooCore 1.0.0
 */
@MainActor
public final class ScreenCaptureService: ScreenCaptureServiceProtocol, EngineAwareScreenCaptureServiceProtocol {
    @_spi(Testing) public struct Dependencies {
        let feedbackClient: any AutomationFeedbackClient
        let permissionEvaluator: any ScreenRecordingPermissionEvaluating
        let fallbackRunner: ScreenCaptureFallbackRunner
        let applicationResolver: any ApplicationResolving
        let makeFrameSource: @MainActor @Sendable (CategoryLogger) -> any CaptureFrameSource
        let makeModernOperator: @MainActor @Sendable (CategoryLogger, any AutomationFeedbackClient)
            -> any ModernScreenCaptureOperating
        let makeLegacyOperator: @MainActor @Sendable (CategoryLogger)
            -> any LegacyScreenCaptureOperating
        public init(
            feedbackClient: any AutomationFeedbackClient,
            permissionEvaluator: any ScreenRecordingPermissionEvaluating,
            fallbackRunner: ScreenCaptureFallbackRunner,
            applicationResolver: any ApplicationResolving,
            makeFrameSource: @escaping @MainActor @Sendable (CategoryLogger) -> any CaptureFrameSource,
            makeModernOperator: @escaping @MainActor @Sendable (CategoryLogger, any AutomationFeedbackClient)
                -> any ModernScreenCaptureOperating,
            makeLegacyOperator: @escaping @MainActor @Sendable (CategoryLogger)
                -> any LegacyScreenCaptureOperating)
        {
            self.feedbackClient = feedbackClient
            self.permissionEvaluator = permissionEvaluator
            self.fallbackRunner = fallbackRunner
            self.applicationResolver = applicationResolver
            self.makeFrameSource = makeFrameSource
            self.makeModernOperator = makeModernOperator
            self.makeLegacyOperator = makeLegacyOperator
        }

        @MainActor
        static func live(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            applicationResolver: (any ApplicationResolving)? = nil,
            feedbackClient: (any AutomationFeedbackClient)? = nil) -> Dependencies
        {
            let resolver = applicationResolver ?? PeekabooApplicationResolver()
            let frameSourceFactory: @MainActor @Sendable (CategoryLogger) -> any CaptureFrameSource = { logger in
                SingleShotFrameSource(logger: logger)
            }
            return Dependencies(
                feedbackClient: feedbackClient ?? NoopAutomationFeedbackClient(),
                permissionEvaluator: ScreenRecordingPermissionChecker(),
                fallbackRunner: ScreenCaptureFallbackRunner(
                    apis: ScreenCaptureAPIResolver.resolve(environment: environment)),
                applicationResolver: resolver,
                makeFrameSource: frameSourceFactory,
                makeModernOperator: { logger, visualizer in
                    ScreenCaptureKitOperator(
                        logger: logger,
                        feedbackClient: visualizer,
                        frameSource: frameSourceFactory(logger))
                },
                makeLegacyOperator: { logger in
                    LegacyScreenCaptureOperator(logger: logger)
                })
        }
    }

    let logger: CategoryLogger
    let feedbackClient: any AutomationFeedbackClient
    let permissionGate: ScreenCapturePermissionGate
    let fallbackRunner: ScreenCaptureFallbackRunner
    let applicationResolver: any ApplicationResolving
    let modernOperator: any ModernScreenCaptureOperating
    let legacyOperator: any LegacyScreenCaptureOperating
    @TaskLocal static var captureEnginePreference: CaptureEnginePreference = .auto

    public convenience init(
        loggingService: any LoggingServiceProtocol,
        feedbackClient: (any AutomationFeedbackClient)? = nil)
    {
        self.init(loggingService: loggingService, dependencies: .live(feedbackClient: feedbackClient))
    }

    @_spi(Testing) public init(
        loggingService: any LoggingServiceProtocol,
        dependencies: Dependencies)
    {
        self.logger = loggingService.logger(category: LoggingService.Category.screenCapture)
        self.feedbackClient = dependencies.feedbackClient
        self.permissionGate = ScreenCapturePermissionGate(evaluator: dependencies.permissionEvaluator)
        self.fallbackRunner = dependencies.fallbackRunner
        self.applicationResolver = dependencies.applicationResolver
        self.modernOperator = dependencies.makeModernOperator(self.logger, self.feedbackClient)
        self.legacyOperator = dependencies.makeLegacyOperator(self.logger)

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

    public func withCaptureEngine<T: Sendable>(
        _ engine: CaptureEnginePreference,
        operation: @MainActor () async throws -> T) async rethrows -> T
    {
        try await Self.$captureEnginePreference.withValue(engine, operation: operation)
    }

    public func captureScreen(
        displayIndex: Int?,
        visualizerMode: CaptureVisualizerMode = .none,
        scale: CaptureScalePreference = .logical1x) async throws -> CaptureResult
    {
        try await self.captureScreenImpl(
            displayIndex: displayIndex,
            visualizerMode: visualizerMode,
            scale: scale)
    }

    public func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode: CaptureVisualizerMode = .none,
        scale: CaptureScalePreference = .logical1x) async throws -> CaptureResult
    {
        try await self.captureWindowImpl(
            appIdentifier: appIdentifier,
            windowIndex: windowIndex,
            visualizerMode: visualizerMode,
            scale: scale)
    }

    public func captureWindow(
        windowID: CGWindowID,
        visualizerMode: CaptureVisualizerMode = .none,
        scale: CaptureScalePreference = .logical1x) async throws -> CaptureResult
    {
        try await self.captureWindowImpl(
            windowID: windowID,
            visualizerMode: visualizerMode,
            scale: scale)
    }

    public func captureFrontmost(
        visualizerMode: CaptureVisualizerMode = .none,
        scale: CaptureScalePreference = .logical1x) async throws -> CaptureResult
    {
        try await self.captureFrontmostImpl(
            visualizerMode: visualizerMode,
            scale: scale)
    }

    public func captureArea(
        _ rect: CGRect,
        visualizerMode _: CaptureVisualizerMode = .none,
        scale: CaptureScalePreference = .logical1x) async throws -> CaptureResult
    {
        try await self.captureAreaImpl(rect, scale: scale)
    }

    public func hasScreenRecordingPermission() async -> Bool {
        await self.hasScreenRecordingPermissionImpl()
    }
}
