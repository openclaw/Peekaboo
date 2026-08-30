import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
extension WatchCaptureSession {
    struct SessionTiming {
        let monotonicStartNs: UInt64
        let deadlineNs: UInt64
        let durationNs: UInt64
        let heartbeatNs: UInt64
        let cadenceIdleNs: UInt64
        let cadenceActiveNs: UInt64
    }

    struct ValidatedTiming {
        let durationNs: UInt64
        let heartbeatNs: UInt64
        let cadenceIdleNs: UInt64
        let cadenceActiveNs: UInt64
    }

    struct SamplingMetrics {
        let durationNs: UInt64
        let captureAttempts: Int
        let framesSampled: Int
        let captureFailures: Int
        let framesDiffFiltered: Int
        let requestedCadenceDurationNs: UInt64
        let requestedCadenceIntervals: Int
    }

    struct SessionState {
        var lastKeptNs: UInt64
        var lastActivityNs: UInt64
        var activeMode: Bool
        var lastDiffBuffer: WatchFrameDiffer.LumaBuffer?
        var lastKeptDiffBuffer: WatchFrameDiffer.LumaBuffer?
        var lastKeptFrameIndex: Int?
        var frameIndex: Int
        var frameAttempts: Int
        var captureAttempts: Int
        var framesSampled: Int
        var captureFailures: Int
        var framesDiffFiltered: Int
        var requestedCadenceDurationNs: UInt64
        var requestedCadenceIntervals: Int
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

    struct CaptureAttemptCompletion: @unchecked Sendable {
        let result: Result<CaptureAttemptResult, any Error>
        let finishedAtNs: UInt64
    }

    enum CaptureAttemptRaceResult: @unchecked Sendable {
        case capture(CaptureAttemptCompletion)
        case stop(Result<CaptureAttemptResult, any Error>)
        case deadline(Result<CaptureAttemptResult, any Error>)
    }

    func validateTiming() throws -> ValidatedTiming {
        let idleFps: Double
        let activeFps: Double
        if self.sourceKind == .live {
            let cadence = try CaptureCadence.validated(
                idleFps: self.options.idleFps,
                activeFps: self.options.activeFps)
            idleFps = cadence.idleFps
            activeFps = cadence.activeFps
        } else {
            // Video sources carry their own sampling cadence and never wall-clock throttle.
            idleFps = self.options.idleFps
            activeFps = self.options.activeFps
        }
        let durationNs = try Self.nanoseconds(
            seconds: self.options.duration,
            name: "Capture duration",
            allowZero: false)
        let heartbeatNs = self.options.heartbeatSeconds > 0
            ? try Self.nanoseconds(
                seconds: self.options.heartbeatSeconds,
                name: "Heartbeat interval",
                allowZero: false)
            : UInt64.max

        let cadenceIdleNs = try Self.cadenceNanoseconds(fps: idleFps)
        let cadenceActiveNs = try Self.cadenceNanoseconds(fps: activeFps)

        return ValidatedTiming(
            durationNs: durationNs,
            heartbeatNs: heartbeatNs,
            cadenceIdleNs: cadenceIdleNs,
            cadenceActiveNs: cadenceActiveNs)
    }

    func makeTiming(from validated: ValidatedTiming) -> SessionTiming {
        let monotonicStartNs = self.clock.nowNanoseconds()
        let (deadlineNs, deadlineOverflow) = monotonicStartNs.addingReportingOverflow(validated.durationNs)
        return SessionTiming(
            monotonicStartNs: monotonicStartNs,
            deadlineNs: deadlineOverflow ? UInt64.max : deadlineNs,
            durationNs: validated.durationNs,
            heartbeatNs: validated.heartbeatNs,
            cadenceIdleNs: validated.cadenceIdleNs,
            cadenceActiveNs: validated.cadenceActiveNs)
    }

    func makeTiming() throws -> SessionTiming {
        try self.makeTiming(from: self.validateTiming())
    }

