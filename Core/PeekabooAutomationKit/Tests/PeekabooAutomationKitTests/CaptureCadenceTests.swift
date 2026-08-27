import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct CaptureCadenceTests {
    @Test
    func `defaults and inclusive boundaries are accepted`() throws {
        #expect(try CaptureCadence.validated(idleFps: nil, activeFps: nil) == CaptureCadence(
            idleFps: 2,
            activeFps: 8))
        #expect(try CaptureCadence.validated(idleFps: 0.1, activeFps: 0.5).idleFps == 0.1)
        #expect(try CaptureCadence.validated(idleFps: 5, activeFps: 15).activeFps == 15)
        #expect(try CaptureCadence.validated(idleFps: 5, activeFps: 5).activeFps == 5)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func `nonfinite values are rejected`(_ value: Double) {
        #expect(throws: CaptureCadenceValidationError.self) {
            _ = try CaptureCadence.validated(idleFps: value, activeFps: 8)
        }
        #expect(throws: CaptureCadenceValidationError.self) {
            _ = try CaptureCadence.validated(idleFps: 2, activeFps: value)
        }
    }

    @Test(arguments: [0.0, -1.0])
    func `nonpositive values are rejected`(_ value: Double) {
        #expect(throws: CaptureCadenceValidationError.self) {
            _ = try CaptureCadence.validated(idleFps: value, activeFps: 8)
        }
        #expect(throws: CaptureCadenceValidationError.self) {
            _ = try CaptureCadence.validated(idleFps: 2, activeFps: value)
        }
    }

    @Test
    func `out of range and inverted adaptive rates are rejected`() {
        for idle in [0.099, 5.001] {
            #expect(throws: CaptureCadenceValidationError.self) {
                _ = try CaptureCadence.validated(idleFps: idle, activeFps: 8)
            }
        }
        for active in [0.499, 15.001] {
            #expect(throws: CaptureCadenceValidationError.self) {
                _ = try CaptureCadence.validated(idleFps: 0.1, activeFps: active)
            }
        }
        #expect(throws: CaptureCadenceValidationError.self) {
            _ = try CaptureCadence.validated(idleFps: 5, activeFps: 4)
        }
    }
}

@MainActor
struct WatchCaptureCadenceSchedulingTests {
    @Test(arguments: [
        (costMs: UInt64(0), expectedSleepMs: UInt64(100)),
        (costMs: 20, expectedSleepMs: 80),
        (costMs: 80, expectedSleepMs: 20),
        (costMs: 150, expectedSleepMs: 0),
    ])
    func `monotonic scheduling compensates processing cost without extra overrun sleep`(
        costMs: UInt64,
        expectedSleepMs: UInt64) async throws
    {
        let clock = TestWatchCaptureClock()
        let session = Self.makeSession(clock: clock)
        let frameStart = clock.nowNanoseconds()
        clock.advance(nanoseconds: costMs * 1_000_000)

        try await session.sleep(ns: 100_000_000, since: frameStart)

        #expect(clock.requestedSleeps == (expectedSleepMs == 0 ? [] : [expectedSleepMs * 1_000_000]))
    }

    @Test
    func `motion transition selects active cadence for the immediately following interval`() async throws {
        let clock = TestWatchCaptureClock()
        let session = Self.makeSession(clock: clock)
        let timing = try session.makeTiming()
        var state = WatchCaptureSession.SessionState(
            lastKeptNs: timing.monotonicStartNs,
            lastActivityNs: timing.monotonicStartNs,
            activeMode: false,
            lastDiffBuffer: nil,
            lastKeptDiffBuffer: nil,
            lastKeptFrameIndex: nil,
            frameIndex: 1,
            frameAttempts: 1,
            captureAttempts: 1,
            framesSampled: 1,
            captureFailures: 0,
            framesDiffFiltered: 0,
            requestedCadenceDurationNs: 0,
            requestedCadenceIntervals: 0,
            consecutiveDecodeFailures: 0,
            consecutiveTransientCaptureFailures: 0,
            transientCaptureWarningEmitted: false)

        let cadence = session.postFrameCadenceNanoseconds(
            changePercent: 4,
            nowNs: timing.monotonicStartNs,
            state: &state,
            timing: timing)

        #expect(state.activeMode)
        #expect(cadence == 100_000_000)
        #expect(cadence < timing.cadenceIdleNs)

        let frameStart = clock.nowNanoseconds()
        clock.advance(nanoseconds: 20_000_000)
        try await session.sleep(ns: cadence, since: frameStart)
        #expect(clock.requestedSleeps == [80_000_000])
    }

