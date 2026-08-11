import CoreGraphics
import Foundation

@MainActor
extension WatchCaptureSession {
    struct SessionTiming {
        let start: Date
        let durationNs: UInt64
        let heartbeatNs: UInt64
        let cadenceIdleNs: UInt64
        let cadenceActiveNs: UInt64
    }

    struct SessionState {
        var lastKeptTime: Date
        var lastActivityTime: Date
        var activeMode: Bool
        var lastDiffBuffer: WatchFrameDiffer.LumaBuffer?
        var lastKeptDiffBuffer: WatchFrameDiffer.LumaBuffer?
        var lastKeptFrameIndex: Int?
        var frameIndex: Int
        var frameAttempts: Int
        var consecutiveDecodeFailures: Int
        var consecutiveTransientCaptureFailures: Int
        var transientCaptureWarningEmitted: Bool
    }

    struct DiffComputation {
        let changePercent: Double
        let motionBoxes: [CGRect]?
        let buffer: WatchFrameDiffer.LumaBuffer
        let enterActive: Bool
    }

    enum CaptureAttemptResult: @unchecked Sendable {
        case frame(WatchCaptureFrame?, warning: WatchWarning?)
        case stopRequested
    }

    func makeTiming(start: Date) -> SessionTiming {
        let durationNs = UInt64(self.options.duration * 1_000_000_000)
        let heartbeatNs = self.options.heartbeatSeconds > 0
            ? UInt64(self.options.heartbeatSeconds * 1_000_000_000)
            : UInt64.max

        let cadenceIdleNs = UInt64(1_000_000_000 / max(self.options.idleFps, 0.1))
        let cadenceActiveNs = UInt64(1_000_000_000 / max(self.options.activeFps, 0.1))

        return SessionTiming(
            start: start,
            durationNs: durationNs,
            heartbeatNs: heartbeatNs,
            cadenceIdleNs: cadenceIdleNs,
            cadenceActiveNs: cadenceActiveNs)
    }

    func captureFrames(timing: SessionTiming) async throws {
        var state = SessionState(
            lastKeptTime: timing.start,
            lastActivityTime: timing.start,
            activeMode: false,
            lastDiffBuffer: nil,
            lastKeptDiffBuffer: nil,
            lastKeptFrameIndex: nil,
            frameIndex: 0,
            frameAttempts: 0,
            consecutiveDecodeFailures: 0,
            consecutiveTransientCaptureFailures: 0,
            transientCaptureWarningEmitted: false)

        captureLoop: while true {
            let now = Date()
            let elapsedNs = Self.elapsedNanoseconds(since: timing.start, now: now)
            if self.shouldEndSession(elapsedNs: elapsedNs, durationNs: timing.durationNs) {
                break
            }
            if self.hitFrameCap(videoFrameAttempts: state.frameAttempts) || self.hitSizeCap() {
                break
            }

            let frameStart = Date()
            let cadence = state.activeMode ? timing.cadenceActiveNs : timing.cadenceIdleNs
            let attemptResult: CaptureAttemptResult
            do {
                attemptResult = try await self.captureFrameOrStop()
            } catch {
                if let delay = ScreenCaptureKitTransientError.retryDelayNanoseconds(after: error) {
                    state.consecutiveTransientCaptureFailures += 1
                    guard state.consecutiveTransientCaptureFailures <= 3 else {
                        throw error
                    }
                    let boundedError = CaptureDiagnosticSanitizer.sanitize(error.localizedDescription) ??
                        "Transient ScreenCaptureKit capture failure"
                    self.lastCaptureErrorDescription = boundedError
                    self.framesDropped += 1
                    if !state.transientCaptureWarningEmitted {
                        state.transientCaptureWarningEmitted = true
                        self.warnings.append(
                            WatchWarning(
                                code: .transientCaptureFailure,
                                message: "Dropped a frame after a transient ScreenCaptureKit capture failure",
                                details: ["error": boundedError]))
                    }
                    // SCK can report a temporary TCC denial while another CLI capture is settling.
                    // Treat that as a dropped live frame; the next sample or fallback frame can recover.
                    let retryStart = Date()
                    try await self.sleep(ns: delay, since: retryStart)
                    continue
                }
                throw error
            }
            state.consecutiveTransientCaptureFailures = 0

            let capture: WatchCaptureFrame?
            switch attemptResult {
            case let .frame(frame, warning):
                if let warning {
                    self.warnings.append(warning)
                }
                capture = frame
            case .stopRequested:
                break captureLoop
            }

            guard let capture else {
                // Frame source exhausted, usually from finite video input.
                break
            }
            state.frameAttempts += 1
            self.frameAttempts = state.frameAttempts
            let timestampMs = capture.metadata.videoTimestampMs ?? Int(elapsedNs / 1_000_000)

            guard let cgImage = capture.cgImage else {
                self.framesDropped += 1
                state.consecutiveDecodeFailures += 1
                if self.sourceKind == .video, state.consecutiveDecodeFailures >= 32 {
                    let diagnostics = self.captureSourceDiagnostics
                    var details = ["count": "\(diagnostics.decodeFailures)"]
                    if let first = diagnostics.firstDecodeError {
                        details["first_error"] = first
                    }
                    if let last = diagnostics.lastDecodeError {
                        details["last_error"] = last
                    }
                    self.warnings.append(WatchWarning(
                        code: .videoDecodeFailure,
                        message: "Stopped video sampling after 32 consecutive undecodable samples",
                        details: details))
                    break
                }
                try await self.sleep(ns: cadence, since: frameStart)
                continue
            }
            state.consecutiveDecodeFailures = 0

            if self.keepAllFrames {
                try await self.keepAllFrame(
                    cgImage: cgImage,
                    capture: capture,
                    timestampMs: timestampMs,
                    state: &state)
                try await self.sleep(ns: cadence, since: frameStart)
                continue
            }

            let diff = self.computeDiff(cgImage: cgImage, previous: state.lastDiffBuffer)
            state.lastDiffBuffer = diff.buffer
            self.updateActiveMode(
                changePercent: diff.changePercent,
                now: now,
                state: &state)

            let decision = self.keepDecision(
                now: now,
                state: state,
                heartbeatNs: timing.heartbeatNs,
                enterActive: diff.enterActive)

            if decision.keep {
                let outputDiff = self.diffForOutputFrame(
                    sampledDiff: diff,
                    previousKept: state.lastKeptDiffBuffer,
                    previousKeptFrameIndex: state.lastKeptFrameIndex,
                    currentFrameIndex: state.frameIndex,
                    originalSize: CGSize(width: cgImage.width, height: cgImage.height))
                let saveContext = FrameSaveContext(
                    capture: capture,
                    index: state.frameIndex,
                    timestampMs: timestampMs,
                    changePercent: outputDiff.changePercent,
                    reason: decision.reason,
                    motionBoxes: outputDiff.motionBoxes)
                let saved = try await self.saveFrame(cgImage: cgImage, context: saveContext)
                self.frames.append(saved)
                state.lastKeptTime = now
                state.lastKeptDiffBuffer = diff.buffer
                state.lastKeptFrameIndex = state.frameIndex
            } else {
                self.framesDropped += 1
            }

            state.frameIndex += 1
            try await self.sleep(ns: cadence, since: frameStart)
        }
    }