    func captureFrames(timing: SessionTiming) async throws -> SamplingMetrics {
        var state = SessionState(
            lastKeptNs: timing.monotonicStartNs,
            lastActivityNs: timing.monotonicStartNs,
            activeMode: false,
            lastDiffBuffer: nil,
            lastKeptDiffBuffer: nil,
            lastKeptFrameIndex: nil,
            frameIndex: 0,
            frameAttempts: 0,
            captureAttempts: 0,
            framesSampled: 0,
            captureFailures: 0,
            framesDiffFiltered: 0,
            requestedCadenceDurationNs: 0,
            requestedCadenceIntervals: 0,
            consecutiveDecodeFailures: 0,
            consecutiveTransientCaptureFailures: 0,
            transientCaptureWarningEmitted: false)

        captureLoop: while true {
            let elapsedNs = Self.elapsedNanoseconds(
                since: timing.monotonicStartNs,
                now: self.clock.nowNanoseconds())
            if self.shouldEndSession(elapsedNs: elapsedNs, durationNs: timing.durationNs) {
                break
            }
            if self.hitFrameCap(videoFrameAttempts: state.frameAttempts) || self.hitSizeCap() {
                break
            }

            let frameStartNs = self.clock.nowNanoseconds()
            let attemptResult: CaptureAttemptResult
            state.captureAttempts += 1
            do {
                attemptResult = try await self.captureFrameOrStop(deadlineNs: timing.deadlineNs)
            } catch {
                if let delay = ScreenCaptureKitTransientError.retryDelayNanoseconds(after: error) {
                    try self.recordTransientCaptureFailure(error, state: &state)
                    // SCK can report a temporary TCC denial while another CLI capture is settling.
                    // Treat that as a dropped live frame; the next sample or fallback frame can recover.
                    self.recordRequestedCadence(
                        self.cadenceNanoseconds(for: state, timing: timing),
                        state: &state)
                    let retryStartNs = self.clock.nowNanoseconds()
                    try await self.sleep(ns: delay, since: retryStartNs, deadlineNs: timing.deadlineNs)
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
                if self.recordDecodeFailure(state: &state) {
                    break
                }
                if self.hitFrameCap(videoFrameAttempts: state.frameAttempts) || self.hitSizeCap() {
                    break
                }
                let cadence = self.cadenceNanoseconds(for: state, timing: timing)
                self.recordRequestedCadence(cadence, state: &state)
                try await self.sleep(ns: cadence, since: frameStartNs, deadlineNs: timing.deadlineNs)
                continue
            }
            state.consecutiveDecodeFailures = 0
            state.framesSampled += 1

            if self.keepAllFrames {
                try await self.keepAllFrame(
                    cgImage: cgImage,
                    capture: capture,
                    timestampMs: timestampMs,
                    state: &state)
                if self.hitFrameCap(videoFrameAttempts: state.frameAttempts) || self.hitSizeCap() {
                    break
                }
                let cadence = self.cadenceNanoseconds(for: state, timing: timing)
                self.recordRequestedCadence(cadence, state: &state)
                try await self.sleep(ns: cadence, since: frameStartNs, deadlineNs: timing.deadlineNs)
                continue
            }

            let diff = self.computeDiff(cgImage: cgImage, previous: state.lastDiffBuffer)
            state.lastDiffBuffer = diff.buffer
            let frameCompletedNs = self.clock.nowNanoseconds()
            let cadence = self.postFrameCadenceNanoseconds(
                changePercent: diff.changePercent,
                nowNs: frameCompletedNs,
                state: &state,
                timing: timing)

            let decision = self.keepDecision(
                nowNs: frameCompletedNs,
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
                state.lastKeptNs = frameCompletedNs
                state.lastKeptDiffBuffer = diff.buffer
                state.lastKeptFrameIndex = state.frameIndex
            } else {
                self.framesDropped += 1
                state.framesDiffFiltered += 1
            }

            state.frameIndex += 1
            if self.hitFrameCap(videoFrameAttempts: state.frameAttempts) || self.hitSizeCap() {
                break
            }
            self.recordRequestedCadence(cadence, state: &state)
            try await self.sleep(ns: cadence, since: frameStartNs, deadlineNs: timing.deadlineNs)
        }

        return SamplingMetrics(
            durationNs: Self.elapsedNanoseconds(
                since: timing.monotonicStartNs,
                now: self.clock.nowNanoseconds()),
            captureAttempts: state.captureAttempts,
            framesSampled: state.framesSampled,
            captureFailures: state.captureFailures,
            framesDiffFiltered: state.framesDiffFiltered,
            requestedCadenceDurationNs: state.requestedCadenceDurationNs,
            requestedCadenceIntervals: state.requestedCadenceIntervals)
    }

    private func recordTransientCaptureFailure(
        _ error: any Error,
        state: inout SessionState) throws
    {
        state.captureFailures += 1
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
    }

    private func recordDecodeFailure(state: inout SessionState) -> Bool {
        self.framesDropped += 1
        if self.sourceKind != .video {
            state.captureFailures += 1
        }
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
            return true
        }
        return false
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

    func captureFrameOrStop(deadlineNs: UInt64) async throws -> CaptureAttemptResult {
        guard !self.hasStopRequest() else { return .stopRequested }
        let now = self.clock.nowNanoseconds()
        guard deadlineNs > now else { return .stopRequested }
        try self.requireNoRetiringCaptureTask()
        let provider = self.frameProvider
        let clock = self.clock
        let gate = WatchCaptureAttemptContinuation()
        let captureTask = Task<CaptureAttemptCompletion, Never> { @MainActor in
            let result: Result<CaptureAttemptResult, any Error>
            do {
                let output = try await provider.captureFrame()
                result = .success(.frame(output.frame, warning: output.warning))
            } catch {
                result = .failure(error)
            }
            let completion = CaptureAttemptCompletion(result: result, finishedAtNs: clock.nowNanoseconds())
            gate.resume(with: .capture(completion))
            return completion
        }
        var captureResultReturned = false
        let stopTask = Task<CaptureAttemptResult, any Error> { [weak self] in
            let result: Result<CaptureAttemptResult, any Error>
            do {
                await self?.waitForStopRequest()
                try Task.checkCancellation()
                result = .success(.stopRequested)
            } catch {
                result = .failure(error)
            }
            gate.resume(with: .stop(result))
            return try result.get()
        }
        let deadlineTask = Task<CaptureAttemptResult, any Error> {
            let result: Result<CaptureAttemptResult, any Error>
            do {
                try await clock.sleep(nanoseconds: deadlineNs - now)
                try Task.checkCancellation()
                result = .success(.stopRequested)
            } catch {
                result = .failure(error)
            }
            gate.resume(with: .deadline(result))
            return try result.get()
        }
        defer {
            captureTask.cancel()
            stopTask.cancel()
            deadlineTask.cancel()
            if !captureResultReturned {
                self.retireCaptureTask(captureTask)
            }
        }
        return try await withTaskCancellationHandler {
            let race = await gate.wait()
            try Task.checkCancellation()
            switch race {
            case let .capture(completion):
                captureResultReturned = true
                guard completion.finishedAtNs < deadlineNs else { return .stopRequested }
                return try completion.result.get()
            case let .stop(result), let .deadline(result):
                _ = try result.get()
                return .stopRequested
            }
        } onCancel: {
            captureTask.cancel()
            stopTask.cancel()
            deadlineTask.cancel()
        }
    }

    static func elapsedNanoseconds(since start: UInt64, now: UInt64) -> UInt64 {
        now >= start ? now - start : 0
    }

    static func nanoseconds(
        seconds: Double,
        name: String,
        allowZero: Bool) throws -> UInt64
    {
        guard seconds.isFinite else {
            throw PeekabooError.invalidInput("\(name) must be finite")
        }
        guard seconds > 0 || (allowZero && seconds == 0) else {
            throw PeekabooError.invalidInput("\(name) must be greater than zero")
        }
        let scaled = seconds * 1_000_000_000
        guard scaled.isFinite, scaled >= 0, scaled < Double(UInt64.max) else {
            throw PeekabooError.invalidInput("\(name) is too large")
        }
        return UInt64(scaled)
    }

    static func cadenceNanoseconds(fps: Double) throws -> UInt64 {
        let cadence = 1_000_000_000 / fps
        guard cadence.isFinite, cadence > 0, cadence < Double(UInt64.max) else {
            throw PeekabooError.invalidInput("Capture FPS cannot be represented as a sampling interval")
        }
        return UInt64(cadence)
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
        nowNs: UInt64,
        state: inout SessionState)
    {
        let threshold = self.options.changeThresholdPercent
        let enterActive = changePercent >= threshold
        let exitActive = state.activeMode && WatchCaptureActivityPolicy.shouldExitActive(
            changePercent: changePercent,
            threshold: threshold,
            lastActivityNs: state.lastActivityNs,
            quietMs: self.options.quietMsToIdle,
            nowNs: nowNs)

        if enterActive {
            state.lastActivityNs = nowNs
        }

        if enterActive, !state.activeMode {
            state.activeMode = true
            return
        }

        if exitActive {
            state.activeMode = false
        }
    }

    func postFrameCadenceNanoseconds(
        changePercent: Double,
        nowNs: UInt64,
        state: inout SessionState,
        timing: SessionTiming) -> UInt64
    {
        self.updateActiveMode(changePercent: changePercent, nowNs: nowNs, state: &state)
        return self.cadenceNanoseconds(for: state, timing: timing)
    }

    func cadenceNanoseconds(for state: SessionState, timing: SessionTiming) -> UInt64 {
        state.activeMode ? timing.cadenceActiveNs : timing.cadenceIdleNs
    }

    func recordRequestedCadence(_ cadence: UInt64, state: inout SessionState) {
        let (duration, overflow) = state.requestedCadenceDurationNs.addingReportingOverflow(cadence)
        state.requestedCadenceDurationNs = overflow ? UInt64.max : duration
        state.requestedCadenceIntervals += 1
    }

    func keepDecision(
        nowNs: UInt64,
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

        let elapsedSinceKeep = nowNs >= state.lastKeptNs ? nowNs - state.lastKeptNs : 0
        let isHeartbeat = elapsedSinceKeep >= heartbeatNs
        if isHeartbeat {
            return (true, .heartbeat)
        }

        return (false, .cap)
    }

    func sleep(ns: UInt64, since start: UInt64, deadlineNs: UInt64? = nil) async throws {
        // Video input already has intrinsic cadence; do not add wall-clock throttling.
        if self.frameSource != nil {
            return
        }
        if self.hasStopRequest() {
            return
        }
        let (unboundedTarget, targetOverflow) = start.addingReportingOverflow(ns)
        let cadenceTarget = targetOverflow ? UInt64.max : unboundedTarget
        let target = min(cadenceTarget, deadlineNs ?? UInt64.max)
        let now = self.clock.nowNanoseconds()
        guard target > now else { return }

        try Task.checkCancellation()
        let clock = self.clock
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await clock.sleep(nanoseconds: target - now)
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

final class WatchCaptureAttemptContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WatchCaptureSession.CaptureAttemptRaceResult, Never>?
    private var result: WatchCaptureSession.CaptureAttemptRaceResult?

    func wait() async -> WatchCaptureSession.CaptureAttemptRaceResult {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            if let result = self.result {
                self.lock.unlock()
                continuation.resume(returning: result)
            } else {
                precondition(self.continuation == nil)
                self.continuation = continuation
                self.lock.unlock()
            }
        }
    }

    func resume(with result: WatchCaptureSession.CaptureAttemptRaceResult) {
        self.lock.lock()
        guard self.result == nil else {
            self.lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(returning: result)
    }
}
