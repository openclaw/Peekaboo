import Algorithms
import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation
@preconcurrency import ScreenCaptureKit

@MainActor
extension ScreenCaptureKitOperator {
    struct WindowMetadataContext {
        let mode: CaptureMode
        let applicationInfo: ServiceApplicationInfo?
        let window: SCWindow
        let windowIndex: Int
        let display: SCDisplay
        let displayIndex: Int
        let scalePlan: ScreenCaptureScaleResolver.Plan
    }

    func captureWindowImpl(
        app: ServiceApplicationInfo,
        windowIndex: Int?,
        correlationId: String,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        let content = try await ScreenCaptureKitCaptureGate.shareableContent(
            excludingDesktopWindows: false,
            onScreenWindowsOnly: false)

        let appWindows = content.windows.filter { window in
            window.owningApplication?.processID == app.processIdentifier
        }

        self.logger.debug(
            "Found windows for application",
            metadata: ["count": appWindows.count],
            correlationId: correlationId)
        guard !appWindows.isEmpty else {
            self.logger.error(
                "No windows found for application",
                metadata: ["appName": app.name],
                correlationId: correlationId)
            throw NotFoundError.window(app: app.name)
        }

        let resolvedIndex = try self.resolveWindowIndex(
            requestedIndex: windowIndex,
            windows: appWindows,
            appName: app.name,
            correlationId: correlationId)
        let targetWindow = appWindows[resolvedIndex]

        self.logger.debug(
            "Capturing window",
            metadata: [
                "title": targetWindow.title ?? "untitled",
                "windowID": targetWindow.windowID,
            ],
            correlationId: correlationId)

        guard let resolution = self.resolveDisplayForWindow(targetWindow, displays: content.displays) else {
            throw OperationError.captureFailed(reason: "No displays available for window capture")
        }
        let targetDisplay = resolution.display
        if !resolution.isMapped {
            self.logger.warning(
                "Window does not map to any enumerated display; using desktop-independent capture filter",
                metadata: [
                    "windowID": targetWindow.windowID,
                    "windowFrame": "\(targetWindow.frame)",
                    "displayCount": content.displays.count,
                ],
                correlationId: correlationId)
        }
        let scalePlan = self.scalePlan(for: targetDisplay, preference: scale)
        let image = try await self.captureWindowImage(
            targetWindow,
            scale: scale,
            scalePlan: scalePlan,
            display: targetDisplay,
            useDisplayBoundFilter: resolution.isMapped)
        let imageData = try image.pngData()

        self.logger.debug(
            "Screenshot created",
            metadata: [
                "imageSize": "\(image.width)x\(image.height)",
                "dataSize": imageData.count,
            ],
            correlationId: correlationId)

        await self.emitVisualizer(mode: visualizerMode, rect: targetWindow.frame)

        let metadata = self.windowMetadata(
            image: image,
            context: WindowMetadataContext(
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: app.processIdentifier,
                    bundleIdentifier: app.bundleIdentifier,
                    name: app.name,
                    bundlePath: app.bundlePath),
                window: targetWindow,
                windowIndex: resolvedIndex,
                display: targetDisplay,
                displayIndex: content.displays.firstIndex(where: { $0.displayID == targetDisplay.displayID }) ?? 0,
                scalePlan: scalePlan))

