@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooCore

@MainActor
struct VideoWriterTests {
    @Test
    func `scaledVideoSize caps longest edge and keeps aspect`() {
        let size = CGSize(width: 4000, height: 2000)
        let capped = WatchCaptureSession.scaledVideoSize(for: size, maxDimension: 1440)
        #expect(capped.width == 1440)
        #expect(capped.height == 720)

        let unchanged = WatchCaptureSession.scaledVideoSize(for: size, maxDimension: 5000)
        #expect(unchanged.width == 4000)
        #expect(unchanged.height == 2000)
    }

    @Test
    func `video sessions bound output size and preserve fps`() async throws {
        let frameSize = CGSize(width: 4000, height: 2000)
        let frameSource = FakeFrameSource(frameCount: 5, size: frameSize)
        let outputDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let videoOut = outputDir.appendingPathComponent("capture.mp4").path

        let options = CaptureOptions(
            duration: 5,
            idleFps: 1,
            activeFps: 12,
            changeThresholdPercent: 0,
            heartbeatSeconds: 0,
            quietMsToIdle: 0,
            maxFrames: 10,
            maxMegabytes: nil,
            highlightChanges: false,
            captureFocus: .auto,
            resolutionCap: 1440,
            diffStrategy: .fast,
            diffBudgetMs: nil)

        let config = WatchCaptureConfiguration(
            scope: CaptureScope(kind: .frontmost),
            options: options,
            outputRoot: outputDir,
            autoclean: WatchAutocleanConfig(minutes: 120, managed: false),
            sourceKind: .video,
            videoIn: "mock.mov",
            videoOut: videoOut,
            keepAllFrames: true)

        let deps = WatchCaptureDependencies(
            screenCapture: NoOpScreenCaptureService(),
            screenService: NoOpScreenService(),
            frameSource: frameSource)

        let session = WatchCaptureSession(dependencies: deps, configuration: config)
        let result = try await session.run()

        let asset = AVAsset(url: URL(fileURLWithPath: videoOut))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let natural = naturalSize.applying(preferredTransform)
        let width = Int(abs(natural.width.rounded()))
        let height = Int(abs(natural.height.rounded()))

        let nominalFrameRate = try await track.load(.nominalFrameRate)

        #expect(width == 1440)
        #expect(height == 720)
        #expect(abs(Double(nominalFrameRate) - 12) < 0.5)
        #expect(result.videoOut?.hasSuffix("capture.mp4") == true)
        #expect(result.videoArtifactCustody?.path == URL(fileURLWithPath: videoOut).standardizedFileURL.path)
        #expect(result.videoArtifactCustody?.byteCount ?? 0 > 0)
        var videoInformation = stat()
        #expect(videoOut.withCString { lstat($0, &videoInformation) } == 0)
        #expect((videoInformation.st_mode & 0o777) == (S_IRUSR | S_IWUSR))
        try CaptureArtifactIntegrityValidator.validate(result)
    }

    @Test
    func `video timestamps follow asset timeline, not wall clock`() async throws {
        let timestamps = [0, 500, 1000, 1500]
        let frameSource = FakeFrameSource(
            frameCount: timestamps.count,
            size: CGSize(width: 100, height: 50),
            timestampsMs: timestamps)
        let outputDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let options = CaptureOptions(
            duration: 5,
            idleFps: 60,
            activeFps: 60,
            changeThresholdPercent: 0,
            heartbeatSeconds: 0,
            quietMsToIdle: 0,
            maxFrames: 10,
            maxMegabytes: nil,
            highlightChanges: false,
            captureFocus: .auto,
            resolutionCap: nil,
            diffStrategy: .fast,
            diffBudgetMs: nil)

        let config = WatchCaptureConfiguration(
            scope: CaptureScope(kind: .frontmost),
            options: options,
            outputRoot: outputDir,
            autoclean: WatchAutocleanConfig(minutes: 120, managed: false),
            sourceKind: .video,
            videoIn: "mock.mov",
            videoOut: nil,
            keepAllFrames: true)

        let deps = WatchCaptureDependencies(
            screenCapture: NoOpScreenCaptureService(),
            screenService: NoOpScreenService(),
            frameSource: frameSource)

        let session = WatchCaptureSession(dependencies: deps, configuration: config)
        let result = try await session.run()

        let observed = result.frames.map(\.timestampMs)
        #expect(observed == timestamps)
    }

