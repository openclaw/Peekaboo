import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooCore

@MainActor
struct CaptureSessionTests {
    @Test
    func `keeps all frames and writes contact/metadata`() async throws {
        let framesToEmit = 5
        let frameSource = FakeFrameSource(frameCount: framesToEmit, size: CGSize(width: 100, height: 80))
        let outputDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-capture-test-\(UUID().uuidString)", isDirectory: true)

        let deps = WatchCaptureDependencies(
            screenCapture: NoOpScreenCaptureService(),
            screenService: NoOpScreenService(),
            frameSource: frameSource)

        let options = CaptureOptions(
            duration: 10,
            idleFps: 1,
            activeFps: 1,
            changeThresholdPercent: 0,
            heartbeatSeconds: 0,
            quietMsToIdle: 0,
            maxFrames: 50,
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
            sourceKind: .live,
            videoIn: nil,
            videoOut: nil,
            keepAllFrames: true)

        let session = WatchCaptureSession(dependencies: deps, configuration: config)
        let result = try await session.run()

        #expect(result.frames.count == framesToEmit)
        #expect(result.stats.framesKept == framesToEmit)
        #expect(result.stats.captureAttempts == framesToEmit + 1)
        #expect(result.stats.framesSampled == framesToEmit)
        #expect(result.stats.captureFailures == 0)
        #expect(result.stats.framesDiffFiltered == 0)
        #expect(FileManager.default.fileExists(atPath: result.contactSheet.path))
        #expect(FileManager.default.fileExists(atPath: result.metadataFile))
    }

    @Test
    func `video capture result preserves video sampling options`() async throws {
        let frameSource = FakeFrameSource(frameCount: 1, size: CGSize(width: 100, height: 80))
        let outputDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-video-options-test-\(UUID().uuidString)", isDirectory: true)

        let options = CaptureOptions(
            duration: 3600,
            idleFps: 60,
            activeFps: 60,
            changeThresholdPercent: 2.5,
            heartbeatSeconds: 5,
            quietMsToIdle: 1000,
            maxFrames: 10,
            maxMegabytes: nil,
            highlightChanges: false,
            captureFocus: .auto,
            resolutionCap: 1440,
            diffStrategy: .fast,
            diffBudgetMs: nil)
        let videoOptions = CaptureVideoOptionsSnapshot(
            sampleFps: nil,
            everyMs: 100,
            effectiveFps: 10,
            startMs: 250,
            endMs: 1250,
            keepAllFrames: true)
        let config = WatchCaptureConfiguration(
            scope: CaptureScope(kind: .frontmost),
            options: options,
            outputRoot: outputDir,
            autoclean: WatchAutocleanConfig(minutes: 120, managed: false),
            sourceKind: .video,
            videoIn: "/tmp/input.mov",
            videoOut: nil,
            keepAllFrames: true,
            videoOptions: videoOptions)

        let session = WatchCaptureSession(
            dependencies: WatchCaptureDependencies(
                screenCapture: NoOpScreenCaptureService(),
                screenService: NoOpScreenService(),
                frameSource: frameSource),
            configuration: config)
        let result = try await session.run()

        #expect(result.source == .video)
        #expect(result.videoIn == "/tmp/input.mov")
        #expect(result.options.video == videoOptions)
    }

    @Test
    func `finite source with no valid image fails before contact or metadata output`() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-empty-capture-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let source = DiagnosticFrameSource(steps: [.invalid("missing image")])
        let session = Self.makeSession(source: source, sourceKind: .live, outputDir: outputDir)

