@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAutomationKit

struct WatchCaptureSessionTests {
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
    func `Stops at max-frames cap and keeps first frame`() async throws {
        let png = Self.makePNG(size: CGSize(width: 20, height: 20))
        let capture = StubScreenCaptureService(result: png, size: CGSize(width: 20, height: 20))
        let screens = StubScreenService()
        let scope = WatchScope(
            kind: .frontmost,
            screenIndex: nil,
            displayUUID: nil,
            windowId: nil,
            applicationIdentifier: nil,
            windowIndex: nil,
            region: nil)

        let options = WatchCaptureOptions(
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
    func `Stops at size cap and emits warning`() async throws {
        let png = Self.makePNG(size: CGSize(width: 50, height: 50))
        let capture = StubScreenCaptureService(result: png, size: CGSize(width: 50, height: 50))
        let screens = StubScreenService()
        let scope = WatchScope(
            kind: .frontmost,
            screenIndex: nil,
            displayUUID: nil,
            windowId: nil,
            applicationIdentifier: nil,
            windowIndex: nil,
            region: nil)

        let options = WatchCaptureOptions(
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

        let result = try await session.run()
        #expect(result.warnings.contains { $0.code == .sizeCap })
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

        let options = WatchCaptureOptions(
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
                scope: WatchScope(kind: .frontmost),
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
    func `Stop request wakes transient capture backoff`() async throws {
        let png = Self.makePNG(size: CGSize(width: 20, height: 20))
        let capture = StubTransientScreenCaptureService(result: png, size: CGSize(width: 20, height: 20))
        let screens = StubScreenService()
        let output = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("watch-transient-stop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }

        let options = WatchCaptureOptions(
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
                scope: WatchScope(kind: .frontmost),
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

        #expect(result.warnings.contains { $0.code == .transientCaptureFailure })
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

        let options = WatchCaptureOptions(
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
                scope: WatchScope(kind: .frontmost),
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
        let provider = WatchCaptureFrameProvider(
            screenCapture: capture,
            frameSource: nil,
            scope: WatchScope(
                kind: .window,
                windowId: 42,
                applicationIdentifier: "TextEdit",
                windowIndex: 3),
            options: Self.defaultWatchOptions(),
            regionValidator: WatchCaptureRegionValidator(screenService: screens))

        _ = try await provider.captureFrame()

        #expect(capture.capturedWindowID == 42)
        #expect(capture.capturedAppIdentifier == nil)
        #expect(capture.capturedWindowIndex == nil)
    }

    @Test
    @MainActor
    func `Frame provider falls back to app window index without stable id`() async throws {
        let png = Self.makePNG(size: CGSize(width: 20, height: 20))
        let capture = StubScreenCaptureService(result: png, size: CGSize(width: 20, height: 20))
        let screens = StubScreenService()
        let provider = WatchCaptureFrameProvider(
            screenCapture: capture,
            frameSource: nil,
            scope: WatchScope(
                kind: .window,
                applicationIdentifier: "TextEdit",
                windowIndex: 3),
            options: Self.defaultWatchOptions(),
            regionValidator: WatchCaptureRegionValidator(screenService: screens))

        _ = try await provider.captureFrame()

        #expect(capture.capturedWindowID == nil)
        #expect(capture.capturedAppIdentifier == "TextEdit")
        #expect(capture.capturedWindowIndex == 3)
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
            scope: WatchScope(kind: .screen),
            options: Self.defaultWatchOptions(resolutionCap: 1440),
            regionValidator: WatchCaptureRegionValidator(screenService: screens))

        let output = try await provider.captureFrame()

        #expect(output.frame?.cgImage?.width == 1440)
        #expect(output.frame?.cgImage?.height == 781)
    }

    // MARK: - Helpers

    private static func defaultWatchOptions(resolutionCap: CGFloat? = nil) -> WatchCaptureOptions {
        WatchCaptureOptions(
            duration: 1,
            idleFps: 1,
            activeFps: 1,
            changeThresholdPercent: 0,
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
        self.attemptCount += 1
        if self.attemptCount == 1 {
            return try await self.success.captureFrontmost(
                visualizerMode: visualizerMode,
                scale: scale)
        }
        self.onTransientFailure?()
        throw Self.transientError
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

    init(result: Data, size: CGSize) {
        self.resultData = result
        self.size = size
    }

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.makeResult(mode: .screen)
    }

    func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.capturedAppIdentifier = appIdentifier
        self.capturedWindowIndex = windowIndex
        return self.makeResult(mode: .window)
    }

    func captureWindow(
        windowID: CGWindowID,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.capturedWindowID = windowID
        return self.makeResult(mode: .window)
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.makeResult(mode: .frontmost)
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
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