    @Test
    func `video writer refuses a public output that exists before initialization`() throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-video-preexisting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let output = outputDir.appendingPathComponent("capture.mp4")
        let replacement = Data("preexisting".utf8)
        try replacement.write(to: output, options: .withoutOverwriting)

        #expect(throws: PeekabooError.self) {
            _ = try VideoWriter(outputPath: output.path, width: 20, height: 20, fps: 2)
        }
        #expect(try Data(contentsOf: output) == replacement)
    }

    @Test
    func `video writer staging name stays bounded for a long public basename`() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-video-long-name-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let output = outputDir.appendingPathComponent(String(repeating: "v", count: 220) + ".mp4")
        let writer = try VideoWriter(outputPath: output.path, width: 20, height: 20, fps: 2)
        let stagingDirectory = writer.stagingURL.deletingLastPathComponent()
        let image = try #require(Self.makeSolidImage(size: CGSize(width: 20, height: 20)))

        try await writer.append(image: image)
        let custody = try await writer.finish()

        #expect(writer.stagingURL.lastPathComponent == "video.mp4")
        #expect(custody.path == output.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    @Test
    func `video writer refuses a public output created while staging`() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-video-public-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let output = outputDir.appendingPathComponent("capture.mp4")
        let writer = try VideoWriter(outputPath: output.path, width: 20, height: 20, fps: 2)
        let image = try #require(Self.makeSolidImage(size: CGSize(width: 20, height: 20)))
        try await writer.append(image: image)
        let replacement = Data("replacement".utf8)
        let stagingDirectory = writer.stagingURL.deletingLastPathComponent()
        var stagingInformation = stat()
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: writer.stagingURL.path))
        #expect(stagingDirectory.path.withCString { lstat($0, &stagingInformation) } == 0)
        #expect(stagingInformation.st_mode & S_IFMT == S_IFDIR)
        #expect((stagingInformation.st_mode & 0o777) == S_IRWXU)

        await #expect(throws: PeekabooError.self) {
            _ = try await writer.finish(beforeCustodyValidation: {
                try replacement.write(to: output, options: .withoutOverwriting)
            })
        }
        #expect(!FileManager.default.fileExists(atPath: writer.stagingURL.path))
        #expect(!FileManager.default.fileExists(atPath: stagingDirectory.path))
        #expect(try Data(contentsOf: output) == replacement)
    }

    @Test
    func `video writer refuses a replaced staging path without deleting the replacement`() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-video-staging-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let output = outputDir.appendingPathComponent("capture.mp4")
        let writer = try VideoWriter(outputPath: output.path, width: 20, height: 20, fps: 2)
        let image = try #require(Self.makeSolidImage(size: CGSize(width: 20, height: 20)))
        try await writer.append(image: image)
        let replacement = Data("staging-replacement".utf8)

        await #expect(throws: CaptureArtifactIntegrityError.self) {
            _ = try await writer.finish(beforeCustodyValidation: {
                try FileManager.default.removeItem(at: writer.stagingURL)
                try replacement.write(to: writer.stagingURL, options: .withoutOverwriting)
            })
        }
        #expect(throws: PeekabooError.self) {
            try writer.abortAndRemovePartialOutput()
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: writer.stagingURL) == replacement)
    }

    @Test
    func `video writer refuses a replaced published path without deleting the replacement`() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-video-published-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let output = outputDir.appendingPathComponent("capture.mp4")
        let writer = try VideoWriter(outputPath: output.path, width: 20, height: 20, fps: 2)
        let image = try #require(Self.makeSolidImage(size: CGSize(width: 20, height: 20)))
        try await writer.append(image: image)
        let replacement = Data("published-replacement".utf8)

        await #expect(throws: CaptureArtifactIntegrityError.self) {
            _ = try await writer.finish(afterPublication: {
                try FileManager.default.removeItem(at: output)
                try replacement.write(to: output, options: .withoutOverwriting)
            })
        }
        #expect(throws: PeekabooError.self) {
            try writer.abortAndRemovePartialOutput()
        }
        #expect(!FileManager.default.fileExists(atPath: writer.stagingURL.path))
        #expect(try Data(contentsOf: output) == replacement)
    }

    @Test
    func `video writer cleans output when initial custody binding fails`() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-video-custody-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let output = outputDir.appendingPathComponent("capture.mp4")
        var openerWasCalled = false
        let writer = try VideoWriter(
            outputPath: output.path,
            width: 20,
            height: 20,
            fps: 2,
            custodyDescriptorOpener: { _ in
                openerWasCalled = true
                errno = EMFILE
                return -1
            })
        #expect(!openerWasCalled)
        let stagingDirectory = writer.stagingURL.deletingLastPathComponent()
        let image = try #require(Self.makeSolidImage(size: CGSize(width: 20, height: 20)))

        await #expect(throws: PeekabooError.self) {
            try await writer.append(image: image)
        }
        #expect(openerWasCalled)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: writer.stagingURL.path))
        #expect(!FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    @Test
    func `partial video cleanup failure is surfaced and retains the artifact`() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-video-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let output = outputDir.appendingPathComponent("partial.mp4")
        let writer = try VideoWriter(
            outputPath: output.path,
            width: 20,
            height: 20,
            fps: 2,
            fileManager: FailingRemovalFileManager())
        let image = try #require(Self.makeSolidImage(size: CGSize(width: 20, height: 20)))
        try await writer.append(image: image)
        _ = try await writer.finish()

        let thrown = #expect(throws: PeekabooError.self) {
            try writer.abortAndRemovePartialOutput()
        }
        guard case .fileIOError = try #require(thrown) else {
            Issue.record("Expected cleanup failure to retain file-I/O identity")
            return
        }
        #expect(FileManager.default.fileExists(atPath: output.path))

        let primary = PeekabooError.captureFailed("frame persistence failed")
        let combined = try CaptureArtifactCleanupError(
            primaryError: primary,
            cleanupError: #require(thrown),
            artifactPath: output.path)
        #expect((combined.primaryError as? PeekabooError)?.localizedDescription == primary.localizedDescription)
        #expect(combined.localizedDescription.contains("Incomplete video cleanup failed"))

        let longPrimary = CaptureArtifactCleanupError(
            primaryError: PeekabooError.captureFailed(String(repeating: "primary-", count: 200)),
            cleanupError: PeekabooError.fileIOError("cleanup-marker"),
            artifactPath: String(repeating: "/long-path", count: 80))
        #expect(longPrimary.localizedDescription.contains("Incomplete video cleanup failed"))
        #expect(longPrimary.localizedDescription.contains("cleanup-marker"))
        #expect(longPrimary.localizedDescription.utf8.count <= 512)
    }

    private static func makeSolidImage(size: CGSize) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage()
    }
}

