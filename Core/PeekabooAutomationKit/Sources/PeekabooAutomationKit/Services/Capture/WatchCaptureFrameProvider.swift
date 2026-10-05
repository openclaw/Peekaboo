import CoreGraphics
import Foundation
import ImageIO
import PeekabooFoundation
import UniformTypeIdentifiers

struct WatchCaptureFrame {
    let cgImage: CGImage?
    let metadata: CaptureMetadata
    let motionBoxes: [CGRect]?
    private let sourcePNG: Data?

    init(cgImage: CGImage?, metadata: CaptureMetadata, motionBoxes: [CGRect]?) {
        self.cgImage = cgImage
        self.metadata = metadata
        self.motionBoxes = motionBoxes
        self.sourcePNG = nil
    }

    init(
        imageData: Data,
        metadata: CaptureMetadata,
        preservePNG: Bool = true,
        transform: (CGImage) -> CGImage)
    {
        self.metadata = metadata
        self.motionBoxes = nil
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            self.cgImage = nil
            self.sourcePNG = nil
            return
        }
        let image = transform(decoded)
        self.cgImage = image
        self.sourcePNG = preservePNG && image === decoded &&
            imageData.count <= CaptureArtifactIntegrityValidator.maximumPNGBytes &&
            CGImageSourceGetType(source) as String? == UTType.png.identifier &&
            CGImageSourceGetCount(source) == 1 &&
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete ? imageData : nil
    }

    func sourcePNG(for image: CGImage) -> Data? {
        // Identity proves neither the resolution cap nor the saving path replaced the decoded pixels.
        guard let cgImage, image === cgImage, let sourcePNG,
              LegacyPNGValidator.hasValidStructureAndCRC(sourcePNG),
              LegacyPNGValidator.hasCompletePixelData(image)
        else { return nil }
        return sourcePNG
    }
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
            if self.screenCapture.captureTransactionGateOwner == .caller,
               Self.shouldPreferLegacyAreaCapture,
               let engineAware = self.screenCapture as? any EngineAwareScreenCaptureServiceProtocol
            {
                // Live area capture samples repeatedly; prefer the CoreGraphics path in auto mode
                // only for caller-owned capture. Remote services own their request's engine policy.
                result = try await engineAware.withCaptureEngine(.legacy, operation: captureArea)
            } else {
                result = try await captureArea()
            }
        }

        return (
            WatchCaptureFrame(
                imageData: result.imageData,
                metadata: result.metadata,
                preservePNG: !self.options.highlightChanges,
                transform: self.capResolutionIfNeeded),
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
