import CoreGraphics
import Foundation
import PeekabooFoundation
@preconcurrency import ScreenCaptureKit

@MainActor
extension ScreenCaptureKitOperator {
    func captureDisplayFrame(
        request: CaptureFrameRequest) async throws -> (image: CGImage, metadata: CaptureMetadata)
    {
        let policy = ScreenCapturePlanner.frameSourcePolicy(for: request.mode, windowID: nil)
        if self.useFastStream, policy == .fastStream {
            do {
                try await self.frameSource.start(request: request)
                if let output = try await self.frameSource.nextFrame(maxAge: nil),
                   let image = output.cgImage
                {
                    return (image: image, metadata: output.metadata)
                }
                throw OperationError.captureFailed(reason: "Fast stream produced no image")
            } catch {
                self.logger.warning(
                    "Fast frame source failed, falling back to single-shot",
                    metadata: ["error": String(describing: error)],
                    correlationId: request.correlationId)
            }
        }

        try await self.fallbackFrameSource.start(request: request)
        guard let output = try await self.fallbackFrameSource.nextFrame(maxAge: nil),
              let image = output.cgImage
        else {
            throw OperationError.captureFailed(reason: "Single-shot produced no image")
        }

        return (image: image, metadata: output.metadata)
    }

    func emitVisualizer(mode: CaptureVisualizerMode, rect: CGRect) async {
        switch mode {
        case .screenshotFlash:
            _ = await self.feedbackClient.showScreenshotFlash(in: rect)
        case .watchCapture:
            _ = await self.feedbackClient.showWatchCapture(in: rect)
        }
    }

    nonisolated static func windowIndexError(requestedIndex: Int, totalWindows: Int) -> String {
        let lastIndex = max(totalWindows - 1, 0)
        return "windowIndex: Index \(requestedIndex) is out of range. Valid windows: 0-\(lastIndex)"
    }

    func scalePlan(
        for display: SCDisplay,
        preference: CaptureScalePreference) -> ScreenCaptureScaleResolver.Plan
    {
        ScreenCaptureScaleResolver.plan(
            preference: preference,
            displayID: display.displayID,
            fallbackPixelWidth: display.width,
            frameWidth: display.frame.width)
    }

    func display(for window: SCWindow, displays: [SCDisplay]) -> SCDisplay? {
        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window.frame,
            displayFrames: displays.map(\.frame))
        switch match {
        case let .mapped(index):
            return displays[index]
        case .unmapped, .noDisplays:
            return nil
        }
    }

    /// Resolve a display for window capture, returning both the chosen display and whether the
    /// window cleanly maps to that display. When the window does not map to any enumerated
    /// display (multi-display setups with partial enumeration, dormant displays, degenerate
    /// window frames), callers should construct a desktop-independent capture filter rather than
    /// throwing — the returned display is still useful for scale and metadata purposes.
    func resolveDisplayForWindow(
        _ window: SCWindow,
        displays: [SCDisplay]) -> (display: SCDisplay, isMapped: Bool)?
    {
        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window.frame,
            displayFrames: displays.map(\.frame))
        switch match {
        case let .mapped(index):
            return (displays[index], true)
        case let .unmapped(fallbackIndex):
            return (displays[fallbackIndex], false)
        case .noDisplays:
            return nil
        }
    }
}
