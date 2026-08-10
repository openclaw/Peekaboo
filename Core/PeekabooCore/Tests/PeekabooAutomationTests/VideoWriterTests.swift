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
    func `partial video cleanup failure is surfaced and retains the artifact`() throws {
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
        try Data("partial".utf8).write(to: output)

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
