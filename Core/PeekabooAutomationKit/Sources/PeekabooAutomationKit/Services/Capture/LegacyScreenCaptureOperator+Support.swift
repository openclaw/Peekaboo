import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation
@preconcurrency import ScreenCaptureKit

extension LegacyScreenCaptureOperator {
    func captureDisplayWithScreenshotManager(
        screen: NSScreen,
        displayIndex: Int,
        correlationId: String) async throws -> CGImage
    {
        let content = try await ScreenCaptureKitCaptureGate.currentShareableContent()
        let displays = content.displays
        guard !displays.isEmpty else {
            throw OperationError.captureFailed(reason: "No ScreenCaptureKit displays available")
        }

        let display = try self.resolveDisplay(
            for: screen,
            displayIndex: displayIndex,
            availableDisplays: displays)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        self.logger.debug(
            "Capturing display via SCScreenshotManager",
            metadata: [
                "displayIndex": displayIndex,
                "displayID": display.displayID,
            ],
            correlationId: correlationId)

        return try await ScreenCaptureKitCaptureGate.captureImage(
            contentFilter: filter,
            configuration: self.makeScreenshotConfiguration())
    }

    func resolveDisplay(
        for screen: NSScreen,
        displayIndex: Int,
        availableDisplays: [SCDisplay]) throws -> SCDisplay
    {
        if let displayID = self.displayID(for: screen),
           let display = availableDisplays.first(where: { $0.displayID == displayID })
        {
            return display
        }

        guard displayIndex >= 0, displayIndex < availableDisplays.count else {
            throw PeekabooError
                .invalidInput("displayIndex \(displayIndex) is out of range for ScreenCaptureKit displays")
        }

        return availableDisplays[displayIndex]
    }

    func captureWindowWithScreenshotManager(
        windowID: CGWindowID,
        correlationId: String) async throws -> CGImage
    {
        try await RetryHandler.withRetry(policy: .standard) {
            try await self.captureWindowWithScreenshotManagerAttempt(
                windowID: windowID,
                correlationId: correlationId)
        }
    }

    private func captureWindowWithScreenshotManagerAttempt(
        windowID: CGWindowID,
        correlationId: String) async throws -> CGImage
    {
        let content = try await ScreenCaptureKitCaptureGate.shareableContent(
            excludingDesktopWindows: false,
            onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw OperationError.captureFailed(
                reason: "Window \(windowID) is not in ScreenCaptureKit shareable content " +
                    "(it may be minimized, off-screen, or on another Space)")
        }

        let displayFrames = content.displays.map(\.frame)
        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: scWindow.frame,
            displayFrames: displayFrames)

        let mappedDisplay: SCDisplay?
        let scaleSourceDisplay: SCDisplay
        switch match {
        case .noDisplays:
            throw OperationError.captureFailed(
                reason: "No displays available for window \(windowID) capture")
        case let .mapped(index):
            mappedDisplay = content.displays[index]
            scaleSourceDisplay = content.displays[index]
        case let .unmapped(fallbackIndex):
            mappedDisplay = nil
            scaleSourceDisplay = content.displays[fallbackIndex]
            self.logger.warning(
                "Window does not map to any enumerated display; using desktop-independent capture filter",
                metadata: [
                    "windowID": windowID,
                    "windowFrame": "\(scWindow.frame)",
                    "displayCount": content.displays.count,
                ],
                correlationId: correlationId)
        }

        let nativeScale = ScreenCaptureScaleResolver.plan(
            preference: .native,
            displayID: scaleSourceDisplay.displayID,
            fallbackPixelWidth: scaleSourceDisplay.width,
            frameWidth: scaleSourceDisplay.frame.width).nativeScale

        let config = self.makeScreenshotConfiguration()
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        if #available(macOS 14.2, *) {
            config.includeChildWindows = false
        }

        let filter: SCContentFilter
        let pixelSize: (width: Int, height: Int)
        if let display = mappedDisplay {
            filter = SCContentFilter(display: display, including: [scWindow])
            pixelSize = ScreenCapturePlanner.capturePixelSize(for: scWindow.frame, scale: nativeScale)
            // Display-bound filters expect display-local geometry. This mirrors the reliable modern path and keeps
            // single-shot captures crisp without relying on the obsolete CoreGraphics window API.
            config.sourceRect = ScreenCapturePlanner.displayLocalSourceRect(
                globalRect: scWindow.frame,
                displayFrame: display.frame)
            self.logger.debug(
                "Capturing window via display-bound SCScreenshotManager",
                metadata: [
                    "windowID": windowID,
                    "displayID": display.displayID,
                ],
                correlationId: correlationId)
        } else {
            filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let filterScale = CGFloat(filter.pointPixelScale)
            let outputScale = filterScale.isFinite && filterScale > 0 ? filterScale : nativeScale
            pixelSize = ScreenCapturePlanner.capturePixelSize(
                for: filter.contentRect,
                fallbackFrame: scWindow.frame,
                scale: outputScale)
            self.logger.debug(
                "Capturing window via desktop-independent SCScreenshotManager filter",
                metadata: ["windowID": windowID],
                correlationId: correlationId)
        }
        config.width = pixelSize.width
        config.height = pixelSize.height

        return try await ScreenCaptureKitCaptureGate.captureImage(
            contentFilter: filter,
            configuration: config)
    }

    @MainActor
    func captureWindowWithCGWindowList(
        windowID: CGWindowID,
        correlationId: String) async throws -> CGImage
    {
        if Self.privateScreenCaptureKitWindowLookupEnabled() {
            do {
                return try await self.captureWindowWithPrivateScreenCaptureKit(
                    windowID: windowID,
                    correlationId: correlationId)
            } catch {
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
            return try self.captureWindowWithSystemScreencapture(
                windowID: windowID,
                correlationId: correlationId)
        } catch {
            self.logger.warning(
                "System screencapture window capture failed, falling back to SCScreenshotManager",
                metadata: [
                    "windowID": String(windowID),
                    "error": String(describing: error),
                ],
                correlationId: correlationId)
            return try await self.captureWindowWithScreenshotManager(
                windowID: windowID,
                correlationId: correlationId)
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

    func shouldUseLegacyCGCapture() -> Bool {
        if ScreenCaptureService.captureEnginePreference == .legacy {
            return true
        }

        #if os(macOS)
        if #available(macOS 14.0, *) {
            let env = ProcessInfo.processInfo.environment["PEEKABOO_ALLOW_LEGACY_CAPTURE"]?.lowercased()
            return env.map { ["1", "true", "yes"].contains($0) } ?? false
        }
        return true
        #else
        return false
        #endif
    }

    func scaleFactor(for bounds: CGRect) -> CGFloat {
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(bounds) }) {
            return screen.backingScaleFactor
        }
        return NSScreen.main?.backingScaleFactor ?? 1.0
    }

    func scalePlan(
        for bounds: CGRect,
        preference: CaptureScalePreference) -> ScreenCaptureScaleResolver.Plan
    {
        let scaleFactor = self.scaleFactor(for: bounds)
        return ScreenCaptureScaleResolver.plan(
            preference: preference,
            screenBackingScaleFactor: scaleFactor,
            fallbackPixelWidth: Int(bounds.width * scaleFactor),
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