    func keepAllFrame(
        cgImage: CGImage,
        capture: WatchCaptureFrame,
        timestampMs: Int,
        state: inout SessionState) async throws
    {
        let reason: CaptureFrameInfo.Reason = self.frames.isEmpty ? .first : .motion
        let saved = try await self.saveFrame(
            cgImage: cgImage,
            context: FrameSaveContext(
                capture: capture,
                index: state.frameIndex,
                timestampMs: timestampMs,
                changePercent: 0,
                reason: reason,
                motionBoxes: nil))
        self.frames.append(saved)
        state.frameIndex += 1
    }

    func captureFrameOrStop() async throws -> CaptureAttemptResult {
        guard !self.hasStopRequest() else { return .stopRequested }
        let provider = self.frameProvider
        let captureTask = Task<CaptureAttemptResult, any Error> { @MainActor in
            let output = try await provider.captureFrame()
            return .frame(output.frame, warning: output.warning)
        }
        let stopTask = Task<CaptureAttemptResult, any Error> { [weak self] in
            await self?.waitForStopRequest()
            try Task.checkCancellation()
            return .stopRequested
        }
        defer {
            captureTask.cancel()
            stopTask.cancel()
        }
        return try await withTaskCancellationHandler {
            let result: CaptureAttemptResult = try await withCheckedThrowingContinuation { continuation in
                let gate = WatchCaptureAttemptContinuation(continuation: continuation)
                Task {
                    await gate.resume(with: captureTask.result)
                }
                Task {
                    await gate.resume(with: stopTask.result)
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            captureTask.cancel()
            stopTask.cancel()
        }
    }

    static func elapsedNanoseconds(since start: Date, now: Date) -> UInt64 {
        UInt64(now.timeIntervalSince(start) * 1_000_000_000)
    }

    func shouldEndSession(elapsedNs: UInt64, durationNs: UInt64) -> Bool {
        self.hasStopRequest() || elapsedNs >= durationNs
    }

    func hitFrameCap(videoFrameAttempts: Int = 0) -> Bool {
        let count = self.sourceKind == .video ? videoFrameAttempts : self.frames.count
        guard count >= self.options.maxFrames else { return false }
        let message = self.sourceKind == .video
            ? "Stopped after reaching max-frames video sampling cap"
            : "Stopped after reaching max-frames cap"
        self.warnings.append(
            WatchWarning(code: .frameCap, message: message))
        return true
    }

    func hitSizeCap() -> Bool {
        guard let maxMb = self.options.maxMegabytes else { return false }
        let currentMb = self.totalBytes / (1024 * 1024)
        guard currentMb >= maxMb else { return false }
        self.warnings.append(
            WatchWarning(code: .sizeCap, message: "Stopped after reaching max-mb cap"))
        return true
    }

    func computeDiff(
        cgImage: CGImage,
        previous: WatchFrameDiffer.LumaBuffer?) -> DiffComputation
    {
        let downscaled = WatchFrameDiffer.makeLumaBuffer(from: cgImage, maxWidth: Constants.diffScaleWidth)
        return self.computeDiff(
            current: downscaled,
            previous: previous,
            originalSize: CGSize(width: cgImage.width, height: cgImage.height),
            recordDowngradeWarning: true)
    }

    func diffForOutputFrame(
        sampledDiff: DiffComputation,
        previousKept: WatchFrameDiffer.LumaBuffer?,
        previousKeptFrameIndex: Int?,
        currentFrameIndex: Int,
        originalSize: CGSize) -> DiffComputation
    {
        guard let previousKept,
              previousKeptFrameIndex != currentFrameIndex - 1
        else {
            return sampledDiff
        }

        return self.computeDiff(
            current: sampledDiff.buffer,
            previous: previousKept,
            originalSize: originalSize,
            recordDowngradeWarning: false)
    }

    private func computeDiff(
        current: WatchFrameDiffer.LumaBuffer,
        previous: WatchFrameDiffer.LumaBuffer?,
        originalSize: CGSize,
        recordDowngradeWarning: Bool) -> DiffComputation
    {
        let diff = WatchFrameDiffer.computeChange(
            using: WatchFrameDiffer.DiffInput(
                strategy: self.options.diffStrategy,
                diffBudgetMs: self.options.diffBudgetMs,
                previous: previous,
                current: current,
                deltaThreshold: Constants.motionDelta,
                originalSize: originalSize))

        if diff.downgraded, recordDowngradeWarning {
            self.warnings.append(
                WatchWarning(code: .diffDowngraded, message: "Diff downgraded to fast due to budget"))
        }

        return DiffComputation(
            changePercent: diff.changePercent,
            motionBoxes: diff.boundingBoxes,
            buffer: current,
            enterActive: diff.changePercent >= self.options.changeThresholdPercent)
    }

    func updateActiveMode(
        changePercent: Double,
        now: Date,
        state: inout SessionState)
    {
        let threshold = self.options.changeThresholdPercent
        let enterActive = changePercent >= threshold
        let exitActive = state.activeMode && WatchCaptureActivityPolicy.shouldExitActive(
            changePercent: changePercent,
            threshold: threshold,
            lastActivityTime: state.lastActivityTime,
            quietMs: self.options.quietMsToIdle,
            now: now)

        if enterActive {
            state.lastActivityTime = now
        }

        if enterActive, !state.activeMode {
            state.activeMode = true
            return
        }

        if exitActive {
            state.activeMode = false
        }
    }

    func keepDecision(
        now: Date,
        state: SessionState,
        heartbeatNs: UInt64,
        enterActive: Bool) -> (keep: Bool, reason: CaptureFrameInfo.Reason)
    {
        if state.frameIndex == 0 {
            return (true, .first)
        }

        if enterActive {
            return (true, .motion)
        }

        let isHeartbeat = UInt64(now.timeIntervalSince(state.lastKeptTime) * 1_000_000_000) >= heartbeatNs
        if isHeartbeat {
            return (true, .heartbeat)
        }

        return (false, .cap)
    }

    func sleep(ns: UInt64, since start: Date) async throws {
        // Video input already has intrinsic cadence; do not add wall-clock throttling.
        if self.frameSource != nil {
            return
        }
        if self.hasStopRequest() {
            return
        }
        let elapsed = UInt64(Date().timeIntervalSince(start) * 1_000_000_000)
        guard ns > elapsed else { return }

        try Task.checkCancellation()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: ns - elapsed)
            }
            group.addTask { [weak self] in
                await self?.waitForStopRequest()
            }

            _ = try await group.next()
            group.cancelAll()
            try Task.checkCancellation()
        }
    }
}

private final class WatchCaptureAttemptContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WatchCaptureSession.CaptureAttemptResult, any Error>?

    init(continuation: CheckedContinuation<WatchCaptureSession.CaptureAttemptResult, any Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<WatchCaptureSession.CaptureAttemptResult, any Error>) {
        self.lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(with: result)
    }
}
