import CoreGraphics
import Foundation
import PeekabooFoundation
@preconcurrency import ScreenCaptureKit

public struct CaptureFrameRequest: Sendable {
    public let mode: CaptureMode
    public let display: SCDisplay
    public let displayIndex: Int
    public let displayName: String?
    public let displayBounds: CGRect
    public let sourceRect: CGRect
    public let scale: CaptureScalePreference
    public let correlationId: String

    public init(
        mode: CaptureMode,
        display: SCDisplay,
        displayIndex: Int,
        displayName: String?,
        displayBounds: CGRect,
        sourceRect: CGRect,
        scale: CaptureScalePreference,
        correlationId: String)
    {
        self.mode = mode
        self.display = display
        self.displayIndex = displayIndex
        self.displayName = displayName
        self.displayBounds = displayBounds
        self.sourceRect = sourceRect
        self.scale = scale
        self.correlationId = correlationId
    }
}

/// Abstract source of frames for capture sessions (live or video).
public protocol CaptureFrameSource {
    /// Returns next frame; nil when the source is exhausted.
    @MainActor
    func nextFrame() async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)?

    /// Begin a capture request (no-op for one-shot/video sources).
    @MainActor
    func start(request: CaptureFrameRequest) async throws

    /// Stop the capture source (no-op for one-shot/video sources).
    @MainActor
    func stop() async

    /// Returns the next frame for the current request.
    @MainActor
    func nextFrame(maxAge: TimeInterval?) async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)?
}

public struct CaptureFrameSourceDiagnostics: Sendable, Equatable {
    public let decodeFailures: Int
    public let firstDecodeError: String?
    public let lastDecodeError: String?

    public init(
        decodeFailures: Int = 0,
        firstDecodeError: String? = nil,
        lastDecodeError: String? = nil)
    {
        self.decodeFailures = max(0, decodeFailures)
        self.firstDecodeError = CaptureDiagnosticSanitizer.sanitize(firstDecodeError)
        self.lastDecodeError = CaptureDiagnosticSanitizer.sanitize(lastDecodeError)
    }
}

public protocol CaptureFrameSourceDiagnosticsProviding: CaptureFrameSource {
    @MainActor var captureDiagnostics: CaptureFrameSourceDiagnostics { get }
}

extension CaptureFrameSource {
    @MainActor
    public func start(request _: CaptureFrameRequest) async throws {}
    @MainActor
    public func stop() async {}
    @MainActor
    public func nextFrame(maxAge _: TimeInterval?) async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        try await self.nextFrame()
    }
}