    @Test
    func `cadence sleep is bounded by the session deadline`() async throws {
        let clock = TestWatchCaptureClock()
        let session = Self.makeSession(clock: clock)
        let timing = try session.makeTiming()
        clock.advance(nanoseconds: 900_000_000)

        try await session.sleep(
            ns: 2_000_000_000,
            since: clock.nowNanoseconds(),
            deadlineNs: timing.deadlineNs)

        #expect(clock.requestedSleeps == [100_000_000])
        #expect(clock.nowNanoseconds() == timing.deadlineNs)
    }

    @Test
    func `timing anchor starts after validated setup work`() throws {
        let clock = TestWatchCaptureClock()
        let session = Self.makeSession(clock: clock)
        let validated = try session.validateTiming()

        clock.advance(nanoseconds: 500_000_000)
        let timing = session.makeTiming(from: validated)

        #expect(timing.monotonicStartNs == 500_000_000)
        #expect(timing.deadlineNs - timing.monotonicStartNs == 1_000_000_000)
    }

    @Test
    func `raw invalid options fail before floating point conversion`() {
        let clock = TestWatchCaptureClock()
        let session = Self.makeSession(clock: clock, idleFps: .nan, activeFps: 10)

        #expect(throws: CaptureCadenceValidationError.self) {
            _ = try session.makeTiming()
        }
    }

    @Test
    func `invalid public session options fail before creating artifacts`() async {
        let clock = TestWatchCaptureClock()
        let outputRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-invalid-cadence-\(UUID().uuidString)", isDirectory: true)
        let session = Self.makeSession(
            clock: clock,
            idleFps: 5,
            activeFps: 4,
            outputRoot: outputRoot)

        await #expect(throws: CaptureCadenceValidationError.self) {
            _ = try await session.run()
        }
        #expect(!FileManager.default.fileExists(atPath: outputRoot.path))
    }

    private static func makeSession(
        clock: TestWatchCaptureClock,
        idleFps: Double = 1,
        activeFps: Double = 10,
        outputRoot: URL = FileManager.default.temporaryDirectory) -> WatchCaptureSession
    {
        WatchCaptureSession(
            dependencies: WatchCaptureDependencies(
                screenCapture: CadenceNoOpCaptureService(),
                clock: clock),
            configuration: WatchCaptureConfiguration(
                scope: CaptureScope(kind: .frontmost),
                options: CaptureOptions(
                    duration: 1,
                    idleFps: idleFps,
                    activeFps: activeFps,
                    changeThresholdPercent: 2,
                    heartbeatSeconds: 0,
                    quietMsToIdle: 1000,
                    maxFrames: 10,
                    maxMegabytes: nil,
                    highlightChanges: false,
                    captureFocus: .background,
                    resolutionCap: nil,
                    diffStrategy: .fast,
                    diffBudgetMs: nil),
                outputRoot: outputRoot,
                autoclean: WatchAutocleanConfig(minutes: 1, managed: false)))
    }
}

struct CaptureSamplingMetricsTests {
    @Test
    func `stats separate sampled retained and loss semantics with compatibility aliases`() {
        let result = Self.makeResult(
            sampling: .init(
                durationNs: 1_000_000_000,
                captureAttempts: 12,
                framesSampled: 10,
                captureFailures: 2,
                framesDiffFiltered: 6,
                requestedCadenceDurationNs: 1_000_000_000,
                requestedCadenceIntervals: 10),
            framesKept: 4)

        #expect(result.stats.totalDurationMs == 1300)
        #expect(result.stats.samplingDurationMs == 1000)
        #expect(result.stats.captureAttempts == 12)
        #expect(result.stats.framesSampled == 10)
        #expect(result.stats.captureFailures == 2)
        #expect(result.stats.framesDiffFiltered == 6)
        #expect(result.stats.sampledFps == 10)
        #expect(result.stats.keptFps == 4)
        #expect(!result.stats.lowFps)
        #expect(result.stats.durationMs == result.stats.totalDurationMs)
        #expect(result.stats.fpsEffective == result.stats.keptFps)
        #expect(result.stats.framesDropped == 8)
    }