        let thrown = await #expect(throws: CaptureNoValidFramesError.self) {
            _ = try await session.run()
        }
        let error = try #require(thrown)

        #expect(error.source == .live)
        #expect(error.framesDropped == 1)
        #expect(!FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("contact.png").path))
        #expect(!FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("metadata.json").path))
    }

    @Test
    func `contact sheet rejects empty and unreadable source frames`() throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-contact-honesty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        #expect(throws: PeekabooError.self) {
            _ = try WatchCaptureArtifactWriter.buildContactSheet(
                frames: [],
                outputRoot: outputDir,
                columns: 2,
                thumbSize: CGSize(width: 20, height: 20))
        }

        let missing = CaptureFrameInfo(
            index: 7,
            path: outputDir.appendingPathComponent("missing.png").path,
            file: "missing.png",
            timestampMs: 0,
            changePercent: 0,
            reason: .first)
        let thrown = #expect(throws: PeekabooError.self) {
            _ = try WatchCaptureArtifactWriter.buildContactSheet(
                frames: [missing],
                outputRoot: outputDir,
                columns: 2,
                thumbSize: CGSize(width: 20, height: 20))
        }
        guard case .fileIOError = try #require(thrown) else {
            Issue.record("Expected unreadable contact source to remain a file-I/O error")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("contact.png").path))
    }

    @Test
    func `existing capture artifacts are rejected without being mistaken for current output`() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-stale-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let oldContact = outputDir.appendingPathComponent("contact.png")
        let oldAction = outputDir.appendingPathComponent("action.json")
        try Data("old-contact".utf8).write(to: oldContact)
        try Data("old-action".utf8).write(to: oldAction)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let session = Self.makeSession(
            source: DiagnosticFrameSource(steps: [.invalid("missing image")]),
            sourceKind: .video,
            outputDir: outputDir)

        let thrown = await #expect(throws: PeekabooError.self) {
            _ = try await session.run()
        }
        guard case .fileIOError = try #require(thrown) else {
            Issue.record("Expected stale capture output to fail as file I/O")
            return
        }
        #expect(try Data(contentsOf: oldContact) == Data("old-contact".utf8))
        #expect(try Data(contentsOf: oldAction) == Data("old-action".utf8))
        #expect(!FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("metadata.json").path))
    }

    @Test
    func `persistent transient live failure stops after bounded retries without laundering the error`() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-transient-empty-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let transient = NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
            code: -3801,
            userInfo: [NSLocalizedDescriptionKey: "The user declined TCC for application, window, display capture"])
        let service = AlwaysFailingScreenCaptureService(error: transient)
        let session = WatchCaptureSession(
            dependencies: WatchCaptureDependencies(
                screenCapture: service,
                screenService: NoOpScreenService()),
            configuration: WatchCaptureConfiguration(
                scope: CaptureScope(kind: .frontmost),
                options: Self.options(duration: 10),
                outputRoot: outputDir,
                autoclean: WatchAutocleanConfig(minutes: 120, managed: false),
                sourceKind: .live,
                keepAllFrames: true))

        let thrown = await #expect(throws: NSError.self) {
            _ = try await session.run()
        }
        let error = try #require(thrown)

        #expect(error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain")
        #expect(service.attemptCount == 4)
    }

    @Test
    func `partial video decode keeps valid frame and reports decode failures separately`() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-partial-video-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let source = DiagnosticFrameSource(steps: [
            .invalid("first decode failure"),
            .valid,
            .invalid("last decode failure"),
        ])
        let session = Self.makeSession(source: source, sourceKind: .video, outputDir: outputDir)

        let result = try await session.run()

        #expect(result.frames.count == 1)
        #expect(result.stats.framesDropped == 2)
        #expect(result.stats.decodeFailures == 2)
        let warning = try #require(result.warnings.first(where: { $0.code == .videoDecodeFailure }))
        #expect(warning.details?["count"] == "2")
        #expect(warning.details?["first_error"] == "first decode failure")
        #expect(warning.details?["last_error"] == "last decode failure")
        #expect(!result.warnings.contains(where: { $0.code == .noMotion }))
    }

    @Test
    func `all-bad video fails with bounded decode diagnostics`() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-bad-video-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let source = DiagnosticFrameSource(steps: [
            .invalid(String(repeating: "界", count: 700)),
            .invalid(String(repeating: "x", count: 700)),
        ])
        let session = Self.makeSession(source: source, sourceKind: .video, outputDir: outputDir)

        let thrown = await #expect(throws: CaptureNoValidFramesError.self) {
            _ = try await session.run()
        }
        let error = try #require(thrown)

        #expect(error.source == .video)
        #expect(error.decodeFailures == 2)
        #expect((error.firstDecodeError?.utf8.count ?? 0) <= CaptureDiagnosticSanitizer.maximumUTF8Bytes)
        #expect((error.lastDecodeError?.utf8.count ?? 0) <= CaptureDiagnosticSanitizer.maximumUTF8Bytes)
        #expect(error.firstDecodeError?.hasSuffix("…") == true)
        #expect(error.lastDecodeError?.hasSuffix("…") == true)
        #expect(error.localizedDescription.contains("Video capture produced no decodable frames"))
    }

    @Test
    func `video decode attempts honor max-frames even when every sample is invalid`() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-video-attempt-cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let source = DiagnosticFrameSource(steps: Array(repeating: .invalid("bad sample"), count: 10))
        let session = Self.makeSession(
            source: source,
            sourceKind: .video,
            outputDir: outputDir,
            maxFrames: 2)

        let thrown = await #expect(throws: CaptureNoValidFramesError.self) {
            _ = try await session.run()
        }
        let error = try #require(thrown)

        #expect(error.framesDropped == 2)
        #expect(error.decodeFailures == 2)
        #expect(source.remainingStepCount == 8)
    }

    @Test
    func `partial video reports max-frames hit from sample attempts`() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-video-partial-cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let source = DiagnosticFrameSource(steps: [.invalid("bad sample"), .valid, .valid])
        let session = Self.makeSession(
            source: source,
            sourceKind: .video,
            outputDir: outputDir,
            maxFrames: 2)

        let result = try await session.run()

        #expect(result.frames.count == 1)
        #expect(result.stats.decodeFailures == 1)
        #expect(result.stats.maxFramesHit)
        #expect(result.warnings.contains { $0.code == .frameCap })
        #expect(source.remainingStepCount == 1)
    }

    @Test
    func `cancellation and permanent source errors propagate without no-frame reclassification`() async throws {
        let cancelDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cancel-source-\(UUID().uuidString)", isDirectory: true)
        let failureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-failed-source-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: cancelDir)
            try? FileManager.default.removeItem(at: failureDir)
        }

        let cancelled = Self.makeSession(
            source: DiagnosticFrameSource(steps: [.failure(CancellationError())]),
            sourceKind: .video,
            outputDir: cancelDir)
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.run()
        }

        let permanentError = PeekabooError.fileIOError("permanent source failure")
        let failed = Self.makeSession(
            source: DiagnosticFrameSource(steps: [.failure(permanentError)]),
            sourceKind: .video,
            outputDir: failureDir)
        let thrown = await #expect(throws: PeekabooError.self) {
            _ = try await failed.run()
        }
        #expect(try #require(thrown).localizedDescription.contains("permanent source failure"))
    }

    @Test
    func `video writer is removed when frame persistence fails after append`() async throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-video-abort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outputDir.appendingPathComponent("keep-0001.png"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let videoURL = outputDir.appendingPathComponent("capture.mp4")
        let session = WatchCaptureSession(
            dependencies: WatchCaptureDependencies(
                screenCapture: NoOpScreenCaptureService(),
                screenService: NoOpScreenService(),
                frameSource: FakeFrameSource(frameCount: 1, size: CGSize(width: 100, height: 80))),
            configuration: WatchCaptureConfiguration(
                scope: CaptureScope(kind: .frontmost),
                options: Self.options(duration: 1),
                outputRoot: outputDir,
                autoclean: WatchAutocleanConfig(minutes: 120, managed: false),
                sourceKind: .video,
                videoIn: "/tmp/input.mov",
                videoOut: videoURL.path,
                keepAllFrames: true))

        await #expect(throws: PeekabooError.self) {
            _ = try await session.run()
        }
        #expect(!FileManager.default.fileExists(atPath: videoURL.path))
    }

    private static func makeSession(
        source: some CaptureFrameSource,
        sourceKind: CaptureSessionResult.Source,
        outputDir: URL,
        maxFrames: Int = 50) -> WatchCaptureSession
    {
        WatchCaptureSession(
            dependencies: WatchCaptureDependencies(
                screenCapture: NoOpScreenCaptureService(),
                screenService: NoOpScreenService(),
                frameSource: source),
            configuration: WatchCaptureConfiguration(
                scope: CaptureScope(kind: .frontmost),
                options: self.options(duration: 1, maxFrames: maxFrames),
                outputRoot: outputDir,
                autoclean: WatchAutocleanConfig(minutes: 120, managed: false),
                sourceKind: sourceKind,
                videoIn: sourceKind == .video ? "/tmp/input.mov" : nil,
                keepAllFrames: true))
    }

    private static func options(duration: TimeInterval, maxFrames: Int = 50) -> CaptureOptions {
        CaptureOptions(
            duration: duration,
            idleFps: 5,
            activeFps: 5,
            changeThresholdPercent: 0,
            heartbeatSeconds: 0,
            quietMsToIdle: 0,
            maxFrames: maxFrames,
            maxMegabytes: nil,
            highlightChanges: false,
            captureFocus: .background,
            resolutionCap: nil,
            diffStrategy: .fast,
            diffBudgetMs: nil)
    }
}

