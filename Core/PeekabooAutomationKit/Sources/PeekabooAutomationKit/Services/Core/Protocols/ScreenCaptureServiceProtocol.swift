import CoreGraphics
import Foundation

public enum CaptureVisualizerMode: Sendable, Codable, Equatable {
    case none
    case screenshotFlash
    case watchCapture

    public static func resolved(
        for focus: CaptureFocus,
        visibleMode: CaptureVisualizerMode) -> CaptureVisualizerMode
    {
        focus == .background ? .none : visibleMode
    }
}

/// Preferred output scale for captures
public enum CaptureScalePreference: Sendable, Codable, Equatable {
    /// Store images at logical 1x resolution (default)
    case logical1x
    /// Store images at the display's native pixel scale (e.g., 2x on Retina)
    case native
}

/// Identifies which side of a capture-service boundary owns transaction-level serialization.
///
/// A higher-level observation normally holds the caller-side gate across target resolution and capture. A service
/// that crosses an IPC boundary must instead coordinate on the execution host: holding the same cross-process lock
/// in the client while asking the host to acquire it would deadlock.
public enum CaptureTransactionGateOwner: Sendable, Equatable {
    case caller
    case service
}

/// Protocol defining screen capture operations
@MainActor
public protocol ScreenCaptureServiceProtocol: Sendable {
    /// The side responsible for serializing a complete capture transaction.
    var captureTransactionGateOwner: CaptureTransactionGateOwner { get }