// MARK: - Test fakes

private final class FakeFrameSource: CaptureFrameSource {
    private var remaining: Int
    private let size: CGSize
    private let timestampsMs: [Int]?
    private var produced: Int = 0

    init(frameCount: Int, size: CGSize, timestampsMs: [Int]? = nil) {
        self.remaining = frameCount
        self.size = size
        self.timestampsMs = timestampsMs
    }

    func nextFrame() async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        guard self.remaining > 0 else { return nil }
        self.remaining -= 1
        let videoMs: Int? = if let timestamps = self.timestampsMs, self.produced < timestamps.count {
            timestamps[self.produced]
        } else {
            nil
        }
        self.produced += 1
        let image = FakeFrameSource.makeSolidImage(size: self.size)
        let meta = CaptureMetadata(size: self.size, mode: .screen, videoTimestampMs: videoMs, timestamp: Date())
        return (image, meta)
    }

    private static func makeSolidImage(size: CGSize) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let width = Int(size.width)
        let height = Int(size.height)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 200, count: width * height * bytesPerPixel)
        guard
            let ctx = CGContext(
                data: &data,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return nil
        }
        return ctx.makeImage()
    }
}

private struct NoOpScreenCaptureService: ScreenCaptureServiceProtocol {
    func captureScreen(
        displayIndex: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        throw PeekabooError.captureFailed(reason: "unused")
    }

    func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        throw PeekabooError.captureFailed(reason: "unused")
    }

    func captureFrontmost(
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        throw PeekabooError.captureFailed(reason: "unused")
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        throw PeekabooError.captureFailed(reason: "unused")
    }

    func hasScreenRecordingPermission() async -> Bool {
        true
    }
}

private struct NoOpScreenService: ScreenServiceProtocol {
    func listScreens() -> [ScreenInfo] {
        []
    }

    func screenContainingWindow(bounds: CGRect) -> ScreenInfo? {
        nil
    }

    func screen(at index: Int) -> ScreenInfo? {
        nil
    }

    var primaryScreen: ScreenInfo? {
        nil
    }
}

private final class FailingRemovalFileManager: FileManager, @unchecked Sendable {
    override func fileExists(atPath _: String) -> Bool {
        false
    }

    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: URL.path])
    }
}
