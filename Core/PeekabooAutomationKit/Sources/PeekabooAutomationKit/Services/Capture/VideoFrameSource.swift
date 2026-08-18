import AVFoundation
import CoreGraphics
import Foundation
import PeekabooFoundation

/// Frame source that samples frames from a video asset.
public final class VideoFrameSource: CaptureFrameSource {
    private let decoder: any VideoFrameDecoding
    private let sourceURL: URL?
    private var timeline: VideoFrameTimeline
    private let mode: CaptureMode = .screen
    private var decodeFailures = 0
    private var firstDecodeError: String?
    private var lastDecodeError: String?
    private let decodeTimeout: Duration
    public let effectiveFPS: Double

    init(
        timeline: VideoFrameTimeline,
        effectiveFPS: Double,
        decoder: any VideoFrameDecoding,
        decodeTimeout: Duration = .seconds(5))
    {
        self.timeline = timeline
        self.effectiveFPS = effectiveFPS
        self.decoder = decoder
        self.decodeTimeout = decodeTimeout
        self.sourceURL = nil
    }

    public init(
        url: URL,
        sampleFps: Double?,
        everyMs: Int?,
        startMs: Int?,
        endMs: Int?,
        resolutionCap: CGFloat?) async throws
    {
        self.sourceURL = url
        self.decodeTimeout = .seconds(5)
        try VideoFrameRequestValidator.validate(
            sampleFps: sampleFps,
            everyMs: everyMs,
            startMs: startMs,
            endMs: endMs,
            resolutionCap: resolutionCap.map(Double.init))

        let asset = AVAsset(url: url)
        let duration: CMTime = if #available(macOS 13.0, *) {
            try await asset.load(.duration)
        } else {
            asset.duration
        }
        guard duration.isNumeric, duration.seconds > 0 else {
            throw PeekabooError.captureFailed(reason: "Video has no duration")
        }

        let start = CMTime(milliseconds: startMs ?? 0)
        guard start < duration else {
            throw PeekabooError.invalidInput("start-ms must be before the end of the video")
        }
        let requestedEnd = endMs.map { CMTime(milliseconds: $0) } ?? duration
        let end = min(requestedEnd, duration)
        guard end > start else { throw PeekabooError.captureFailed(reason: "end-ms must exceed start-ms") }

        // Derive sampling cadence from either fps or fixed millisecond interval,
        // and expose effectiveFPS so the video writer can match it later.
        let interval: CMTime
        if let everyMs, everyMs > 0 {
            interval = CMTime(milliseconds: everyMs)
            self.effectiveFPS = everyMs > 0 ? min(240, max(0.1, 1000.0 / Double(everyMs))) : 2.0
        } else {
            let fps = min(240, max(sampleFps ?? 2.0, 0.1))
            interval = CMTime(seconds: 1.0 / max(fps, 0.1), preferredTimescale: 1_000_000)
            self.effectiveFPS = fps
        }

