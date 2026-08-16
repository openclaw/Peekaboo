@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PeekabooFoundation
import Testing
import UniformTypeIdentifiers
@testable @_spi(Testing) import PeekabooAutomationKit

struct WatchCaptureSessionTests {
    @Test
    @MainActor
    func `video decoder suspension releases MainActor`() async throws {
        let image = try #require(WatchCaptureArtifactWriter.makeCGImage(from: Self.makePNG(
            size: CGSize(width: 20, height: 20))))
        let decoder = ControlledVideoFrameDecoder(image: image)
        let source = VideoFrameSource(
            timeline: VideoFrameTimeline(
                start: .zero,
                end: CMTime(seconds: 1, preferredTimescale: 1000),
                interval: CMTime(seconds: 0.5, preferredTimescale: 1000)),
            effectiveFPS: 2,
            decoder: decoder)

        let frameTask = Task { @MainActor in
            try await source.nextFrame()
        }
        await decoder.waitUntilEntered()
        let mainActorRemainedResponsive = await MainActor.run { true }
        #expect(mainActorRemainedResponsive)
        await decoder.release()
        #expect(try await frameTask.value?.cgImage != nil)
    }

    @Test
    @MainActor
    func `video decoder timeout cancels generator without awaiting noncooperative work`() async throws {
        let image = try #require(WatchCaptureArtifactWriter.makeCGImage(from: Self.makePNG(
            size: CGSize(width: 20, height: 20))))
        let decoder = NoncooperativeVideoFrameDecoder(image: image)
        let source = VideoFrameSource(
            timeline: VideoFrameTimeline(
                start: .zero,
                end: CMTime(seconds: 1, preferredTimescale: 1000),
                interval: CMTime(seconds: 0.5, preferredTimescale: 1000)),
            effectiveFPS: 2,
            decoder: decoder,
            decodeTimeout: .milliseconds(30))

        let releaseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            decoder.release()
        }
        let started = ContinuousClock.now
        let frame = try await source.nextFrame()
        let elapsed = started.duration(to: .now)

        #expect(frame?.cgImage == nil)
        #expect(elapsed < .milliseconds(150))
        #expect(decoder.cancelCount == 1)
        #expect(source.captureDiagnostics.decodeFailures == 1)
        await releaseTask.value
    }

    @Test
    @MainActor
    func `video decoder file IO errors are not counted as recoverable decode loss`() async throws {
        let source = VideoFrameSource(
            timeline: VideoFrameTimeline(
                start: .zero,
                end: CMTime(seconds: 1, preferredTimescale: 1000),
                interval: CMTime(seconds: 0.5, preferredTimescale: 1000)),
            effectiveFPS: 2,
            decoder: FailingVideoFrameDecoder(error: PeekabooError.fileIOError("read failed")))

        let thrown = await #expect(throws: PeekabooError.self) {
            _ = try await source.nextFrame()
        }
        guard case .fileIOError = try #require(thrown) else {
            Issue.record("Expected file-I/O decode failure to retain its type")
            return
        }
        #expect(source.captureDiagnostics.decodeFailures == 0)

        let recoverable = VideoFrameSource(
            timeline: VideoFrameTimeline(
                start: .zero,
                end: CMTime(seconds: 1, preferredTimescale: 1000),
                interval: CMTime(seconds: 0.5, preferredTimescale: 1000)),
            effectiveFPS: 2,
            decoder: FailingVideoFrameDecoder(error: PeekabooError.captureFailed("decode failed")))
        let output = try await recoverable.nextFrame()
        #expect(output?.cgImage == nil)
        #expect(recoverable.captureDiagnostics.decodeFailures == 1)
    }

    @Test
    func `Fast diff detects change and bounding box`() {
        let prev = WatchFrameDiffer.LumaBuffer(width: 2, height: 2, pixels: [0, 0, 0, 0])
        let curr = WatchFrameDiffer.LumaBuffer(width: 2, height: 2, pixels: [0, 255, 0, 0])
        let result = WatchFrameDiffer.computeChange(
            using: .init(
                strategy: .fast,
                diffBudgetMs: nil,
                previous: prev,
                current: curr,
                deltaThreshold: 10,
                originalSize: CGSize(width: 200, height: 200)))
        #expect(result.changePercent > 0)
        let firstBox = result.boundingBoxes.first
        #expect(abs((firstBox?.origin.x ?? 0) - 100) < 0.1)
        #expect(abs((firstBox?.origin.y ?? 0) - 0) < 0.1)
    }

    @Test
    @MainActor
    func `Output diff compares with previous retained frame after dropped samples`() throws {
        let png = Self.makePNG(size: CGSize(width: 40, height: 40))
        let session = WatchCaptureSession(
            dependencies: WatchCaptureDependencies(
                screenCapture: StubScreenCaptureService(result: png, size: CGSize(width: 40, height: 40)),
                screenService: StubScreenService()),
            configuration: WatchCaptureConfiguration(
                scope: CaptureScope(kind: .frontmost),
                options: Self.defaultWatchOptions(changeThresholdPercent: 2.5),
                outputRoot: FileManager.default.temporaryDirectory,
                autoclean: WatchAutocleanConfig(minutes: 1, managed: false)))
        let previousKept = WatchFrameDiffer.LumaBuffer(
            width: 4,
            height: 4,
            pixels: Array(repeating: 0, count: 16))
        var changedPixels = Array(repeating: UInt8(0), count: 16)
        changedPixels[5] = 255
        let current = WatchFrameDiffer.LumaBuffer(width: 4, height: 4, pixels: changedPixels)
        let sampledDiff = WatchCaptureSession.DiffComputation(
            changePercent: 0,
            motionBoxes: nil,
            buffer: current,
            enterActive: false)

        let retainedDiff = session.diffForOutputFrame(
            sampledDiff: sampledDiff,
            previousKept: previousKept,
            previousKeptFrameIndex: 0,
            currentFrameIndex: 2,
            originalSize: CGSize(width: 40, height: 40))
        #expect(retainedDiff.changePercent == 6.25)
        #expect(retainedDiff.motionBoxes?.isEmpty == false)

        let adjacentDiff = session.diffForOutputFrame(
            sampledDiff: sampledDiff,
            previousKept: previousKept,
            previousKeptFrameIndex: 1,
            currentFrameIndex: 2,
            originalSize: CGSize(width: 40, height: 40))
        #expect(adjacentDiff.changePercent == 0)
        #expect(adjacentDiff.motionBoxes == nil)

        let resizedSize = CGSize(width: 40, height: 80)
        let resizedImage = try #require(WatchCaptureArtifactWriter.makeCGImage(from: Self.makePNG(size: resizedSize)))
        let adjacentResizeDiff = session.computeDiff(cgImage: resizedImage, previous: previousKept)
        #expect(adjacentResizeDiff.changePercent == 100)
        #expect(adjacentResizeDiff.motionBoxes == [CGRect(origin: .zero, size: resizedSize)])
        #expect(adjacentResizeDiff.buffer.width == 40)
        #expect(adjacentResizeDiff.buffer.height == 80)
        #expect(adjacentResizeDiff.enterActive)

        let settledResizeSample = WatchCaptureSession.DiffComputation(
            changePercent: 0,
            motionBoxes: nil,
            buffer: adjacentResizeDiff.buffer,
            enterActive: false)
        let retainedResizeDiff = session.diffForOutputFrame(
            sampledDiff: settledResizeSample,
            previousKept: previousKept,
            previousKeptFrameIndex: 0,
            currentFrameIndex: 2,
            originalSize: resizedSize)
        #expect(retainedResizeDiff.changePercent == 100)
        #expect(retainedResizeDiff.motionBoxes == [CGRect(origin: .zero, size: resizedSize)])
        #expect(retainedResizeDiff.buffer.width == adjacentResizeDiff.buffer.width)
        #expect(retainedResizeDiff.buffer.height == adjacentResizeDiff.buffer.height)
        #expect(retainedResizeDiff.buffer.pixels == adjacentResizeDiff.buffer.pixels)
        #expect(retainedResizeDiff.enterActive)
    }

    @Test
    func `Quality diff near-zero for identical frames`() {
        let buffer = WatchFrameDiffer.LumaBuffer(width: 4, height: 4, pixels: Array(repeating: 64, count: 16))
        let result = WatchFrameDiffer.computeChange(
            using: .init(
                strategy: .quality,
                diffBudgetMs: nil,
                previous: buffer,
                current: buffer,
                deltaThreshold: 10,
                originalSize: CGSize(width: 100, height: 100)))
        #expect(result.changePercent < 0.01)
        #expect(result.boundingBoxes.isEmpty)
    }

    @Test
    func `Quality diff caps at 100`() {
        let prev = WatchFrameDiffer.LumaBuffer(width: 2, height: 2, pixels: [0, 0, 0, 0])
        let curr = WatchFrameDiffer.LumaBuffer(width: 2, height: 2, pixels: [255, 255, 255, 255])
        let result = WatchFrameDiffer.computeChange(
            using: .init(
                strategy: .quality,
                diffBudgetMs: nil,
                previous: prev,
                current: curr,
                deltaThreshold: 10,
                originalSize: CGSize(width: 100, height: 100)))
        #expect(result.changePercent <= 100)
    }

    @Test
    func `Bounding boxes always include overall motion bounds`() {
        // Two disjoint regions far apart should still report a union box that spans both.
        let width = 8
        let height = 8
        let prev = WatchFrameDiffer.LumaBuffer(
            width: width,
            height: height,
            pixels: Array(repeating: 0, count: width * height))
        var pixels = Array(repeating: UInt8(0), count: width * height)
        func index(_ x: Int, _ y: Int) -> Int {
            y * width + x
        }
        // Activate a block in the top-left and another in the bottom-right.
        for y in 0..<2 {
            for x in 0..<2 {
                pixels[index(x, y)] = 255
            }
        }
        for y in (height - 2)..<height {
            for x in (width - 2)..<width {
                pixels[index(x, y)] = 255
            }
        }
        let curr = WatchFrameDiffer.LumaBuffer(width: width, height: height, pixels: pixels)
        let result = WatchFrameDiffer.computeChange(
            using: .init(
                strategy: .fast,
                diffBudgetMs: nil,
                previous: prev,
                current: curr,
                deltaThreshold: 1,
                originalSize: CGSize(width: 800, height: 800)))
        guard let union = result.boundingBoxes.first else {
            Issue.record("Expected bounding boxes to be reported")
            return
        }
        #expect(union.origin.x == 0)
        #expect(union.origin.y == 0)
        #expect(union.width == 800)
        #expect(union.height == 800)
        #expect(result.boundingBoxes.count <= 5)
    }

    @Test
    func `Video frame timeline samples lazily without precomputed frame cap`() {
        var timeline = VideoFrameTimeline(
            start: .zero,
            end: CMTime(seconds: 60, preferredTimescale: 1000),
            interval: CMTime(value: 1, timescale: 1000))

        #expect(timeline.next() == .zero)
        #expect(timeline.next() == CMTime(value: 1, timescale: 1000))
        #expect(timeline.next() == CMTime(value: 2, timescale: 1000))
    }

    @Test
    func `Video frame timeline treats trim end as exclusive`() {
        var timeline = VideoFrameTimeline(
            start: .zero,
            end: CMTime(value: 2, timescale: 1000),
            interval: CMTime(value: 1, timescale: 1000))

        #expect(timeline.next() == .zero)
        #expect(timeline.next() == CMTime(value: 1, timescale: 1000))
        #expect(timeline.next() == nil)
    }

    @Test
    func `Video source rejects invalid sampling trim and resolution admission before file access`() async {
        let missing = URL(fileURLWithPath: "/tmp/peekaboo-missing-video-\(UUID().uuidString).mov")
        await #expect(throws: PeekabooError.self) {
            _ = try await VideoFrameSource(
                url: missing,
                sampleFps: 0,
                everyMs: nil,
                startMs: nil,
                endMs: nil,
                resolutionCap: nil)
        }
        await #expect(throws: PeekabooError.self) {
            _ = try await VideoFrameSource(
                url: missing,
                sampleFps: nil,
                everyMs: 0,
                startMs: nil,
                endMs: nil,
                resolutionCap: nil)
        }
        await #expect(throws: PeekabooError.self) {
            _ = try await VideoFrameSource(
                url: missing,
                sampleFps: nil,
                everyMs: nil,
                startMs: -1,
                endMs: nil,
                resolutionCap: nil)
        }
        await #expect(throws: PeekabooError.self) {
            _ = try await VideoFrameSource(
                url: missing,
                sampleFps: nil,
                everyMs: nil,
                startMs: nil,
                endMs: -1,
                resolutionCap: nil)
        }
        await #expect(throws: PeekabooError.self) {
            _ = try await VideoFrameSource(
                url: missing,
                sampleFps: nil,
                everyMs: nil,
                startMs: nil,
                endMs: nil,
                resolutionCap: 0)
        }
    }

    @Test
    func `Only the observed TCC contention signature receives a transient retry`() {
        let contention = NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
            code: -3801,
            userInfo: [NSLocalizedDescriptionKey: "The user declined TCC for application, window, display capture"])
        let invalidParameter = NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
            code: -3812,
            userInfo: [NSLocalizedDescriptionKey: "Invalid parameter"])
        let unrelatedDenial = NSError(
            domain: "example.test",
            code: -3801,
            userInfo: [NSLocalizedDescriptionKey: "The user declined TCC"])

        #expect(ScreenCaptureKitTransientError.retryDelayNanoseconds(after: contention) != nil)
        #expect(ScreenCaptureKitTransientError.retryDelayNanoseconds(after: invalidParameter) == nil)
        #expect(ScreenCaptureKitTransientError.retryDelayNanoseconds(after: unrelatedDenial) == nil)
    }

    @Test
    func `Autoclean removes old default capture sessions`() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-autoclean-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("capture-sessions", isDirectory: true)
        let oldSession = root.appendingPathComponent("capture-old", isDirectory: true)
        let currentSession = root.appendingPathComponent("capture-current", isDirectory: true)
        try FileManager.default.createDirectory(at: oldSession, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentSession, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: oldSession.path)

        let store = WatchCaptureSessionStore(
            outputRoot: currentSession,
            autocleanMinutes: 1,
            managedAutoclean: true,
            sessionId: "capture-current")
        let warning = store.performAutoclean()

        #expect(warning?.code == .autoclean)
        #expect(!FileManager.default.fileExists(atPath: oldSession.path))
        #expect(FileManager.default.fileExists(atPath: currentSession.path))
    }

    @Test
    func `Autoclean ignores non-positive retention and keeps current session`() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("peekaboo-autoclean-current-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("capture-sessions", isDirectory: true)
        let currentSession = root.appendingPathComponent("capture-current", isDirectory: true)
        try FileManager.default.createDirectory(at: currentSession, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: currentSession.path)

        let store = WatchCaptureSessionStore(
            outputRoot: currentSession,
            autocleanMinutes: 0,
            managedAutoclean: true,
            sessionId: "capture-current")
        let warning = store.performAutoclean()

        #expect(warning == nil)
        #expect(FileManager.default.fileExists(atPath: currentSession.path))
    }

    @Test
    @MainActor
    func `Live capture visualizer follows capture focus`() async throws {
        let png = Self.makePNG(size: CGSize(width: 20, height: 20))
        let scope = CaptureScope(kind: .frontmost)

        for (focus, expectedMode) in [
            (CaptureFocus.background, CaptureVisualizerMode.none),
            (.foreground, .watchCapture),
            (.auto, .watchCapture),
        ] {
            let capture = StubScreenCaptureService(result: png, size: CGSize(width: 20, height: 20))
            let provider = WatchCaptureFrameProvider(
                screenCapture: capture,
                frameSource: nil,
                scope: scope,
                options: CaptureOptions(
                    duration: 1,
                    idleFps: 1,
                    activeFps: 1,
                    changeThresholdPercent: 1,
                    heartbeatSeconds: 0,
                    quietMsToIdle: 0,
                    maxFrames: 1,
                    maxMegabytes: nil,
                    highlightChanges: false,
                    captureFocus: focus,
                    resolutionCap: nil,
                    diffStrategy: .fast,
                    diffBudgetMs: nil),
                regionValidator: WatchCaptureRegionValidator(screenService: nil))

            _ = try await provider.captureFrame()

            #expect(capture.capturedVisualizerModes == [expectedMode])
        }
    }

    @Test
    @MainActor
    func `Stops at max-frames cap and keeps first frame`() async throws {
        let png = Self.makePNG(size: CGSize(width: 20, height: 20))
        let capture = StubScreenCaptureService(result: png, size: CGSize(width: 20, height: 20))
        let screens = StubScreenService()
        let scope = CaptureScope(
            kind: .frontmost,
            screenIndex: nil,
            displayUUID: nil,
            windowId: nil,
            applicationIdentifier: nil,
            windowIndex: nil,
            region: nil)

        let options = CaptureOptions(
            duration: 2,
            idleFps: 5,
            activeFps: 5,
            changeThresholdPercent: 0,
            heartbeatSeconds: 0,
            quietMsToIdle: 0,
            maxFrames: 1,
            maxMegabytes: nil,
            highlightChanges: false,
            captureFocus: .auto,
            resolutionCap: nil,
            diffStrategy: .fast,
            diffBudgetMs: nil)

        let output = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("watch-cap-\(UUID().uuidString)", isDirectory: true)

        let dependencies = WatchCaptureDependencies(
            screenCapture: capture,
            screenService: screens)
        let configuration = WatchCaptureConfiguration(
            scope: scope,
            options: options,
            outputRoot: output,
            autoclean: WatchAutocleanConfig(minutes: 1, managed: false))
        let session = WatchCaptureSession(dependencies: dependencies, configuration: configuration)

        let result = try await session.run()
        #expect(result.frames.count == 1)
        #expect(result.warnings.contains { $0.code == .frameCap } || result.warnings.isEmpty == false)
    }

    @Test
    @MainActor
    func `Size cap is honored before any fallback capture`() async throws {
        let png = Self.makePNG(size: CGSize(width: 50, height: 50))
        let capture = StubScreenCaptureService(result: png, size: CGSize(width: 50, height: 50))
        let screens = StubScreenService()
        let scope = CaptureScope(
            kind: .frontmost,
            screenIndex: nil,
            displayUUID: nil,
            windowId: nil,
            applicationIdentifier: nil,
            windowIndex: nil,
            region: nil)

        let options = CaptureOptions(
            duration: 2,
            idleFps: 5,
            activeFps: 5,
            changeThresholdPercent: 0,
            heartbeatSeconds: 0,
            quietMsToIdle: 0,
            maxFrames: 100,
            maxMegabytes: 0, // trigger immediately
            highlightChanges: false,
            captureFocus: .auto,
            resolutionCap: nil,
            diffStrategy: .fast,
            diffBudgetMs: nil)

        let output = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("watch-sizecap-\(UUID().uuidString)", isDirectory: true)

        let dependencies = WatchCaptureDependencies(
            screenCapture: capture,
            screenService: screens)
        let configuration = WatchCaptureConfiguration(
            scope: scope,
            options: options,
            outputRoot: output,
            autoclean: WatchAutocleanConfig(minutes: 1, managed: false))
        let session = WatchCaptureSession(dependencies: dependencies, configuration: configuration)

        let thrown = await #expect(throws: CaptureNoValidFramesError.self) {
            _ = try await session.run()
        }
        #expect(try #require(thrown).framesDropped == 0)
    }

    @Test
    @MainActor
    func `Stop request wakes cadence sleep`() async throws {
        let png = Self.makePNG(size: CGSize(width: 20, height: 20))
        let capture = StubScreenCaptureService(result: png, size: CGSize(width: 20, height: 20))
        let screens = StubScreenService()
        let output = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("watch-stop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }

        let options = CaptureOptions(
            duration: 30,
            idleFps: 0.1,
            activeFps: 1,
            changeThresholdPercent: 100,
            heartbeatSeconds: 0,
            quietMsToIdle: 0,
            maxFrames: 10,
            maxMegabytes: nil,
            highlightChanges: false,
            captureFocus: .auto,
            resolutionCap: nil,
            diffStrategy: .fast,
            diffBudgetMs: nil)
        let session = WatchCaptureSession(
            dependencies: WatchCaptureDependencies(screenCapture: capture, screenService: screens),
            configuration: WatchCaptureConfiguration(
                scope: CaptureScope(kind: .frontmost),
                options: options,
                outputRoot: output,
                autoclean: WatchAutocleanConfig(minutes: 1, managed: false)))

        let task = Task { @MainActor in
            try await session.run()
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let stopStarted = Date()
        session.requestStop()
        let result = try await task.value

        #expect(result.frames.count >= 1)
        #expect(Date().timeIntervalSince(stopStarted) < 1)
    }

    @Test
    @MainActor
    func `Stop request returns while an in-flight frame source ignores cancellation`() async throws {
        let image = try #require(WatchCaptureArtifactWriter.makeCGImage(from: Self.makePNG(
            size: CGSize(width: 20, height: 20))))
        let source = NoncooperativeCaptureFrameSource(image: image)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-noncooperative-stop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let options = CaptureOptions(
            duration: 30,
            idleFps: 5,
            activeFps: 5,
            changeThresholdPercent: 100,
            heartbeatSeconds: 0,
            quietMsToIdle: 0,
            maxFrames: 10,
            maxMegabytes: nil,
            highlightChanges: false,
            captureFocus: .background,
            resolutionCap: nil,
            diffStrategy: .fast,
            diffBudgetMs: nil)
        let session = WatchCaptureSession(
            dependencies: WatchCaptureDependencies(
                screenCapture: StubScreenCaptureService(
                    result: Self.makePNG(size: CGSize(width: 20, height: 20)),
                    size: CGSize(width: 20, height: 20)),
                screenService: StubScreenService(),
                frameSource: source),
            configuration: WatchCaptureConfiguration(
                scope: CaptureScope(kind: .frontmost),
                options: options,
                outputRoot: output,
                autoclean: WatchAutocleanConfig(minutes: 1, managed: false),
                sourceKind: .live,
                keepAllFrames: true))

        let task = Task { @MainActor in try await session.run() }
        await source.waitUntilBlocked()
        let releaseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            source.release()
        }
        let started = ContinuousClock.now
        session.requestStop()
        let result = try await task.value
        let elapsed = started.duration(to: .now)

        #expect(result.frames.count == 1)
        #expect(elapsed < .milliseconds(150))
        await releaseTask.value
    }

    @Test
    @MainActor
    func `Stop request cancels in-flight transient capture backoff`() async throws {
        let png = Self.makePNG(size: CGSize(width: 20, height: 20))
        let capture = StubTransientScreenCaptureService(result: png, size: CGSize(width: 20, height: 20))
        let screens = StubScreenService()
        let output = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("watch-transient-stop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }

        let options = CaptureOptions(
            duration: 30,
            idleFps: 5,
            activeFps: 5,
            changeThresholdPercent: 100,
            heartbeatSeconds: 0,
            quietMsToIdle: 0,
            maxFrames: 10,
            maxMegabytes: nil,
            highlightChanges: false,
            captureFocus: .auto,
            resolutionCap: nil,
            diffStrategy: .fast,
            diffBudgetMs: nil)
        let session = WatchCaptureSession(
            dependencies: WatchCaptureDependencies(screenCapture: capture, screenService: screens),
            configuration: WatchCaptureConfiguration(
                scope: CaptureScope(kind: .frontmost),
                options: options,
                outputRoot: output,
                autoclean: WatchAutocleanConfig(minutes: 1, managed: false)))

        let transientFailure = AsyncStream<Void>.makeStream()
        capture.onTransientFailure = {
            transientFailure.continuation.yield()
        }

        let task = Task { @MainActor in
            try await session.run()
        }

        var sawTransientFailure = false
        for await _ in transientFailure.stream {
            sawTransientFailure = true
            break
        }
        #expect(sawTransientFailure)
        #expect(capture.attemptCount >= 1)

        // Ensure requestStop() lands inside the 350ms transient backoff window.
        try await Task.sleep(nanoseconds: 15_000_000)

        let stopStarted = Date()
        session.requestStop()
        let result = try await task.value
        let stopElapsed = Date().timeIntervalSince(stopStarted)

        print("PROOF transient_stop_elapsed_ms=\(Int(stopElapsed * 1000))")

        // The fallback runner owns this retry and cancellation wins before it surfaces an error
        // to the session, so reporting a dropped transient frame here would be fabricated.
        #expect(!result.warnings.contains { $0.code == .transientCaptureFailure })
        #expect(result.frames.count == 1)
        #expect(result.warnings.contains { $0.code == .noMotion })
        // Unfixed raw Task.sleep still waits ~350ms before the loop can observe stop.
        #expect(stopElapsed < 0.08)
    }

    @Test
    @MainActor
    func `Task cancellation wakes cadence sleep`() async throws {
        let png = Self.makePNG(size: CGSize(width: 20, height: 20))
        let capture = StubScreenCaptureService(result: png, size: CGSize(width: 20, height: 20))
        let screens = StubScreenService()
        let output = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("watch-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }

        let options = CaptureOptions(
            duration: 30,
            idleFps: 0.1,
            activeFps: 1,
            changeThresholdPercent: 100,
            heartbeatSeconds: 0,
            quietMsToIdle: 0,
            maxFrames: 10,
            maxMegabytes: nil,
            highlightChanges: false,
            captureFocus: .auto,
            resolutionCap: nil,
            diffStrategy: .fast,
            diffBudgetMs: nil)
        let session = WatchCaptureSession(
            dependencies: WatchCaptureDependencies(screenCapture: capture, screenService: screens),
            configuration: WatchCaptureConfiguration(
                scope: CaptureScope(kind: .frontmost),
                options: options,
                outputRoot: output,
                autoclean: WatchAutocleanConfig(minutes: 1, managed: false)))

        let task = Task { @MainActor in
            try await session.run()
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let cancelStarted = Date()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation to propagate")
        } catch is CancellationError {
            #expect(Date().timeIntervalSince(cancelStarted) < 1)
        }
    }

    @Test
    @MainActor
    func `Frame provider prefers stable window id when present`() async throws {
        let png = Self.makePNG(size: CGSize(width: 20, height: 20))
        let capture = StubScreenCaptureService(result: png, size: CGSize(width: 20, height: 20))
        let screens = StubScreenService()
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 111,
            ownerProcessStartIdentity: 222,
            capturedBounds: bounds)
        var validationCount = 0
        let provider = WatchCaptureFrameProvider(
            screenCapture: capture,
            frameSource: nil,
            scope: CaptureScope(
                kind: .window,
                windowId: 42,
                windowMutationIdentity: identity,
                applicationIdentifier: "TextEdit",
                windowIndex: 3),
            options: Self.defaultWatchOptions(),
            regionValidator: WatchCaptureRegionValidator(screenService: screens),
            windowIdentityValidator: { candidate in
                validationCount += 1
                return candidate == identity
            })

        _ = try await provider.captureFrame()
        _ = try await provider.captureFrame()

        #expect(capture.capturedWindowID == 42)
        #expect(capture.capturedAppIdentifier == nil)
        #expect(capture.capturedWindowIndex == nil)
        #expect(validationCount == 4)
    }

    @Test
    @MainActor
    func `Frame provider rejects app window fallback without exact identity`() async throws {
        let png = Self.makePNG(size: CGSize(width: 20, height: 20))
        let capture = StubScreenCaptureService(result: png, size: CGSize(width: 20, height: 20))
        let screens = StubScreenService()
        let provider = WatchCaptureFrameProvider(
            screenCapture: capture,
            frameSource: nil,
            scope: CaptureScope(
                kind: .window,
                applicationIdentifier: "TextEdit",
                windowIndex: 3),
            options: Self.defaultWatchOptions(),
            regionValidator: WatchCaptureRegionValidator(screenService: screens))

        await #expect(throws: PeekabooError.self) {
            _ = try await provider.captureFrame()
        }

        #expect(capture.capturedWindowID == nil)
        #expect(capture.capturedAppIdentifier == nil)
        #expect(capture.capturedWindowIndex == nil)
    }

    @Test
    @MainActor
    func `Frame provider rejects identity drift after exact capture`() async throws {
        let png = Self.makePNG(size: CGSize(width: 20, height: 20))
        let capture = StubScreenCaptureService(result: png, size: CGSize(width: 20, height: 20))
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 111,
            ownerProcessStartIdentity: 222,
            capturedBounds: CGRect(x: 10, y: 20, width: 600, height: 400))
        var validations = [true, false]
        let provider = WatchCaptureFrameProvider(
            screenCapture: capture,
            frameSource: nil,
            scope: CaptureScope(
                kind: .window,
                windowId: 42,
                windowMutationIdentity: identity),
            options: Self.defaultWatchOptions(),
            regionValidator: WatchCaptureRegionValidator(screenService: StubScreenService()),
            windowIdentityValidator: { _ in validations.removeFirst() })

        await #expect(throws: PeekabooError.self) {
            _ = try await provider.captureFrame()
        }
        #expect(capture.capturedWindowID == 42)
        #expect(validations.isEmpty)
    }

    @Test
    @MainActor
    func `Frame provider caps live frames to resolution cap`() async throws {
        let sourceSize = CGSize(width: 3008, height: 1632)
        let png = Self.makePNG(size: sourceSize)
        let capture = StubScreenCaptureService(result: png, size: sourceSize)
        let screens = StubScreenService()
        let provider = WatchCaptureFrameProvider(
            screenCapture: capture,
            frameSource: nil,
            scope: CaptureScope(kind: .screen),
            options: Self.defaultWatchOptions(resolutionCap: 1440),
            regionValidator: WatchCaptureRegionValidator(screenService: screens))

        let output = try await provider.captureFrame()

        #expect(output.frame?.cgImage?.width == 1440)
        #expect(output.frame?.cgImage?.height == 781)
    }

    // MARK: - Helpers

    private static func defaultWatchOptions(
        resolutionCap: CGFloat? = nil,
        changeThresholdPercent: Double = 0) -> CaptureOptions
    {
        CaptureOptions(
            duration: 1,
            idleFps: 1,
            activeFps: 1,
            changeThresholdPercent: changeThresholdPercent,
            heartbeatSeconds: 0,
            quietMsToIdle: 0,
            maxFrames: 1,
            maxMegabytes: nil,
            highlightChanges: false,
            captureFocus: .auto,
            resolutionCap: resolutionCap,
            diffStrategy: .fast,
            diffBudgetMs: nil)
    }

    private static func makePNG(size: CGSize) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            fatalError("Failed to create context")
        }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        guard let image = ctx.makeImage() else {
            fatalError("Failed to build CGImage")
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil)
        else {
            fatalError("Failed to create image destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("Failed to finalize PNG")
        }
        return data as Data
    }
}

