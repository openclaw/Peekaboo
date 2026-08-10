import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import PeekabooFoundation

/// Simple MP4 writer that appends CGImages as video frames.
final class VideoWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frameDuration: CMTime
    private var frameIndex: Int64 = 0
    private let outputExistedBeforeInitialization: Bool
    private let fileManager: FileManager

    var finalURL: URL {
        self.writer.outputURL
    }

    init(
        outputPath: String,
        width: Int,
        height: Int,
        fps: Double,
        fileManager: FileManager = .default) throws
    {
        self.fileManager = fileManager
        let url = URL(fileURLWithPath: outputPath)
        self.outputExistedBeforeInitialization = fileManager.fileExists(atPath: url.path)
        guard !self.outputExistedBeforeInitialization else {
            throw PeekabooError.fileIOError("Video output already exists: \(url.path)")
        }
        self.writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        self.input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        self.input.expectsMediaDataInRealTime = false

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: self.input,
            sourcePixelBufferAttributes: attrs)

        guard self.writer.canAdd(self.input) else {
            throw PeekabooError.captureFailed(reason: "Cannot add video input")
        }
        self.writer.add(self.input)
        self.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(fps))))
    }

    func startIfNeeded() throws {
        guard self.writer.status == .unknown else { return }
        guard self.writer.startWriting() else {
            throw self.writer.error ?? PeekabooError.captureFailed(reason: "Failed to start video writer")
        }
        self.writer.startSession(atSourceTime: .zero)
    }

    func append(image: CGImage) async throws {
        try self.startIfNeeded()
        let readinessDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !self.input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if self.writer.status == .failed || self.writer.status == .cancelled {
                throw self.writer.error ?? PeekabooError.captureFailed("Video writer stopped accepting frames")
            }
            guard ContinuousClock.now < readinessDeadline else {
                throw PeekabooError.captureTimeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        var pixelBuffer: CVPixelBuffer?
        let width = image.width
        let height = image.height
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer)
        guard let buffer = pixelBuffer else {
            throw PeekabooError.captureFailed("Failed to allocate a video pixel buffer")
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            throw PeekabooError.captureFailed("Failed to create the video frame drawing context")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let pts = CMTimeMultiply(self.frameDuration, multiplier: Int32(self.frameIndex))
        guard self.adaptor.append(buffer, withPresentationTime: pts) else {
            throw self.writer.error ?? PeekabooError.captureFailed("Failed to append a video frame")
        }
        self.frameIndex += 1
    }

    func finish() async throws {
        try Task.checkCancellation()
        guard self.writer.status != .completed else { return }
        self.input.markAsFinished()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.writer.finishWriting {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.writer.cancelWriting()
        }
        try Task.checkCancellation()
        if self.writer.status != .completed {
            throw self.writer.error ?? PeekabooError.captureFailed(reason: "Failed to finalize video")
        }
    }

    func abortAndRemovePartialOutput() throws {
        if self.writer.status == .writing || self.writer.status == .unknown {
            self.writer.cancelWriting()
        }
        guard !self.outputExistedBeforeInitialization else { return }
        do {
            try self.fileManager.removeItem(at: self.writer.outputURL)
        } catch {
            if Self.isMissingOutputError(error) {
                return
            }
            let detail = CaptureDiagnosticSanitizer.sanitize(error.localizedDescription) ?? "unknown error"
            throw PeekabooError.fileIOError(
                "Failed to remove incomplete video output at \(self.writer.outputURL.path): \(detail)")
        }
    }

    private static func isMissingOutputError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == ENOENT {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error,
           underlying as NSError !== nsError
        {
            return self.isMissingOutputError(underlying)
        }
        return false
    }
}