// MARK: - Fakes

private final class FakeFrameSource: CaptureFrameSource {
    private var remaining: Int
    private let size: CGSize

    init(frameCount: Int, size: CGSize) {
        self.remaining = frameCount
        self.size = size
    }

    func nextFrame() async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        guard self.remaining > 0 else { return nil }
        self.remaining -= 1
        let image = FakeFrameSource.makeSolidImage(size: self.size)
        let meta = CaptureMetadata(size: size, mode: .screen, timestamp: Date())
        return (image, meta)
    }

    fileprivate static func makeSolidImage(size: CGSize) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let width = Int(size.width)
        let height = Int(size.height)
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 255, count: width * height * bytesPerPixel)
        let ctx = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        return ctx?.makeImage()
    }
}

@MainActor
private final class DiagnosticFrameSource: CaptureFrameSourceDiagnosticsProviding {
    enum Step {
        case failure(any Error)
        case invalid(String)
        case valid
    }

    private var steps: [Step]
    private var decodeErrors: [String] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    var remainingStepCount: Int {
        self.steps.count
    }

    var captureDiagnostics: CaptureFrameSourceDiagnostics {
        CaptureFrameSourceDiagnostics(
            decodeFailures: self.decodeErrors.count,
            firstDecodeError: self.decodeErrors.first,
            lastDecodeError: self.decodeErrors.last)
    }

