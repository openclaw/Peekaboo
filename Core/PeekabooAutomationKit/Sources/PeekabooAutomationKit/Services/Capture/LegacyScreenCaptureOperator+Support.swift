import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation
@preconcurrency import ScreenCaptureKit

extension LegacyScreenCaptureOperator {
    @MainActor
    func captureWindowWithCGWindowList(
        windowID: CGWindowID,
        correlationId: String,
        geometry: LegacyWindowCaptureGeometry) async throws -> LegacyCapturedRaster
    {
        let allowsPrivateSCKLookup = ScreenCaptureService.captureEnginePreference != .legacy
        if Self.privateScreenCaptureKitWindowLookupEnabled(), allowsPrivateSCKLookup {
            do {
                let image = try await self.captureWindowWithPrivateScreenCaptureKit(
                    windowID: windowID,
                    correlationId: correlationId,
                    scale: geometry.scalePlan.preference)
                return try geometry.deliver(
                    LegacyCapturedRaster(image: image),
                    sourceScale: geometry.scalePlan.outputScale)
            } catch {
                guard PrivateScreenCaptureKitWindowLookupPolicy.allowsSystemFallback(
                    after: error,
                    laneIsQuarantined: ScreenCaptureKitCaptureGate.isQuarantined)
                else {
                    throw error
                }
                self.logger.warning(
                    "Private ScreenCaptureKit window capture failed, falling back to system screencapture",
                    metadata: [
                        "windowID": String(windowID),
                        "error": String(describing: error),
                    ],
                    correlationId: correlationId)
            }
        } else {
            self.logger.debug(
                "Private ScreenCaptureKit window lookup disabled, falling back to system screencapture",
                metadata: ["windowID": String(windowID)],
                correlationId: correlationId)
        }

        do {
            let raster = try await self.captureWindowWithSystemScreencapture(
                windowID: windowID,
                correlationId: correlationId)
            return try geometry.deliver(raster, sourceScale: geometry.scalePlan.nativeScale)
        } catch {
            self.logger.error(
                "Isolated system screencapture window capture failed",
                metadata: [
                    "windowID": String(windowID),
                    "error": String(describing: error),
                ],
                correlationId: correlationId)
            throw error
        }
    }

    nonisolated static func windowIndexError(requestedIndex: Int, totalWindows: Int) -> String {
        let lastIndex = max(totalWindows - 1, 0)
        return "windowIndex: Index \(requestedIndex) is out of range. Valid windows: 0-\(lastIndex)"
    }

    nonisolated static func firstRenderableWindowIndex(
        in windows: [[String: Any]]) -> Int?
    {
        windows.indexed().first { indexWindow in
            guard let info = self.makeFilteringInfo(from: indexWindow.element, index: indexWindow.index) else {
                return false
            }
            return WindowFiltering.isRenderable(info)
        }?.index
    }

    nonisolated static func makeFilteringInfo(
        from window: [String: Any],
        index: Int) -> ServiceWindowInfo?
    {
        guard
            let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
            let width = boundsDict["Width"] as? CGFloat,
            let height = boundsDict["Height"] as? CGFloat,
            let x = boundsDict["X"] as? CGFloat,
            let y = boundsDict["Y"] as? CGFloat
        else {
            return nil
        }

        let bounds = CGRect(x: x, y: y, width: width, height: height)
        let windowID = window[kCGWindowNumber as String] as? Int ?? index
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        let alpha = window[kCGWindowAlpha as String] as? CGFloat ?? 1.0
        let isOnScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? true
        let sharingRaw = window[kCGWindowSharingState as String] as? Int
        let sharingState = sharingRaw.flatMap { WindowSharingState(rawValue: $0) }

        return ServiceWindowInfo(
            windowID: windowID,
            title: (window[kCGWindowName as String] as? String) ?? "",
            bounds: bounds,
            isMinimized: false,
            isMainWindow: index == 0,
            windowLevel: layer,
            alpha: alpha,
            index: index,
            isOffScreen: !isOnScreen,
            layer: layer,
            isOnScreen: isOnScreen,
            sharingState: sharingState)
    }

    func scaleFactor(for bounds: CGRect) -> CGFloat {
        let screens = NSScreen.screens
        let appKitBounds = GlobalScreenCoordinateGeometry.appKitRect(
            fromGlobalDisplay: bounds,
            primaryScreenFrame: screens.first?.frame)
        if let screen = screens.first(where: { $0.frame.contains(appKitBounds) }) {
            return screen.backingScaleFactor
        }
        return screens.first?.backingScaleFactor ?? 1.0
    }

    func scalePlan(
        for bounds: CGRect,
        preference: CaptureScalePreference) -> ScreenCaptureScaleResolver.Plan
    {
        let scaleFactor = self.scaleFactor(for: bounds)
        return ScreenCaptureScaleResolver.plan(
            preference: preference,
            screenBackingScaleFactor: scaleFactor,
            fallbackPixelWidth: Int(exactly: bounds.width * scaleFactor) ?? 0,
            frameWidth: bounds.width)
    }

    func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    func makeScreenshotConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.backgroundColor = .clear
        configuration.shouldBeOpaque = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return configuration
    }
}