        return CaptureResult(imageData: imageData, metadata: metadata)
    }

    func captureWindowImpl(
        windowID: CGWindowID,
        correlationId: String,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        let content = try await ScreenCaptureKitCaptureGate.shareableContent(
            excludingDesktopWindows: false,
            onScreenWindowsOnly: false)

        guard let targetWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw PeekabooError.windowNotFound(criteria: "window_id \(windowID)")
        }

        let owningPid = targetWindow.owningApplication?.processID
        let appWindows: [SCWindow] = if let owningPid {
            content.windows.filter { $0.owningApplication?.processID == owningPid }
        } else {
            [targetWindow]
        }
        let resolvedIndex = appWindows.firstIndex(where: { $0.windowID == windowID }) ?? 0

        self.logger.debug(
            "Capturing window by id",
            metadata: [
                "title": targetWindow.title ?? "untitled",
                "windowID": targetWindow.windowID,
            ],
            correlationId: correlationId)

        guard let resolution = self.resolveDisplayForWindow(targetWindow, displays: content.displays) else {
            throw OperationError.captureFailed(reason: "No displays available for window capture")
        }
        let targetDisplay = resolution.display
        if !resolution.isMapped {
            self.logger.warning(
                "Window does not map to any enumerated display; using desktop-independent capture filter",
                metadata: [
                    "windowID": targetWindow.windowID,
                    "windowFrame": "\(targetWindow.frame)",
                    "displayCount": content.displays.count,
                ],
                correlationId: correlationId)
        }
        let scalePlan = self.scalePlan(for: targetDisplay, preference: scale)
        let image = try await self.captureWindowImage(
            targetWindow,
            scale: scale,
            scalePlan: scalePlan,
            display: targetDisplay,
            useDisplayBoundFilter: resolution.isMapped)
        let imageData = try image.pngData()

        await self.emitVisualizer(mode: visualizerMode, rect: targetWindow.frame)

        let metadata = self.windowMetadata(
            image: image,
            context: WindowMetadataContext(
                mode: .window,
                applicationInfo: self.applicationInfo(for: owningPid, windowCount: appWindows.count),
                window: targetWindow,
                windowIndex: resolvedIndex,
                display: targetDisplay,
                displayIndex: content.displays.firstIndex(where: { $0.displayID == targetDisplay.displayID }) ?? 0,
                scalePlan: scalePlan))

        return CaptureResult(imageData: imageData, metadata: metadata)
    }

    func resolveWindowIndex(
        requestedIndex: Int?,
        windows: [SCWindow],
        appName: String,
        correlationId: String) throws -> Int
    {
        if let requestedIndex {
            guard requestedIndex >= 0, requestedIndex < windows.count else {
                let message = Self.windowIndexError(
                    requestedIndex: requestedIndex,
                    totalWindows: windows.count)
                throw PeekabooError.invalidInput(message)
            }
            return requestedIndex
        }

        if let candidateIndex = Self.firstRenderableWindowIndex(in: windows) {
            if candidateIndex != 0 {
                self.logger.debug(
                    "Auto-selected visible SCWindow",
                    metadata: ["index": candidateIndex],
                    correlationId: correlationId)
            }
            return candidateIndex
        }

        self.logger.warning(
            "Falling back to first SCWindow; no renderable windows detected",
            metadata: ["app": appName],
            correlationId: correlationId)
        return 0
    }

    func captureWindowImage(
        _ window: SCWindow,
        scale: CaptureScalePreference,
        scalePlan: ScreenCaptureScaleResolver.Plan,
        display: SCDisplay,
        useDisplayBoundFilter: Bool = true) async throws -> CGImage
    {
        try await RetryHandler.withRetry(policy: .standard) {
            try await self.createScreenshot(
                of: window,
                scale: scale,
                targetScale: scalePlan.nativeScale,
                display: display,
                useDisplayBoundFilter: useDisplayBoundFilter)
        }
    }

    /// Capture a window screenshot.
    ///
    /// When `useDisplayBoundFilter` is `true` (the default), uses `SCContentFilter(display:including:)`
    /// which stays reliable for GPU-rendered windows such as the iOS Simulator. When `false`, falls
    /// back to `SCContentFilter(desktopIndependentWindow:)` — the ScreenCaptureKit API designed to
    /// capture a window without needing to identify which display it lives on. The fallback path is
    /// used when display resolution failed (multi-display setups with partial enumeration), keeping
    /// the iOS Simulator behavior intact for the common case.
    func createScreenshot(
        of window: SCWindow,
        scale: CaptureScalePreference,
        targetScale: CGFloat,
        display: SCDisplay,
        useDisplayBoundFilter: Bool = true) async throws -> CGImage
    {
        let scaleValue = scale == .native ? targetScale : 1.0
        let width = Int(window.frame.width * scaleValue)
        let height = Int(window.frame.height * scaleValue)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.captureResolution = .best
        config.showsCursor = false

        let filter: SCContentFilter
        if useDisplayBoundFilter {
            filter = SCContentFilter(display: display, including: [window])
            // `window.frame` is global desktop coordinates; display-bound filters require display-local `sourceRect`.
            config.sourceRect = ScreenCapturePlanner.displayLocalSourceRect(
                globalRect: window.frame,
                displayFrame: display.frame)
        } else {
            // `desktopIndependentWindow` captures the window's full content without referencing any
            // display, so no `sourceRect` is needed. This rescues capture on multi-display Macs where
            // `SCShareableContent.displays` enumeration misses the display the window actually lives on.
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        return try await ScreenCaptureKitCaptureGate.captureImage(
            contentFilter: filter,
            configuration: config)
    }

    func windowMetadata(
        image: CGImage,
        context: WindowMetadataContext) -> CaptureMetadata
    {
        CaptureMetadata(
            size: CGSize(width: image.width, height: image.height),
            mode: context.mode,
            applicationInfo: context.applicationInfo,
            windowInfo: ServiceWindowInfo(
                windowID: Int(context.window.windowID),
                title: context.window.title ?? "",
                bounds: context.window.frame,
                isMinimized: false,
                isMainWindow: context.window.isOnScreen,
                windowLevel: 0,
                alpha: 1.0,
                index: context.windowIndex,
                isOffScreen: !context.window.isOnScreen,
                layer: 0,
                isOnScreen: context.window.isOnScreen),
            displayInfo: DisplayInfo(
                index: context.displayIndex,
                name: context.display.displayID.description,
                bounds: context.display.frame,
                scaleFactor: context.scalePlan.outputScale),
            diagnostics: ScreenCaptureScaleResolver.diagnostics(
                plan: context.scalePlan,
                finalPixelSize: CGSize(width: image.width, height: image.height)))
    }

    func applicationInfo(for processID: pid_t?, windowCount: Int) -> ServiceApplicationInfo? {
        guard let processID,
              let runningApplication = NSRunningApplication(processIdentifier: processID)
        else {
            return nil
        }

        return ServiceApplicationInfo(
            processIdentifier: runningApplication.processIdentifier,
            bundleIdentifier: runningApplication.bundleIdentifier,
            name: runningApplication.localizedName ?? runningApplication.bundleIdentifier ?? "Unknown",
            bundlePath: runningApplication.bundleURL?.path,
            isActive: runningApplication.isActive,
            isHidden: runningApplication.isHidden,
            windowCount: windowCount)
    }

    nonisolated static func firstRenderableWindowIndex(in windows: [SCWindow]) -> Int? {
        for (index, window) in windows.indexed() {
            guard let info = self.makeFilteringInfo(from: window, index: index) else { continue }
            guard WindowFiltering.isRenderable(info) else { continue }
            return index
        }
        return nil
    }

    nonisolated static func makeFilteringInfo(from window: SCWindow, index: Int) -> ServiceWindowInfo? {
        ServiceWindowInfo(
            windowID: Int(window.windowID),
            title: window.title ?? "",
            bounds: window.frame,
            isMinimized: false,
            isMainWindow: window.isOnScreen,
            windowLevel: 0,
            alpha: 1.0,
            index: index,
            isOffScreen: !window.isOnScreen,
            layer: 0,
            isOnScreen: window.isOnScreen)
    }
}
