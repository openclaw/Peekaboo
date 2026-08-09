import CoreGraphics
import Foundation

extension DesktopObservationService {
    func capture(
        _ target: ResolvedObservationTarget,
        options: DesktopCaptureOptions,
        snapshot _: DesktopStateSnapshot) async throws -> CaptureResult
    {
        guard let engineAwareCapture = self.engineAwareCapture else {
            return try await self.captureResolvedTarget(target, options: options)
        }

        return try await engineAwareCapture.withCaptureEngine(options.engine) {
            try await self.captureResolvedTarget(target, options: options)
        }
    }

    func captureResolvedTarget(
        _ target: ResolvedObservationTarget,
        options: DesktopCaptureOptions) async throws -> CaptureResult
    {
        switch target.kind {
        case let .screen(index):
            return try await self.screenCapture.captureScreen(
                displayIndex: index,
                visualizerMode: options.visualizerMode,
                scale: options.scale)

        case .frontmost:
            return try await self.screenCapture.captureFrontmost(
                visualizerMode: options.visualizerMode,
                scale: options.scale)

        case .appWindow:
            guard let app = target.app else {
                throw DesktopObservationError.targetNotFound("application window")
            }
            return try await self.screenCapture.captureWindow(
                appIdentifier: app.bundleIdentifier ?? app.name,
                windowIndex: target.window?.index,
                visualizerMode: options.visualizerMode,
                scale: options.scale)

        case let .windowID(windowID):
            return try await self.screenCapture.captureWindow(
                windowID: windowID,
                visualizerMode: options.visualizerMode,
                scale: options.scale)

        case let .area(rect):
            return try await self.screenCapture.captureArea(
                rect,
                visualizerMode: options.visualizerMode,
                scale: options.scale)

        case .menubar:
            guard let bounds = target.bounds else {
                throw DesktopObservationError.targetNotFound("menu bar bounds")
            }
            return try await self.screenCapture.captureArea(
                bounds,
                visualizerMode: options.visualizerMode,
                scale: options.scale)

        case .menubarPopover:
            if let windowID = target.window?.windowID {
                return try await self.screenCapture.captureWindow(
                    windowID: CGWindowID(windowID),
                    visualizerMode: options.visualizerMode,
                    scale: options.scale)
            }
            guard let bounds = target.bounds else {
                throw DesktopObservationError.targetNotFound("menu bar popover bounds")
            }
            return try await self.screenCapture.captureArea(
                bounds,
                visualizerMode: options.visualizerMode,
                scale: options.scale)
        }
    }

    static func normalize(capture: CaptureResult, for target: ResolvedObservationTarget) -> CaptureResult {
        guard
            let resolvedWindow = target.window,
            let capturedWindow = capture.metadata.windowInfo,
            capturedWindow.windowID == resolvedWindow.windowID
        else {
            return capture
        }

        let normalizedWindow = ServiceWindowInfo(
            windowID: capturedWindow.windowID,
            title: resolvedWindow.title.isEmpty ? capturedWindow.title : resolvedWindow.title,
            bounds: capturedWindow.bounds,
            isMinimized: capturedWindow.isMinimized,
            isMainWindow: capturedWindow.isMainWindow,
            isKeyWindow: capturedWindow.isKeyWindow,
            isFrontmost: capturedWindow.isFrontmost,
            subrole: capturedWindow.subrole,
            windowLevel: capturedWindow.windowLevel,
            alpha: capturedWindow.alpha,
            index: resolvedWindow.index,
            spaceID: capturedWindow.spaceID,
            spaceName: capturedWindow.spaceName,
            screenIndex: capturedWindow.screenIndex,
            screenName: capturedWindow.screenName,
            isOffScreen: capturedWindow.isOffScreen,
            layer: capturedWindow.layer,
            isOnScreen: capturedWindow.isOnScreen,
            sharingState: capturedWindow.sharingState,
            isExcludedFromWindowsMenu: capturedWindow.isExcludedFromWindowsMenu,
            mutationIdentity: capturedWindow.mutationIdentity)
        let metadata = CaptureMetadata(
            size: capture.metadata.size,
            mode: capture.metadata.mode,
            videoTimestampMs: capture.metadata.videoTimestampMs,
            applicationInfo: capture.metadata.applicationInfo,
            windowInfo: normalizedWindow,
            displayInfo: capture.metadata.displayInfo,
            timestamp: capture.metadata.timestamp,
            diagnostics: capture.metadata.diagnostics)

        return CaptureResult(
            imageData: capture.imageData,
            savedPath: capture.savedPath,
            metadata: metadata,
            warning: capture.warning)
    }

    nonisolated static func validateCaptureReceipt(
        _ capture: CaptureResult,
        for target: ResolvedObservationTarget) throws
    {
        guard let expected = target.detectionContext?.windowMutationIdentity else {
            return
        }
        guard let expectedBounds = expected.capturedBounds,
              let resolvedApplication = target.app,
              resolvedApplication.processIdentifier == expected.ownerProcessIdentifier,
              resolvedApplication.processStartIdentity == expected.ownerProcessStartIdentity,
              let resolvedWindow = target.window,
              resolvedWindow.windowID == expected.windowID,
              resolvedWindow.bounds == expectedBounds,
              let capturedApplication = capture.metadata.applicationInfo,
              capturedApplication.processIdentifier == expected.ownerProcessIdentifier,
              capturedApplication.processStartIdentity == expected.ownerProcessStartIdentity,
              let capturedWindow = capture.metadata.windowInfo,
              capturedWindow.windowID == expected.windowID,
              capturedWindow.bounds == expectedBounds,
              let capturedIdentity = capturedWindow.mutationIdentity,
              capturedIdentity.windowID == expected.windowID,
              capturedIdentity.ownerProcessIdentifier == expected.ownerProcessIdentifier,
              capturedIdentity.ownerProcessStartIdentity == expected.ownerProcessStartIdentity,
              capturedIdentity.capturedBounds == expectedBounds
        else {
            throw DesktopObservationError.targetChanged(
                "the captured application generation, exact window ID, owner receipt, or bounds no longer " +
                    "matched the resolved target")
        }
    }

    static func bindingCaptureReceipt(
        to target: ResolvedObservationTarget,
        capture: CaptureResult) -> ResolvedObservationTarget
    {
        let capturedApplication = capture.metadata.applicationInfo.map(ApplicationIdentity.init)
        let capturedWindow = capture.metadata.windowInfo.map(WindowIdentity.init)
        return ResolvedObservationTarget(
            kind: target.kind,
            app: capturedApplication ?? target.app,
            window: capturedWindow ?? target.window,
            bounds: capturedWindow?.bounds ?? target.bounds,
            detectionContext: self.windowContext(for: target, capture: capture),
            captureScaleHint: target.captureScaleHint)
    }

    var engineAwareCapture: (any EngineAwareScreenCaptureServiceProtocol)? {
        self.screenCapture as? any EngineAwareScreenCaptureServiceProtocol
    }

    static func captureSpanName(for kind: ResolvedObservationKind) -> String {
        switch kind {
        case .screen:
            "screen"
        case .frontmost:
            "frontmost"
        case .appWindow, .windowID:
            "window"
        case .area, .menubar, .menubarPopover:
            "area"
        }
    }
}
