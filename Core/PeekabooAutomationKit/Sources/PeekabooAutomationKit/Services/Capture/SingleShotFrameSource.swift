import CoreGraphics
import Foundation
import PeekabooFoundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class SingleShotFrameSource: CaptureFrameSource {
    private let logger: CategoryLogger
    private var currentRequest: CaptureFrameRequest?

    init(logger: CategoryLogger) {
        self.logger = logger
    }

    func start(request: CaptureFrameRequest) async throws {
        self.currentRequest = request
    }

    func stop() async {
        self.currentRequest = nil
    }

    func nextFrame() async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        try await self.nextFrame(maxAge: nil)
    }

    func nextFrame(maxAge _: TimeInterval?) async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        guard let request = self.currentRequest else {
            throw OperationError.captureFailed(reason: "Single-shot capture request missing")
        }

        let display = request.display
        let sourceRect = request.sourceRect
        let scalePlan = Self.scalePlan(for: display, preference: request.scale)
        let scaleFactor = scalePlan.outputScale

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int(sourceRect.width * scaleFactor)
        config.height = Int(sourceRect.height * scaleFactor)
        config.captureResolution = .best
        config.showsCursor = false

        let start = Date()
        let image = try await RetryHandler.withRetry(policy: .standard) {
            try await ScreenCaptureKitCaptureGate.captureImage(
                contentFilter: filter,
                configuration: config)
        }
        let duration = Date().timeIntervalSince(start)
        self.logger.debug(
            "Single-shot capture complete",
            metadata: [
                "durationMs": Int(duration * 1000),
                "displayID": display.displayID,
                "scaleSource": scalePlan.source.rawValue,
            ],
            correlationId: request.correlationId)

        let metadata = CaptureMetadata(
            size: CGSize(width: image.width, height: image.height),
            mode: request.mode,
            displayInfo: DisplayInfo(
                index: request.displayIndex,
                name: request.displayName ?? display.displayID.description,
                bounds: request.displayBounds,
                scaleFactor: scaleFactor),
            timestamp: Date(),
            diagnostics: ScreenCaptureScaleResolver.diagnostics(
                plan: scalePlan,
                finalPixelSize: CGSize(width: image.width, height: image.height)))

        return (cgImage: image, metadata: metadata)
    }

    private nonisolated static func scalePlan(
        for display: SCDisplay,
        preference: CaptureScalePreference) -> ScreenCaptureScaleResolver.Plan
    {
        ScreenCaptureScaleResolver.plan(
            preference: preference,
            displayID: display.displayID,
            fallbackPixelWidth: display.width,
            frameWidth: display.frame.width)
    }
}