// MARK: - Stubs

private final class NoncooperativeVideoFrameDecoder: @unchecked Sendable, VideoFrameDecoding {
    private let lock = NSLock()
    private let image: CGImage
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var cancellationCount = 0

    init(image: CGImage) {
        self.image = image
    }

    func image(at time: CMTime) async throws -> (image: CGImage, actualTime: CMTime) {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            self.releaseContinuation = continuation
            self.lock.unlock()
        }
        return (self.image, time)
    }

    func cancelPendingDecodes() {
        self.lock.lock()
        self.cancellationCount += 1
        self.lock.unlock()
    }

    var cancelCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cancellationCount
    }

    func release() {
        self.lock.lock()
        let continuation = self.releaseContinuation
        self.releaseContinuation = nil
        self.lock.unlock()
        continuation?.resume()
    }
}

@MainActor
private final class NoncooperativeCaptureFrameSource: CaptureFrameSource {
    private let image: CGImage
    private var callCount = 0
    private var blocked = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(image: CGImage) {
        self.image = image
    }

    func nextFrame() async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        self.callCount += 1
        if self.callCount == 1 {
            return (self.image, self.metadata)
        }
        self.blocked = true
        self.blockedContinuation?.resume()
        self.blockedContinuation = nil
        await withCheckedContinuation { continuation in
            self.releaseContinuation = continuation
        }
        return (self.image, self.metadata)
    }

    func waitUntilBlocked() async {
        guard !self.blocked else { return }
        await withCheckedContinuation { continuation in
            self.blockedContinuation = continuation
        }
    }

    func release() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }

    private var metadata: CaptureMetadata {
        CaptureMetadata(
            size: CGSize(width: self.image.width, height: self.image.height),
            mode: .screen,
            timestamp: Date())
    }
}