    func nextFrame() async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        guard !self.steps.isEmpty else { return nil }
        let step = self.steps.removeFirst()
        let metadata = CaptureMetadata(size: CGSize(width: 100, height: 80), mode: .screen, timestamp: Date())
        switch step {
        case let .failure(error):
            throw error
        case let .invalid(message):
            self.decodeErrors.append(message)
            return (nil, metadata)
        case .valid:
            return (FakeFrameSource.makeSolidImage(size: metadata.size), metadata)
        }
    }
}

@MainActor
private final class AlwaysFailingScreenCaptureService: ScreenCaptureServiceProtocol {
    let error: any Error
    private(set) var attemptCount = 0

    init(error: any Error) {
        self.error = error
    }

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.attemptCount += 1
        throw self.error
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.attemptCount += 1
        throw self.error
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.attemptCount += 1
        throw self.error
    }

    func captureArea(
        _: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.attemptCount += 1
        throw self.error
    }

    func hasScreenRecordingPermission() async -> Bool {
        true
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
        [
            ScreenInfo(
                index: 0,
                name: "Mock",
                frame: .zero,
                visibleFrame: .zero,
                isPrimary: true,
                scaleFactor: 2.0,
                displayID: 0),
        ]
    }

    func screenContainingWindow(bounds: CGRect) -> ScreenInfo? {
        self.listScreens().first
    }

    func screen(at index: Int) -> ScreenInfo? {
        self.listScreens().first(where: { $0.index == index })
    }

    var primaryScreen: ScreenInfo? {
        self.listScreens().first
    }
}
