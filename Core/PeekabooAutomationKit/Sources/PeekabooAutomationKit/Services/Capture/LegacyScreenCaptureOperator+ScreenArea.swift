import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation
@preconcurrency import ScreenCaptureKit

extension LegacyScreenCaptureOperator {
    func captureScreen(
        displayIndex: Int?,
        correlationId: String,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.logger.debug("Using legacy CGWindowList API for screen capture", correlationId: correlationId)

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            throw OperationError.captureFailed(reason: "No displays available")
        }

        let targetScreen: NSScreen
        if let index = displayIndex {
            guard index >= 0, index < screens.count else {
                throw PeekabooError.invalidInput(
                    "displayIndex: Index \(index) is out of range. Available displays: 0-\(screens.count - 1)")
            }
            targetScreen = screens[index]
        } else {
            targetScreen = screens.first!
        }

        let screenBounds = targetScreen.frame
        let scalePlan = ScreenCaptureScaleResolver.plan(
            preference: scale,
            screenBackingScaleFactor: targetScreen.backingScaleFactor,
            fallbackPixelWidth: Int(screenBounds.width * targetScreen.backingScaleFactor),
            frameWidth: screenBounds.width)
        let image: CGImage
        do {
            image = try self.captureScreenWithSystemScreencapture(
                screen: targetScreen,
                correlationId: correlationId)
        } catch {
            self.logger.error(
                "System screencapture screen capture failed; refusing CGDisplayCreateImage fallback",
                metadata: ["error": String(describing: error)],
                correlationId: correlationId)
            throw error
        }

        let scaledImage = ScreenCaptureImageScaler.maybeDownscale(
            image,
            scale: scale,
            fallbackScale: scalePlan.nativeScale)

        let imageData: Data
        do {
            imageData = try scaledImage.pngData()
        } catch {
            throw OperationError.captureFailed(reason: "Failed to convert image to PNG format")
        }

        self.logger.debug(
            "Legacy screenshot created",
            metadata: [
                "imageSize": "\(scaledImage.width)x\(scaledImage.height)",
                "dataSize": imageData.count,
            ],
            correlationId: correlationId)

        let metadata = CaptureMetadata(
            size: CGSize(width: scaledImage.width, height: scaledImage.height),
            mode: .screen,
            displayInfo: DisplayInfo(
                index: displayIndex ?? 0,
                name: "Display \(displayIndex ?? 0)",
                bounds: screenBounds,
                scaleFactor: scalePlan.outputScale),
            diagnostics: ScreenCaptureScaleResolver.diagnostics(
                plan: scalePlan,
                finalPixelSize: CGSize(width: scaledImage.width, height: scaledImage.height)))

        return CaptureResult(
            imageData: imageData,
            metadata: metadata)
    }

    func captureArea(
        _ rect: CGRect,
        correlationId: String,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.logger.debug("Legacy area capture using CoreGraphics display capture", correlationId: correlationId)

        let displays = Self.activeDisplays()
        guard let display = displays.first(where: { $0.bounds.contains(rect) }) else {
            throw PeekabooError.invalidInput(
                "captureArea: The specified area is not within any display bounds")
        }

        let scalePlan = ScreenCaptureScaleResolver.plan(
            preference: scale,
            displayID: display.id,
            fallbackPixelWidth: CGDisplayPixelsWide(display.id),
            frameWidth: display.bounds.width)
        let image = try self.captureAreaWithSystemScreencapture(
            rect,
            correlationId: correlationId)
        let scaledImage = ScreenCaptureImageScaler.maybeDownscale(
            image,
            scale: scale,
            fallbackScale: scalePlan.nativeScale)
        let imageData = try scaledImage.pngData()
        let metadata = CaptureMetadata(
            size: CGSize(width: scaledImage.width, height: scaledImage.height),
            mode: .area,
            displayInfo: DisplayInfo(
                index: display.index,
                name: display.id.description,
                bounds: rect,
                scaleFactor: scalePlan.outputScale),
            diagnostics: ScreenCaptureScaleResolver.diagnostics(
                plan: scalePlan,
                finalPixelSize: CGSize(width: scaledImage.width, height: scaledImage.height)))

        return CaptureResult(imageData: imageData, metadata: metadata)
    }

    nonisolated static func activeDisplays() -> [(index: Int, id: CGDirectDisplayID, bounds: CGRect)] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return []
        }
        return ids.prefix(Int(count)).enumerated().map { index, id in
            (index: index, id: id, bounds: CGDisplayBounds(id))
        }
    }
}
