import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import PeekabooFoundation

/// Simple MP4 writer that appends CGImages as video frames.
final class VideoWriter: @unchecked Sendable {
    private struct OutputIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct StagingDirectory {
        let url: URL
        let identity: OutputIdentity
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frameDuration: CMTime
    private var frameIndex: Int64 = 0
    private let publishedURL: URL
    private let stagingDirectory: StagingDirectory
    private let fileManager: FileManager
    private let custodyDescriptorOpener: (URL) -> Int32
    private var custodyDescriptor: Int32 = -1
    private var admittedIdentity: OutputIdentity?
    private var outputWasPublished = false
    private var finalCustody: CaptureVideoArtifactCustody?

    var finalURL: URL {
        self.publishedURL
    }

    var stagingURL: URL {
        self.writer.outputURL
    }

    deinit {
        self.closeCustodyDescriptor()
        _ = Self.removeStagingDirectoryIfEmpty(self.stagingDirectory)
    }

    init(
        outputPath: String,
        width: Int,
        height: Int,
        fps: Double,
        fileManager: FileManager = .default,
        custodyDescriptorOpener: @escaping (URL) -> Int32 = { url in
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
        }) throws
    {
        self.fileManager = fileManager
        self.custodyDescriptorOpener = custodyDescriptorOpener
        let publishedURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        try Self.requireAbsent(publishedURL)
        self.publishedURL = publishedURL
        let stagingDirectory = try Self.createStagingDirectory(beside: publishedURL)
        self.stagingDirectory = stagingDirectory
        var initialized = false
        defer {
            if !initialized {
                _ = Self.removeStagingDirectoryIfEmpty(stagingDirectory)
            }
        }
        let stagingURL = stagingDirectory.url.appendingPathComponent("video.mp4", isDirectory: false)
        self.writer = try AVAssetWriter(outputURL: stagingURL, fileType: .mp4)

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
        initialized = true
    }