    @Test
    func `low FPS is based on sampled cadence rather than retained frames`() {
        let diffHeavy = Self.makeResult(
            sampling: .init(
                durationNs: 1_000_000_000,
                captureAttempts: 10,
                framesSampled: 10,
                captureFailures: 0,
                framesDiffFiltered: 9,
                requestedCadenceDurationNs: 1_000_000_000,
                requestedCadenceIntervals: 10),
            framesKept: 1)
        #expect(!diffHeavy.stats.lowFps)

        let undersampled = Self.makeResult(
            sampling: .init(
                durationNs: 1_500_000_000,
                captureAttempts: 10,
                framesSampled: 10,
                captureFailures: 0,
                framesDiffFiltered: 0,
                requestedCadenceDurationNs: 1_000_000_000,
                requestedCadenceIntervals: 10),
            framesKept: 10)
        #expect(undersampled.stats.lowFps)
        #expect(undersampled.warnings.contains { $0.code == .lowFps })
    }

    private static func makeResult(
        sampling: WatchCaptureSession.SamplingMetrics,
        framesKept: Int) -> CaptureSessionResult
    {
        let frames = (0..<framesKept).map { index in
            CaptureFrameInfo(
                index: index,
                path: "/tmp/frame-\(index).png",
                file: "frame-\(index).png",
                timestampMs: index * 100,
                changePercent: 0,
                reason: index == 0 ? .first : .motion)
        }
        return WatchCaptureResultBuilder(
            sourceKind: .live,
            videoIn: nil,
            videoOut: nil,
            videoArtifactCustody: nil,
            scope: CaptureScope(kind: .frontmost),
            options: CaptureOptions(
                duration: 1,
                idleFps: 2,
                activeFps: 10,
                changeThresholdPercent: 2,
                heartbeatSeconds: 5,
                quietMsToIdle: 1000,
                maxFrames: 100,
                maxMegabytes: nil,
                highlightChanges: false,
                captureFocus: .background,
                resolutionCap: nil,
                diffStrategy: .fast,
                diffBudgetMs: nil),
            videoOptions: nil,
            diffScale: "w256")
            .build(.init(
                frames: frames,
                contactSheet: CaptureContactSheet(
                    path: "/tmp/contact.png",
                    file: "contact.png",
                    columns: 1,
                    rows: 1,
                    thumbSize: CGSize(width: 100, height: 100),
                    sampledFrameIndexes: []),
                metadataURL: URL(fileURLWithPath: "/tmp/metadata.json"),
                totalDurationMs: 1300,
                sampling: sampling,
                returnedFrameAttempts: sampling.framesSampled,
                totalBytes: 1,
                warnings: [],
                sourceDiagnostics: CaptureFrameSourceDiagnostics()))
    }
}

private final class TestWatchCaptureClock: WatchCaptureMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 0
    private var sleeps: [UInt64] = []

    var requestedSleeps: [UInt64] {
        self.lock.withLock { self.sleeps }
    }

    func nowNanoseconds() -> UInt64 {
        self.lock.withLock { self.now }
    }

    func advance(nanoseconds: UInt64) {
        self.lock.withLock {
            self.now += nanoseconds
        }
    }

    func sleep(nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        self.lock.withLock {
            self.sleeps.append(nanoseconds)
            self.now += nanoseconds
        }
    }
}

private struct CadenceNoOpCaptureService: ScreenCaptureServiceProtocol {
    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw CancellationError()
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw CancellationError()
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw CancellationError()
    }

    func captureArea(
        _: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw CancellationError()
    }

    func hasScreenRecordingPermission() async -> Bool {
        true
    }
}