private actor ControlledVideoFrameDecoder: VideoFrameDecoding {
    private let image: CGImage
    private var entered = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(image: CGImage) {
        self.image = image
    }

    func image(at time: CMTime) async throws -> (image: CGImage, actualTime: CMTime) {
        self.entered = true
        self.enteredContinuation?.resume()
        self.enteredContinuation = nil
        await withCheckedContinuation { continuation in
            self.releaseContinuation = continuation
        }
        return (self.image, time)
    }

    func waitUntilEntered() async {
        guard !self.entered else { return }
        await withCheckedContinuation { continuation in
            self.enteredContinuation = continuation
        }
    }

    func release() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }
}

private struct FailingVideoFrameDecoder: VideoFrameDecoding {
    let error: any Error & Sendable

    func image(at _: CMTime) async throws -> (image: CGImage, actualTime: CMTime) {
        throw self.error
    }
}

@MainActor
private final class StubTransientScreenCaptureService: ScreenCaptureServiceProtocol {
    private let success: StubScreenCaptureService
    private(set) var attemptCount = 0
    var onTransientFailure: (() -> Void)?

    private static let transientError = NSError(
        domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
        code: -3801,
        userInfo: [
            NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture",
        ])

    init(result: Data, size: CGSize) {
        self.success = StubScreenCaptureService(result: result, size: size)
    }

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw Self.transientError
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw Self.transientError
    }

    func captureWindow(
        windowID _: CGWindowID,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw Self.transientError
    }

    func captureFrontmost(
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        if self.attemptCount == 0 {
            self.attemptCount += 1
            return try await self.success.captureFrontmost(
                visualizerMode: visualizerMode,
                scale: scale)
        }
        let runner = ScreenCaptureFallbackRunner(apis: [.modern])
        return try await runner.run(
            operationName: "captureFrontmost",
            logger: MockLoggingService().logger(category: "test"),
            correlationId: "watch-stop-inner-retry")
        { _ in
            self.attemptCount += 1
            self.onTransientFailure?()
            throw Self.transientError
        }
    }

    func captureArea(
        _: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw Self.transientError
    }

    func hasScreenRecordingPermission() async -> Bool {
        true
    }
}