    func startIfNeeded() throws {
        guard self.writer.status == .unknown else { return }
        guard self.writer.startWriting() else {
            throw self.writer.error ?? PeekabooError.captureFailed(reason: "Failed to start video writer")
        }
        self.writer.startSession(atSourceTime: .zero)
        let admittedIdentity = try Self.identity(at: self.writer.outputURL)
        self.admittedIdentity = admittedIdentity
        let descriptor = self.custodyDescriptorOpener(self.writer.outputURL)
        var information = stat()
        guard descriptor >= 0,
              fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              OutputIdentity(device: information.st_dev, inode: information.st_ino) == admittedIdentity,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
        else {
            if descriptor >= 0 {
                close(descriptor)
            }
            self.writer.cancelWriting()
            let primaryError = PeekabooError.fileIOError(
                "Video writer output could not be bound to a regular file")
            do {
                try self.abortAndRemovePartialOutput()
            } catch {
                throw CaptureArtifactCleanupError(
                    primaryError: primaryError,
                    cleanupError: error,
                    artifactPath: self.writer.outputURL.path)
            }
            throw primaryError
        }
        self.custodyDescriptor = descriptor
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

    func finish(
        beforeCustodyValidation: () throws -> Void = {},
        afterPublication: () throws -> Void = {}) async throws -> CaptureVideoArtifactCustody
    {
        try Task.checkCancellation()
        if self.writer.status != .completed {
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
        }
        try Task.checkCancellation()
        if self.writer.status != .completed {
            throw self.writer.error ?? PeekabooError.captureFailed(reason: "Failed to finalize video")
        }
        if let finalCustody = self.finalCustody {
            return finalCustody
        }
        guard self.custodyDescriptor >= 0, let admittedIdentity else {
            throw PeekabooError.fileIOError("Video writer output custody is unavailable")
        }
        defer { self.closeCustodyDescriptor() }
        try beforeCustodyValidation()
        try Task.checkCancellation()
        _ = try CaptureArtifactIntegrityValidator.videoCustody(
            descriptor: self.custodyDescriptor,
            path: self.writer.outputURL.path,
            expectedDevice: UInt64(admittedIdentity.device),
            expectedInode: UInt64(admittedIdentity.inode))
        do {
            try self.publishStagedOutput()
        } catch {
            let primaryError = error
            do {
                try self.abortAndRemovePartialOutput()
            } catch {
                throw CaptureArtifactCleanupError(
                    primaryError: primaryError,
                    cleanupError: error,
                    artifactPath: self.writer.outputURL.path)
            }
            throw primaryError
        }
        try afterPublication()
        try Task.checkCancellation()
        let custody = try CaptureArtifactIntegrityValidator.videoCustody(
            descriptor: self.custodyDescriptor,
            path: self.publishedURL.path,
            expectedDevice: UInt64(admittedIdentity.device),
            expectedInode: UInt64(admittedIdentity.inode))
        self.finalCustody = custody
        return custody
    }

    func abortAndRemovePartialOutput() throws {
        if self.writer.status == .writing || self.writer.status == .unknown {
            self.writer.cancelWriting()
        }
        self.closeCustodyDescriptor()
        defer { _ = Self.removeStagingDirectoryIfEmpty(self.stagingDirectory) }
        guard let admittedIdentity else { return }
        let artifactURL = self.outputWasPublished ? self.publishedURL : self.writer.outputURL
        let quarantineURL = artifactURL.deletingLastPathComponent().appendingPathComponent(
            ".\(artifactURL.lastPathComponent).\(UUID().uuidString).failed",
            isDirectory: false)
        let quarantineResult = artifactURL.withUnsafeFileSystemRepresentation { sourcePath in
            quarantineURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL))
            }
        }
        if quarantineResult != 0 {
            if errno == ENOENT {
                return
            }
            throw PeekabooError.fileIOError(
                "Failed to quarantine incomplete video output at \(artifactURL.path)")
        }
        let quarantineIdentity = try? Self.identity(at: quarantineURL)
        guard quarantineIdentity == admittedIdentity else {
            _ = quarantineURL.withUnsafeFileSystemRepresentation { sourcePath in
                artifactURL.withUnsafeFileSystemRepresentation { destinationPath in
                    guard let sourcePath, let destinationPath else { return Int32(-1) }
                    return renameatx_np(
                        AT_FDCWD,
                        sourcePath,
                        AT_FDCWD,
                        destinationPath,
                        UInt32(RENAME_EXCL))
                }
            }
            throw PeekabooError.fileIOError(
                "Incomplete video output identity changed before cleanup at \(artifactURL.path)")
        }
        do {
            try self.fileManager.removeItem(at: quarantineURL)
        } catch {
            if Self.isMissingOutputError(error) {
                return
            }
            _ = quarantineURL.withUnsafeFileSystemRepresentation { sourcePath in
                artifactURL.withUnsafeFileSystemRepresentation { destinationPath in
                    guard let sourcePath, let destinationPath else { return Int32(-1) }
                    return renameatx_np(
                        AT_FDCWD,
                        sourcePath,
                        AT_FDCWD,
                        destinationPath,
                        UInt32(RENAME_EXCL))
                }
            }
            let detail = CaptureDiagnosticSanitizer.sanitize(error.localizedDescription) ?? "unknown error"
            throw PeekabooError.fileIOError(
                "Failed to remove incomplete video output at \(artifactURL.path): \(detail)")
        }
    }

    private func publishStagedOutput() throws {
        let result = self.writer.outputURL.withUnsafeFileSystemRepresentation { sourcePath in
            self.publishedURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            throw PeekabooError.fileIOError(
                "Video output could not be published without replacing an existing file: \(self.publishedURL.path)")
        }
        self.outputWasPublished = true
        guard Self.removeStagingDirectoryIfEmpty(self.stagingDirectory) else {
            throw PeekabooError.fileIOError(
                "Video staging directory could not be removed safely: \(self.stagingDirectory.url.path)")
        }
    }

    private func closeCustodyDescriptor() {
        guard self.custodyDescriptor >= 0 else { return }
        close(self.custodyDescriptor)
        self.custodyDescriptor = -1
    }

    private static func identity(at url: URL) throws -> OutputIdentity {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &information)
        }
        guard result == 0, information.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return OutputIdentity(device: information.st_dev, inode: information.st_ino)
    }

    private static func createStagingDirectory(beside publishedURL: URL) throws -> StagingDirectory {
        let parent = publishedURL.deletingLastPathComponent()
        for _ in 0..<4 {
            let url = parent.appendingPathComponent(
                ".peekaboo-video-stage-\(UUID().uuidString.lowercased())",
                isDirectory: true)
            let result = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return mkdir(path, S_IRWXU)
            }
            if result == 0 {
                var information = stat()
                let inspected = url.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return Int32(-1) }
                    return lstat(path, &information)
                }
                guard inspected == 0,
                      information.st_mode & S_IFMT == S_IFDIR,
                      information.st_uid == geteuid(),
                      information.st_mode & (S_IRWXG | S_IRWXO) == 0
                else {
                    _ = url.withUnsafeFileSystemRepresentation { path in
                        guard let path else { return Int32(-1) }
                        return rmdir(path)
                    }
                    throw PeekabooError.fileIOError(
                        "Video staging directory is not owner-private: \(url.path)")
                }
                return StagingDirectory(
                    url: url,
                    identity: OutputIdentity(device: information.st_dev, inode: information.st_ino))
            }
            guard errno == EEXIST else {
                throw PeekabooError.fileIOError(
                    "Video staging directory could not be created: \(parent.path)")
            }
        }
        throw PeekabooError.fileIOError("Video staging directory name could not be reserved: \(parent.path)")
    }

    private static func removeStagingDirectoryIfEmpty(_ stagingDirectory: StagingDirectory) -> Bool {
        var information = stat()
        let inspected = stagingDirectory.url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &information)
        }
        if inspected != 0 {
            return errno == ENOENT
        }
        guard information.st_mode & S_IFMT == S_IFDIR,
              OutputIdentity(device: information.st_dev, inode: information.st_ino) == stagingDirectory.identity
        else {
            return false
        }
        let removed = stagingDirectory.url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return rmdir(path)
        }
        return removed == 0 || errno == ENOENT
    }

    private static func requireAbsent(_ url: URL) throws {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &information)
        }
        if result == 0 {
            throw PeekabooError.fileIOError("Video output already exists: \(url.path)")
        }
        guard errno == ENOENT else {
            throw PeekabooError.fileIOError("Video output could not be inspected safely: \(url.path)")
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