    /// Capture the entire screen or a specific display
    /// - Parameter displayIndex: Optional display index (0-based). If nil, captures main display
    /// - Returns: Result containing the captured image and metadata
    func captureScreen(
        displayIndex: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult

    /// Capture a specific window from an application
    /// - Parameters:
    ///   - appIdentifier: Application name or bundle ID
    ///   - windowIndex: Optional window index (0-based). If nil, captures frontmost window
    /// - Returns: Result containing the captured image and metadata
    func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult

    /// Capture a specific window by CoreGraphics window id (CGWindowID).
    ///
    /// Use this when you need deterministic window targeting (e.g. multiple same-titled documents).
    func captureWindow(
        windowID: CGWindowID,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult

    /// Capture the frontmost window of the frontmost application
    /// - Returns: Result containing the captured image and metadata
    func captureFrontmost(
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult

    /// Capture a specific area of the screen
    /// - Parameter rect: The rectangle to capture in screen coordinates
    /// - Returns: Result containing the captured image and metadata
    func captureArea(
        _ rect: CGRect,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult

    /// Check if screen recording permission is granted
    /// - Returns: True if permission is granted
    func hasScreenRecordingPermission() async -> Bool
}

@MainActor
public protocol EngineAwareScreenCaptureServiceProtocol: ScreenCaptureServiceProtocol {
    /// Observation can honor per-request engine choices without forcing every remote/mock capture service to grow
    /// engine-specific overloads.
    func withCaptureEngine<T: Sendable>(
        _ engine: CaptureEnginePreference,
        operation: @MainActor () async throws -> T) async rethrows -> T
}

extension ScreenCaptureServiceProtocol {
    public var captureTransactionGateOwner: CaptureTransactionGateOwner {
        .caller
    }

    public func captureScreen(displayIndex: Int?) async throws -> CaptureResult {
        try await self.captureScreen(
            displayIndex: displayIndex,
            visualizerMode: .none,
            scale: .logical1x)
    }

    public func captureWindow(appIdentifier: String, windowIndex: Int?) async throws -> CaptureResult {
        try await self.captureWindow(
            appIdentifier: appIdentifier,
            windowIndex: windowIndex,
            visualizerMode: .none,
            scale: .logical1x)
    }

    public func captureWindow(
        windowID: CGWindowID,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        throw NSError(
            domain: "Peekaboo",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "captureWindow(windowID:) is not supported by this capture service"])
    }

    public func captureWindow(windowID: CGWindowID) async throws -> CaptureResult {
        try await self.captureWindow(
            windowID: windowID,
            visualizerMode: .none,
            scale: .logical1x)
    }

    public func captureFrontmost() async throws -> CaptureResult {
        try await self.captureFrontmost(visualizerMode: .none, scale: .logical1x)
    }

    public func captureArea(_ rect: CGRect) async throws -> CaptureResult {
        try await self.captureArea(rect, visualizerMode: .none, scale: .logical1x)
    }
}

/// Result of a capture operation
public struct CaptureResult: Sendable, Codable {
    /// The captured image data
    public let imageData: Data

    /// Path where the image was saved (if saved)
    public let savedPath: String?

    /// Metadata about the capture
    public let metadata: CaptureMetadata

    /// Optional error that occurred during capture
    public let warning: String?

    public init(
        imageData: Data,
        savedPath: String? = nil,
        metadata: CaptureMetadata,
        warning: String? = nil)
    {
        self.imageData = imageData
        self.savedPath = savedPath
        self.metadata = metadata
        self.warning = warning
    }
}

/// Metadata about a captured image
public struct CaptureMetadata: Sendable, Codable {
    /// Pixel size of the image delivered to the caller.
    public let size: CGSize

    /// Capture mode used
    public let mode: CaptureMode

    /// Timestamp on the source timeline in milliseconds, when available (e.g. video ingest).
    /// Falls back to wall-clock timing elsewhere.
    public let videoTimestampMs: Int?

    /// Application information (if applicable)
    public let applicationInfo: ServiceApplicationInfo?

    /// Window information (if applicable)
    public let windowInfo: ServiceWindowInfo?

    /// Display information (if applicable)
    public let displayInfo: DisplayInfo?

    /// Timestamp of capture
    public let timestamp: Date

    /// Diagnostic details for scale planning and engine selection.
    public let diagnostics: CaptureDiagnostics?

    /// Optional stateless viewport applied after an exact-window capture.
    public let viewport: CaptureViewport?

    /// Ordered authoritative selector stages (application, then window), when this was a targeted capture.
    public let selectorResolutionProofs: [SelectorResolutionProof]?

    public init(
        size: CGSize,
        mode: CaptureMode,
        videoTimestampMs: Int? = nil,
        applicationInfo: ServiceApplicationInfo? = nil,
        windowInfo: ServiceWindowInfo? = nil,
        displayInfo: DisplayInfo? = nil,
        timestamp: Date = Date(),
        diagnostics: CaptureDiagnostics? = nil,
        viewport: CaptureViewport? = nil,
        selectorResolutionProofs: [SelectorResolutionProof]? = nil)
    {
        self.size = size
        self.mode = mode
        self.videoTimestampMs = videoTimestampMs
        self.applicationInfo = applicationInfo
        self.windowInfo = windowInfo
        self.displayInfo = displayInfo
        self.timestamp = timestamp
        self.diagnostics = diagnostics
        self.viewport = viewport
        self.selectorResolutionProofs = selectorResolutionProofs ?? applicationInfo?.selectorResolutionProofs?.map {
            $0.selecting(windowIdentity: windowInfo?.mutationIdentity)
        }
    }
}

public struct CaptureViewport: Sendable, Codable, Equatable {
    /// Full exact-window bounds in global logical points.
    public let sourceLogicalBounds: CGRect
    /// Requested ROI in window-local logical points.
    public let requestedWindowRelativeBounds: CGRect
    /// Pixel-aligned delivered ROI in window-local logical points.
    public let deliveredWindowRelativeBounds: CGRect
    /// Pixel-aligned delivered ROI in global logical points.
    public let logicalBounds: CGRect
    /// Full source raster size before cropping.
    public let sourceImageSize: CGSize

    public init(
        sourceLogicalBounds: CGRect,
        requestedWindowRelativeBounds: CGRect,
        deliveredWindowRelativeBounds: CGRect,
        logicalBounds: CGRect,
        sourceImageSize: CGSize)
    {
        self.sourceLogicalBounds = sourceLogicalBounds
        self.requestedWindowRelativeBounds = requestedWindowRelativeBounds
        self.deliveredWindowRelativeBounds = deliveredWindowRelativeBounds
        self.logicalBounds = logicalBounds
        self.sourceImageSize = sourceImageSize
    }

    private enum CodingKeys: String, CodingKey {
        case sourceLogicalBounds = "source_logical_bounds"
        case requestedWindowRelativeBounds = "requested_window_relative_bounds"
        case deliveredWindowRelativeBounds = "delivered_window_relative_bounds"
        case logicalBounds = "logical_bounds"
        case sourceImageSize = "source_image_size"
    }
}

public enum CaptureWindowPlanCacheStatus: String, Sendable, Codable, Equatable {
    case hit
    case miss
    case rebuilt
}

public struct CaptureDiagnostics: Sendable, Codable, Equatable {
    public let requestedScale: CaptureScalePreference
    public let nativeScale: CGFloat
    public let outputScale: CGFloat
    public let scaleSource: String
    public let finalPixelSize: CGSize
    public let engine: String?
    public let fallbackReason: String?
    public let windowPlanCacheStatus: CaptureWindowPlanCacheStatus?
    public let windowPlanCacheGeneration: UInt64?

    public init(
        requestedScale: CaptureScalePreference,
        nativeScale: CGFloat,
        outputScale: CGFloat,
        scaleSource: String,
        finalPixelSize: CGSize,
        engine: String? = nil,
        fallbackReason: String? = nil,
        windowPlanCacheStatus: CaptureWindowPlanCacheStatus? = nil,
        windowPlanCacheGeneration: UInt64? = nil)
    {
        self.requestedScale = requestedScale
        self.nativeScale = nativeScale
        self.outputScale = outputScale
        self.scaleSource = scaleSource
        self.finalPixelSize = finalPixelSize
        self.engine = engine
        self.fallbackReason = fallbackReason
        self.windowPlanCacheStatus = windowPlanCacheStatus
        self.windowPlanCacheGeneration = windowPlanCacheGeneration
    }
}

extension CaptureMetadata {
    public func withDiagnostics(_ diagnostics: CaptureDiagnostics?) -> CaptureMetadata {
        CaptureMetadata(
            size: self.size,
            mode: self.mode,
            videoTimestampMs: self.videoTimestampMs,
            applicationInfo: self.applicationInfo,
            windowInfo: self.windowInfo,
            displayInfo: self.displayInfo,
            timestamp: self.timestamp,
            diagnostics: diagnostics,
            viewport: self.viewport)
    }

    /// Return metadata updated for an image resized after capture.
    ///
    /// Capture engines populate `size` and `finalPixelSize` with their raster output. Callers that
    /// subsequently resize that raster must keep both values aligned with the delivered image.
    public func withDeliveredPixelSize(_ deliveredPixelSize: CGSize) -> CaptureMetadata {
        let logicalBounds = self.viewport?.logicalBounds ?? self.windowInfo?.bounds ?? self.displayInfo?.bounds
        let deliveredOutputScale: CGFloat? = if let logicalBounds, logicalBounds.width > 0 {
            deliveredPixelSize.width / logicalBounds.width
        } else if let diagnostics = self.diagnostics, diagnostics.finalPixelSize.width > 0 {
            diagnostics.outputScale * deliveredPixelSize.width / diagnostics.finalPixelSize.width
        } else {
            nil
        }
        let updatedDiagnostics = self.diagnostics.map { diagnostics in
            CaptureDiagnostics(
                requestedScale: diagnostics.requestedScale,
                nativeScale: diagnostics.nativeScale,
                outputScale: deliveredOutputScale ?? diagnostics.outputScale,
                scaleSource: diagnostics.scaleSource,
                finalPixelSize: deliveredPixelSize,
                engine: diagnostics.engine,
                fallbackReason: diagnostics.fallbackReason,
                windowPlanCacheStatus: diagnostics.windowPlanCacheStatus,
                windowPlanCacheGeneration: diagnostics.windowPlanCacheGeneration)
        }

        return CaptureMetadata(
            size: deliveredPixelSize,
            mode: self.mode,
            videoTimestampMs: self.videoTimestampMs,
            applicationInfo: self.applicationInfo,
            windowInfo: self.windowInfo,
            displayInfo: self.displayInfo,
            timestamp: self.timestamp,
            diagnostics: updatedDiagnostics,
            viewport: self.viewport)
    }

    public func withViewport(_ viewport: CaptureViewport, deliveredPixelSize: CGSize) -> CaptureMetadata {
        let updatedDiagnostics = self.diagnostics.map { diagnostics in
            CaptureDiagnostics(
                requestedScale: diagnostics.requestedScale,
                nativeScale: diagnostics.nativeScale,
                outputScale: diagnostics.outputScale,
                scaleSource: diagnostics.scaleSource,
                finalPixelSize: deliveredPixelSize,
                engine: diagnostics.engine,
                fallbackReason: diagnostics.fallbackReason,
                windowPlanCacheStatus: diagnostics.windowPlanCacheStatus,
                windowPlanCacheGeneration: diagnostics.windowPlanCacheGeneration)
        }
        return CaptureMetadata(
            size: deliveredPixelSize,
            mode: self.mode,
            videoTimestampMs: self.videoTimestampMs,
            applicationInfo: self.applicationInfo,
            windowInfo: self.windowInfo,
            displayInfo: self.displayInfo,
            timestamp: self.timestamp,
            diagnostics: updatedDiagnostics,
            viewport: viewport)
    }
}

/// Coordinate metadata that binds an image raster to Peekaboo's canonical automation space.
///
/// The context is descriptive only: it does not perform coordinate conversion. Consumers can use
/// the logical bounds and delivered image size to map image-local pixels without assuming a Retina
/// scale factor.
public struct CaptureCoordinateContext: Sendable, Codable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let referenceID: String?
    public let logicalSpace: LogicalSpace
    public let origin: Origin
    public let logicalBounds: CGRect?
    public let deliveredImageSize: CGSize
    public let requestedScale: CaptureScalePreference?
    public let nativeScale: CGFloat?
    public let outputScale: CGFloat?
    public let display: DisplayIdentity?
    public let window: WindowIdentity?
    public let viewport: CaptureViewport?

    public enum LogicalSpace: String, Sendable, Codable, Equatable {
        case globalDisplayPoints = "global_display_points"
    }

    public enum Origin: String, Sendable, Codable, Equatable {
        case topLeft = "top_left"
    }

    public struct DisplayIdentity: Sendable, Codable, Equatable {
        public let index: Int
        public let name: String?

        public init(index: Int, name: String?) {
            self.index = index
            self.name = name
        }
    }

    public struct WindowIdentity: Sendable, Codable, Equatable {
        public let windowID: Int
        public let title: String
        public let index: Int
        public let screenIndex: Int?
        public let screenName: String?

        public init(
            windowID: Int,
            title: String,
            index: Int,
            screenIndex: Int?,
            screenName: String?)
        {
            self.windowID = windowID
            self.title = title
            self.index = index
            self.screenIndex = screenIndex
            self.screenName = screenName
        }

        private enum CodingKeys: String, CodingKey {
            case windowID = "window_id"
            case title
            case index
            case screenIndex = "screen_index"
            case screenName = "screen_name"
        }
    }

    public init(metadata: CaptureMetadata, referenceID: String? = nil) {
        let logicalBounds = metadata.viewport?.logicalBounds ?? metadata.windowInfo?.bounds ?? metadata.displayInfo?
            .bounds
        self.version = Self.currentVersion
        self.referenceID = referenceID
        self.logicalSpace = .globalDisplayPoints
        self.origin = .topLeft
        self.logicalBounds = logicalBounds
        self.deliveredImageSize = metadata.size
        self.requestedScale = metadata.diagnostics?.requestedScale
        self.nativeScale = metadata.diagnostics?.nativeScale ?? metadata.displayInfo?.scaleFactor
        self.outputScale = Self.inferredOutputScale(
            deliveredImageSize: metadata.size,
            logicalBounds: logicalBounds) ?? metadata.diagnostics?.outputScale
        self.display = metadata.displayInfo.map { DisplayIdentity(index: $0.index, name: $0.name) }
        self.window = metadata.windowInfo.map {
            WindowIdentity(
                windowID: $0.windowID,
                title: $0.title,
                index: $0.index,
                screenIndex: $0.screenIndex,
                screenName: $0.screenName)
        }
        self.viewport = metadata.viewport
    }

    private static func inferredOutputScale(deliveredImageSize: CGSize, logicalBounds: CGRect?) -> CGFloat? {
        guard let logicalBounds, logicalBounds.width > 0 else { return nil }
        return deliveredImageSize.width / logicalBounds.width
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case referenceID = "reference_id"
        case logicalSpace = "logical_space"
        case origin
        case logicalBounds = "logical_bounds"
        case deliveredImageSize = "delivered_image_size"
        case requestedScale = "requested_scale"
        case nativeScale = "native_scale"
        case outputScale = "output_scale"
        case display
        case window
        case viewport
    }
}

extension CaptureResult {
    public func withCaptureDiagnostics(engine: String?, fallbackReason: String?) -> CaptureResult {
        guard let diagnostics = self.metadata.diagnostics else {
            return self
        }

        return CaptureResult(
            imageData: self.imageData,
            savedPath: self.savedPath,
            metadata: self.metadata.withDiagnostics(CaptureDiagnostics(
                requestedScale: diagnostics.requestedScale,
                nativeScale: diagnostics.nativeScale,
                outputScale: diagnostics.outputScale,
                scaleSource: diagnostics.scaleSource,
                finalPixelSize: diagnostics.finalPixelSize,
                engine: engine ?? diagnostics.engine,
                fallbackReason: fallbackReason ?? diagnostics.fallbackReason,
                windowPlanCacheStatus: diagnostics.windowPlanCacheStatus,
                windowPlanCacheGeneration: diagnostics.windowPlanCacheGeneration)),
            warning: self.warning)
    }
}

/// Information about a display
public struct DisplayInfo: Sendable, Codable {
    public let index: Int
    public let name: String?
    public let bounds: CGRect
    public let scaleFactor: CGFloat

    public init(index: Int, name: String?, bounds: CGRect, scaleFactor: CGFloat) {
        self.index = index
        self.name = name
        self.bounds = bounds
        self.scaleFactor = scaleFactor
    }
}