@MainActor
private final class StubScreenCaptureService: ScreenCaptureServiceProtocol {
    private let resultData: Data
    private let size: CGSize
    var capturedAppIdentifier: String?
    var capturedWindowIndex: Int?
    var capturedWindowID: CGWindowID?
    private(set) var capturedVisualizerModes: [CaptureVisualizerMode] = []

    init(result: Data, size: CGSize) {
        self.resultData = result
        self.size = size
    }

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.capturedVisualizerModes.append(visualizerMode)
        return self.makeResult(mode: .screen)
    }

    func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.capturedVisualizerModes.append(visualizerMode)
        self.capturedAppIdentifier = appIdentifier
        self.capturedWindowIndex = windowIndex
        return self.makeResult(mode: .window)
    }

    func captureWindow(
        windowID: CGWindowID,
        visualizerMode: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.capturedVisualizerModes.append(visualizerMode)
        self.capturedWindowID = windowID
        return self.makeResult(mode: .window)
    }

    func captureFrontmost(
        visualizerMode: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.capturedVisualizerModes.append(visualizerMode)
        return self.makeResult(mode: .frontmost)
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.capturedVisualizerModes.append(visualizerMode)
        let metadata = CaptureMetadata(
            size: rect.size,
            mode: .area,
            applicationInfo: nil,
            windowInfo: nil,
            displayInfo: DisplayInfo(index: 0, name: "Test", bounds: rect, scaleFactor: 2),
            timestamp: Date())
        return CaptureResult(imageData: self.resultData, savedPath: nil, metadata: metadata, warning: nil)
    }

    func hasScreenRecordingPermission() async -> Bool {
        true
    }

    private func makeResult(mode: CaptureMode) -> CaptureResult {
        CaptureResult(
            imageData: self.resultData,
            savedPath: nil,
            metadata: self.baseMetadata(mode: mode),
            warning: nil)
    }

    private func baseMetadata(mode: CaptureMode) -> CaptureMetadata {
        CaptureMetadata(
            size: self.size,
            mode: mode,
            applicationInfo: nil,
            windowInfo: nil,
            displayInfo: DisplayInfo(
                index: 0,
                name: "Test",
                bounds: CGRect(origin: .zero, size: self.size),
                scaleFactor: 2),
            timestamp: Date())
    }
}

@MainActor
private final class StubScreenService: ScreenServiceProtocol {
    func listScreens() -> [ScreenInfo] {
        [
            ScreenInfo(
                index: 0,
                name: "Test",
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                isPrimary: true,
                scaleFactor: 2,
                displayID: 1),
        ]
    }

    func screenContainingWindow(bounds _: CGRect) -> ScreenInfo? {
        self.listScreens().first
    }

    func screen(at index: Int) -> ScreenInfo? {
        self.listScreens().first(where: { $0.index == index })
    }

    var primaryScreen: ScreenInfo? {
        self.listScreens().first
    }
}
