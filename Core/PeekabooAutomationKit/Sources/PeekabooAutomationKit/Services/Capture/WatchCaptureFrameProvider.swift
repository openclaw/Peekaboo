import CoreGraphics
import Foundation
import PeekabooFoundation

struct WatchCaptureFrame {
    let cgImage: CGImage?
    let metadata: CaptureMetadata
    let motionBoxes: [CGRect]?
}

@MainActor
struct WatchCaptureFrameProvider {
    let screenCapture: any ScreenCaptureServiceProtocol
    let frameSource: (any CaptureFrameSource)?
    let scope: CaptureScope
    let options: CaptureOptions
    let regionValidator: WatchCaptureRegionValidator
    let windowIdentityValidator: @MainActor (WindowMutationIdentity) -> Bool

    init(
        screenCapture: any ScreenCaptureServiceProtocol,
        frameSource: (any CaptureFrameSource)?,
        scope: CaptureScope,
        options: CaptureOptions,
        regionValidator: WatchCaptureRegionValidator,
        windowIdentityValidator: @escaping @MainActor (WindowMutationIdentity) -> Bool = {
            SystemIdentityResolver.validateWindowMutationIdentity($0)
        })
    {
        self.screenCapture = screenCapture
        self.frameSource = frameSource
        self.scope = scope
        self.options = options
        self.regionValidator = regionValidator
        self.windowIdentityValidator = windowIdentityValidator
    }

    func captureFrame() async throws -> (frame: WatchCaptureFrame?, warning: WatchWarning?) {
        if let source = self.frameSource {
            return try await self.captureFrame(from: source)
        }

        let result: CaptureResult
        let warning: WatchWarning?
        let visualizerMode = CaptureVisualizerMode.resolved(
            for: self.options.captureFocus,
            visibleMode: .watchCapture)
        switch self.scope.kind {
        case .screen:
            warning = nil
            result = try await self.screenCapture.captureScreen(
                displayIndex: self.scope.screenIndex,
                visualizerMode: visualizerMode,
                scale: .logical1x)
        case .frontmost:
            warning = nil
            result = try await self.screenCapture.captureFrontmost(
                visualizerMode: visualizerMode,
                scale: .logical1x)
        case .window:
            let identity = try self.exactWindowIdentity()
            try self.validateWindowIdentity(identity, phase: "before")
            warning = nil
            result = try await self.screenCapture.captureWindow(
                windowID: CGWindowID(identity.windowID),
                visualizerMode: visualizerMode,
                scale: .logical1x)
            try self.validateWindowIdentity(identity, phase: "after")
        case .region:
            guard let rect = self.scope.region else {
                throw PeekabooError.captureFailed(reason: "Region missing for watch capture")
            }
            let validation = try self.regionValidator.validateRegion(rect)
            warning = validation.warning
            let screenCapture = self.screenCapture
            let validatedRect = validation.rect
            let captureArea: @MainActor @Sendable () async throws -> CaptureResult = {
                try await screenCapture.captureArea(
                    validatedRect,
                    visualizerMode: visualizerMode,
                    scale: .logical1x)
            }
            if Self.shouldPreferLegacyAreaCapture,
               let engineAware = self.screenCapture as? any EngineAwareScreenCaptureServiceProtocol
            {
                // Live area capture samples repeatedly; prefer the CoreGraphics path in auto mode
                // to avoid ScreenCaptureKit setup races while overlapping observation commands run.
                result = try await engineAware.withCaptureEngine(.legacy, operation: captureArea)
            } else {
                result = try await captureArea()
            }
        }

        guard let image = WatchCaptureArtifactWriter.makeCGImage(from: result.imageData) else {
            return (WatchCaptureFrame(cgImage: nil, metadata: result.metadata, motionBoxes: nil), warning)
        }

        return (
            WatchCaptureFrame(
                cgImage: self.capResolutionIfNeeded(image),
                metadata: result.metadata,
                motionBoxes: nil),
            warning)
    }

    private func captureFrame(from source: any CaptureFrameSource) async throws
        -> (frame: WatchCaptureFrame?, warning: WatchWarning?)
    {
        guard let output = try await source.nextFrame() else { return (nil, nil) }
        guard let image = output.cgImage else {
            return (WatchCaptureFrame(cgImage: nil, metadata: output.metadata, motionBoxes: nil), nil)
        }
        return (
            WatchCaptureFrame(
                cgImage: self.capResolutionIfNeeded(image),
                metadata: output.metadata,
                motionBoxes: nil),
            nil)
    }

    private func capResolutionIfNeeded(_ image: CGImage) -> CGImage {
        guard let cap = self.options.resolutionCap else { return image }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let maxDimension = max(width, height)
        guard maxDimension > cap else { return image }
        let scale = cap / maxDimension
        let newSize = CGSize(width: width * scale, height: height * scale)
        return WatchCaptureArtifactWriter.resize(image: image, to: newSize) ?? image
    }

    private func exactWindowIdentity() throws -> WindowMutationIdentity {
        guard let windowID = self.scope.windowId,
              let identity = self.scope.windowMutationIdentity,
              identity.windowID == Int(windowID),
              identity.capturedBounds != nil
        else {
            throw PeekabooError.windowNotFound(
                criteria: "live window capture requires an exact process-generation and bounds receipt")
        }
        return identity
    }

    private func validateWindowIdentity(
        _ identity: WindowMutationIdentity,
        phase: String) throws
    {
        guard self.windowIdentityValidator(identity) else {
            throw PeekabooError.windowNotFound(
                criteria: "live capture window changed identity \(phase) frame capture")
        }
    }

    @MainActor
    private static var shouldPreferLegacyAreaCapture: Bool {
        let environment = ProcessInfo.processInfo.environment
        let hasExplicitEngine = environment["PEEKABOO_CAPTURE_ENGINE"] != nil ||
            environment["PEEKABOO_USE_MODERN_CAPTURE"] != nil
        return ScreenCaptureService.captureEnginePreference == .auto && !hasExplicitEngine
    }
}