        self.timeline = VideoFrameTimeline(
            start: start,
            end: end,
            interval: interval)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let cap = resolutionCap {
            generator.maximumSize = CGSize(width: cap, height: cap)
        }
        self.decoder = VideoFrameDecoder(generator: generator)
    }

    @MainActor
    public func nextFrame() async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        guard let time = self.timeline.next() else { return nil }

        do {
            try Task.checkCancellation()
            let generated = try await self.decodeFrame(at: time)
            try Task.checkCancellation()
            let image = generated.image
            let actual = generated.actualTime
            let size = CGSize(width: image.width, height: image.height)
            let millis = Self.milliseconds(from: actual, fallback: time)
            let meta = CaptureMetadata(
                size: size,
                mode: self.mode,
                videoTimestampMs: millis,
                applicationInfo: nil,
                windowInfo: nil,
                displayInfo: nil,
                timestamp: Date())
            return (image, meta)
        } catch {
            if error is CancellationError {
                throw error
            }
            try Task.checkCancellation()
            if let sourceURL = self.sourceURL,
               !FileManager.default.isReadableFile(atPath: sourceURL.path)
            {
                throw PeekabooError.fileIOError("Video input became unreadable: \(sourceURL.path)")
            }
            if Self.isFileIOError(error) {
                throw error
            }
            let description = CaptureDiagnosticSanitizer.sanitize(error.localizedDescription) ??
                "Video frame decode failed"
            self.decodeFailures += 1
            self.firstDecodeError = self.firstDecodeError ?? description
            self.lastDecodeError = description
            // Skip unreadable frames but keep advancing
            let meta = CaptureMetadata(
                size: .zero,
                mode: self.mode,
                videoTimestampMs: Self.milliseconds(from: .zero, fallback: time),
                applicationInfo: nil,
                windowInfo: nil,
                displayInfo: nil,
                timestamp: Date())
            return (nil, meta)
        }
    }

    private func decodeFrame(at time: CMTime) async throws -> (image: CGImage, actualTime: CMTime) {
        let decoder = self.decoder
        let decodeTask = Task<DecodedVideoFrame, any Error> {
            let result = try await decoder.image(at: time)
            return DecodedVideoFrame(image: result.image, actualTime: result.actualTime)
        }
        let timeout = self.decodeTimeout
        let timeoutTask = Task<DecodedVideoFrame, any Error> {
            try await Task.sleep(for: timeout)
            throw PeekabooError.captureTimeout
        }
        defer {
            decodeTask.cancel()
            timeoutTask.cancel()
        }

        do {
            let decoded = try await withTaskCancellationHandler {
                let result: DecodedVideoFrame = try await withCheckedThrowingContinuation { continuation in
                    let gate = VideoDecodeContinuation(continuation: continuation)
                    Task {
                        await gate.resume(with: decodeTask.result)
                    }
                    Task {
                        await gate.resume(with: timeoutTask.result)
                    }
                }
                try Task.checkCancellation()
                return result
            } onCancel: {
                decoder.cancelPendingDecodes()
                decodeTask.cancel()
                timeoutTask.cancel()
            }
            return (decoded.image, decoded.actualTime)
        } catch {
            if error is CancellationError {
                decoder.cancelPendingDecodes()
            } else if let peekabooError = error as? PeekabooError,
                      case .captureTimeout = peekabooError
            {
                decoder.cancelPendingDecodes()
            }
            throw error
        }
    }

    private static func milliseconds(from time: CMTime, fallback: CMTime) -> Int? {
        // Prefer the actual timestamp when present and non-zero; otherwise use the requested fallback.
        let hasActual = time.isNumeric && time.seconds.isFinite && time != .zero
        let resolved = hasActual ? time : fallback
        guard resolved.isNumeric else { return nil }
        return Int((resolved.seconds * 1000).rounded())
    }

    private static func isFileIOError(_ error: any Error) -> Bool {
        if let peekabooError = error as? PeekabooError {
            if case .fileIOError = peekabooError {
                return true
            }
            return false
        }
        if let captureError = error as? CaptureError {
            switch captureError {
            case .fileIOError, .fileWriteError:
                return true
            default:
                return false
            }
        }
        if error is POSIXError {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain, (256...263).contains(nsError.code) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error,
           underlying as NSError !== nsError
        {
            return self.isFileIOError(underlying)
        }
        return false
    }
}

protocol VideoFrameDecoding: Sendable {
    func image(at time: CMTime) async throws -> (image: CGImage, actualTime: CMTime)
    func cancelPendingDecodes()
}

extension VideoFrameDecoding {
    func cancelPendingDecodes() {}
}

private struct DecodedVideoFrame: @unchecked Sendable {
    let image: CGImage
    let actualTime: CMTime
}

private final class VideoDecodeContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DecodedVideoFrame, any Error>?

    init(continuation: CheckedContinuation<DecodedVideoFrame, any Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<DecodedVideoFrame, any Error>) {
        self.lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class VideoFrameDecoder: @unchecked Sendable, VideoFrameDecoding {
    private let generator: AVAssetImageGenerator

    init(generator: AVAssetImageGenerator) {
        self.generator = generator
    }

    func image(at time: CMTime) async throws -> (image: CGImage, actualTime: CMTime) {
        try Task.checkCancellation()
        let generated = try await self.generator.image(at: time)
        try Task.checkCancellation()
        return generated
    }

    func cancelPendingDecodes() {
        self.generator.cancelAllCGImageGeneration()
    }
}

extension VideoFrameSource: CaptureFrameSourceDiagnosticsProviding {
    @MainActor public var captureDiagnostics: CaptureFrameSourceDiagnostics {
        CaptureFrameSourceDiagnostics(
            decodeFailures: self.decodeFailures,
            firstDecodeError: self.firstDecodeError,
            lastDecodeError: self.lastDecodeError)
    }
}

struct VideoFrameTimeline {
    private var nextTime: CMTime
    private let end: CMTime
    private let interval: CMTime
    private var exhausted = false

    init(start: CMTime, end: CMTime, interval: CMTime) {
        self.nextTime = start
        self.end = end
        self.interval = interval
    }

    mutating func next() -> CMTime? {
        guard !self.exhausted else { return nil }
        guard self.nextTime < self.end else {
            self.exhausted = true
            return nil
        }
        let current = self.nextTime

        let next = CMTimeAdd(current, self.interval)
        guard next.isNumeric, next > current else {
            self.exhausted = true
            return nil
        }

        self.nextTime = min(next, self.end)
        return current
    }
}

extension CMTime {
    fileprivate init(milliseconds: Int) {
        self.init(value: CMTimeValue(milliseconds), timescale: 1000)
    }
}
