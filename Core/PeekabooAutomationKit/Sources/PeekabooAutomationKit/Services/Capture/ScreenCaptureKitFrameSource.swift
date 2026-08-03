import CoreGraphics
import CoreImage
import CoreMedia
import Dispatch
import Foundation
import PeekabooFoundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class ScreenCaptureKitFrameSource: CaptureFrameSource {
    private let logger: CategoryLogger
    private let maxFrameAge: TimeInterval
    private let frameWaitTimeout: TimeInterval
    private let framePollInterval: TimeInterval
    private var sessions: [SCKFrameStreamKey: SCKStreamSession] = [:]
    private var latestFrames: [SCKFrameStreamKey: SCKFrame] = [:]
    private var currentRequest: CaptureFrameRequest?

    init(logger: CategoryLogger) {
        self.logger = logger
        self.maxFrameAge = ScreenCaptureKitFrameSource.defaultMaxFrameAge
        self.frameWaitTimeout = ScreenCaptureKitFrameSource.defaultFrameWaitTimeout
        self.framePollInterval = ScreenCaptureKitFrameSource.defaultFramePollInterval
    }

    func start(request: CaptureFrameRequest) async throws {
        self.currentRequest = request
    }

    func stop() async {
        for session in self.sessions.values {
            do {
                let stream = session.stream
                try await withTimeout(seconds: 2.0) {
                    try await stream.stopCapture()
                }
            } catch {
                self.logger.debug(
                    "Fast stream stop failed",
                    metadata: [
                        "displayID": session.display.displayID,
                        "error": String(describing: error),
                    ])
            }
        }

        self.sessions.removeAll()
        self.latestFrames.removeAll()
        self.currentRequest = nil
    }

    func nextFrame() async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        try await self.nextFrame(maxAge: nil)
    }

    func nextFrame(maxAge: TimeInterval?) async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        guard let request = self.currentRequest else {
            throw OperationError.captureFailed(reason: "Fast stream capture request missing")
        }

        let display = request.display
        let sourceRect = request.sourceRect
        let scale = request.scale
        let correlationId = request.correlationId

        let key = SCKFrameStreamKey(displayID: display.displayID, scale: scale)
        let session = try self.session(for: display, scale: scale, key: key, correlationId: correlationId)
        try await session.start(correlationId: correlationId)
        let scalePlan = Self.scalePlan(for: display, preference: scale)

        let context = SCKFrameContext(
            displayFrame: display.frame,
            scaleFactor: session.scaleFactor,
            sourceRect: sourceRect)
        let configSize = CGSize(
            width: sourceRect.width * session.scaleFactor,
            height: sourceRect.height * session.scaleFactor)
        let requestTime = Date()
        try await session.ensureConfiguration(
            sourceRect: sourceRect,
            size: configSize,
            correlationId: correlationId)

        let frame = try await self.waitForFrame(
            key: key,
            context: context,
            after: requestTime,
            maxAge: maxAge,
            correlationId: correlationId)

        let waitDuration = Date().timeIntervalSince(requestTime)
        let frameAge = Date().timeIntervalSince(frame.timestamp)
        self.logger.debug(
            "Fast stream capture complete",
            metadata: [
                "waitMs": Int(waitDuration * 1000),
                "frameAgeMs": Int(frameAge * 1000),
                "displayID": display.displayID,
            ],
            correlationId: correlationId)

        let metadata = CaptureMetadata(
            size: CGSize(width: frame.image.width, height: frame.image.height),
            mode: request.mode,
            displayInfo: DisplayInfo(
                index: request.displayIndex,
                name: request.displayName ?? display.displayID.description,
                bounds: request.displayBounds,
                scaleFactor: frame.scaleFactor),
            timestamp: frame.timestamp,
            diagnostics: ScreenCaptureScaleResolver.diagnostics(
                plan: scalePlan,
                finalPixelSize: CGSize(width: frame.image.width, height: frame.image.height)))

        return (cgImage: frame.image, metadata: metadata)
    }

    private func session(
        for display: SCDisplay,
        scale: CaptureScalePreference,
        key: SCKFrameStreamKey,
        correlationId: String) throws -> SCKStreamSession
    {
        if let existing = self.sessions[key] {
            if let error = existing.pendingError {
                throw error
            }
            return existing
        }

        let scalePlan = ScreenCaptureKitFrameSource.scalePlan(for: display, preference: scale)
        let scaleFactor = scalePlan.outputScale
        let queue = DispatchQueue(label: "boo.peekaboo.capture.stream.\(display.displayID)")
        let handler = SCKStreamFrameHandler(
            onFrame: { [weak self] image, timestamp, _ in
                let context = SCKFrameContext(
                    displayFrame: display.frame,
                    scaleFactor: scaleFactor,
                    sourceRect: CGRect(origin: .zero, size: display.frame.size))
                self?.update(
                    image: image,
                    timestamp: timestamp,
                    context: context,
                    key: key)
            },
            onError: { [weak self] error in
                self?.handleStreamError(error, key: key)
            })

        let session = try SCKStreamSession(
            key: key,
            display: display,
            scaleFactor: scaleFactor,
            logger: self.logger,
            handler: handler,
            queue: queue)
        self.sessions[key] = session

        self.logger.debug(
            "Fast stream session created",
            metadata: [
                "displayID": display.displayID,
                "scaleFactor": scaleFactor,
                "scaleSource": scalePlan.source.rawValue,
            ],
            correlationId: correlationId)

        return session
    }

    private func update(
        image: CGImage,
        timestamp: Date,
        context: SCKFrameContext,
        key: SCKFrameStreamKey)
    {
        self.latestFrames[key] = SCKFrame(
            image: image,
            timestamp: timestamp,
            displayFrame: context.displayFrame,
            scaleFactor: context.scaleFactor,
            sourceRect: context.sourceRect)
    }

    private func handleStreamError(_ error: any Error, key: SCKFrameStreamKey) {
        if let session = self.sessions[key] {
            session.pendingError = error
        }
        self.logger.error(
            "Fast stream error",
            metadata: ["error": String(describing: error)])
    }

    private func waitForFrame(
        key: SCKFrameStreamKey,
        context: SCKFrameContext,
        after requestTime: Date,
        maxAge: TimeInterval?,
        correlationId: String) async throws -> SCKFrame
    {
        let ageLimit = maxAge ?? self.maxFrameAge
        let deadline = Date().addingTimeInterval(self.frameWaitTimeout)
        while Date() < deadline {
            if let frame = self.latestFrames[key] {
                let age = Date().timeIntervalSince(frame.timestamp)
                if frame.timestamp >= requestTime || age <= ageLimit {
                    return SCKFrame(
                        image: frame.image,
                        timestamp: frame.timestamp,
                        displayFrame: context.displayFrame,
                        scaleFactor: context.scaleFactor,
                        sourceRect: context.sourceRect)
                }
            }
            try await Task.sleep(nanoseconds: UInt64(self.framePollInterval * 1_000_000_000))
        }

        self.logger.warning(
            "Fast stream wait timed out",
            correlationId: correlationId)
        throw OperationError.timeout(
            operation: "FastStream.waitForFrame",
            duration: self.frameWaitTimeout)
    }

    private nonisolated static func scalePlan(
        for display: SCDisplay,
        preference: CaptureScalePreference) -> ScreenCaptureScaleResolver.Plan
    {
        ScreenCaptureScaleResolver.plan(
            preference: preference,
            displayID: display.displayID,
            fallbackPixelWidth: display.width,
            frameWidth: display.frame.width)
    }

    nonisolated static let defaultMaxFrameAge: TimeInterval = 0.25
    nonisolated static let defaultFrameWaitTimeout: TimeInterval = 0.6
    nonisolated static let defaultFramePollInterval: TimeInterval = 0.02
    nonisolated static let defaultFPS: CMTimeScale? = nil
}
