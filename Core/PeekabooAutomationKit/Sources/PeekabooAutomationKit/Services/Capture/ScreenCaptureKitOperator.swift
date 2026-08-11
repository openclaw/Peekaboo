import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
final class ScreenCaptureKitOperator: ModernScreenCaptureOperating {
    let logger: CategoryLogger
    let feedbackClient: any AutomationFeedbackClient
    let frameSource: any CaptureFrameSource
    let exactWindowPlanCache = ScreenCaptureKitWindowPlanCache<ExactWindowCapturePlan>()
    var nextExactWindowPlanGeneration: UInt64 = 1

    init(
        logger: CategoryLogger,
        feedbackClient: any AutomationFeedbackClient,
        frameSource: any CaptureFrameSource)
    {
        self.logger = logger
        self.feedbackClient = feedbackClient
        self.frameSource = frameSource
    }

    func captureScreen(
        displayIndex: Int?,
        correlationId: String,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        try await self.captureScreenImpl(
            displayIndex: displayIndex,
            correlationId: correlationId,
            visualizerMode: visualizerMode,
            scale: scale)
    }

    func captureWindow(
        app: ServiceApplicationInfo,
        windowIndex: Int?,
        correlationId: String,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        try await self.captureWindowImpl(
            app: app,
            windowIndex: windowIndex,
            correlationId: correlationId,
            visualizerMode: visualizerMode,
            scale: scale)
    }

    func captureWindow(
        windowID: CGWindowID,
        correlationId: String,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        try await self.captureWindowImpl(
            windowID: windowID,
            correlationId: correlationId,
            visualizerMode: visualizerMode,
            scale: scale)
    }

    func captureArea(
        _ rect: CGRect,
        correlationId: String,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        try await self.captureAreaImpl(rect, correlationId: correlationId, scale: scale)
    }
}
