import Foundation

struct WatchCaptureResultBuilder {
    let sourceKind: CaptureSessionResult.Source
    let videoIn: String?
    let videoOut: String?
    let videoArtifactCustody: CaptureVideoArtifactCustody?
    let scope: CaptureScope
    let options: CaptureOptions
    let videoOptions: CaptureVideoOptionsSnapshot?
    let diffScale: String

    struct Input {
        let frames: [CaptureFrameInfo]
        let contactSheet: CaptureContactSheet
        let metadataURL: URL
        let totalDurationMs: Int
        let sampling: WatchCaptureSession.SamplingMetrics
        let returnedFrameAttempts: Int
        let totalBytes: Int
        let warnings: [CaptureWarning]
        let sourceDiagnostics: CaptureFrameSourceDiagnostics
    }

    func build(_ input: Input) -> CaptureSessionResult {
        let stats = self.makeStats(input)
        return CaptureSessionResult(
            source: self.sourceKind,
            videoIn: self.videoIn,
            videoOut: self.videoOut,
            videoArtifactCustody: self.videoArtifactCustody,
            frames: input.frames,
            contactSheet: input.contactSheet,
            metadataFile: input.metadataURL.path,
            stats: stats,
            scope: self.scope,
            diffAlgorithm: self.options.diffStrategy.rawValue,
            diffScale: self.diffScale,
            options: self.makeOptionsSnapshot(),
            warnings: self.captureWarnings(
                frames: input.frames,
                warnings: input.warnings,
                sourceDiagnostics: input.sourceDiagnostics,
                stats: stats))
    }

    private func captureWarnings(
        frames: [CaptureFrameInfo],
        warnings: [CaptureWarning],
        sourceDiagnostics: CaptureFrameSourceDiagnostics,
        stats: CaptureStats) -> [CaptureWarning]
    {
        var output = warnings
        if self.sourceKind == .video,
           sourceDiagnostics.decodeFailures > 0,
           !output.contains(where: { $0.code == .videoDecodeFailure })
        {
            var details = ["count": "\(sourceDiagnostics.decodeFailures)"]
            if let first = sourceDiagnostics.firstDecodeError {
                details["first_error"] = first
            }
            if let last = sourceDiagnostics.lastDecodeError {
                details["last_error"] = last
            }
            output.append(WatchWarning(
                code: .videoDecodeFailure,
                message: "Skipped \(sourceDiagnostics.decodeFailures) undecodable video sample(s)",
                details: details))
        }
        let hadCaptureLoss = sourceDiagnostics.decodeFailures > 0 || stats.captureFailures > 0 ||
            warnings.contains(where: { $0.code == .transientCaptureFailure })
        if frames.count < 2, !hadCaptureLoss {
            output.append(WatchWarning(code: .noMotion, message: "No motion detected; only key frames captured"))
        }
        if stats.lowFps {
            output.append(WatchWarning(
                code: .lowFps,
                message: "Live capture sampling fell below 80% of the requested adaptive cadence",
                details: [
                    "sampled_fps": String(format: "%.2f", stats.sampledFps),
                    "idle_fps": String(format: "%.2f", stats.requestedIdleFps),
                    "active_fps": String(format: "%.2f", stats.requestedActiveFps),
                ]))
        }
        return output
    }

    private func makeOptionsSnapshot() -> CaptureOptionsSnapshot {
        CaptureOptionsSnapshot(
            duration: self.options.duration,
            idleFps: self.options.idleFps,
            activeFps: self.options.activeFps,
            changeThresholdPercent: self.options.changeThresholdPercent,
            heartbeatSeconds: self.options.heartbeatSeconds,
            quietMsToIdle: self.options.quietMsToIdle,
            maxFrames: self.options.maxFrames,
            maxMegabytes: self.options.maxMegabytes,
            highlightChanges: self.options.highlightChanges,
            captureFocus: self.options.captureFocus,
            resolutionCap: self.options.resolutionCap,
            diffStrategy: self.options.diffStrategy,
            diffBudgetMs: self.options.diffBudgetMs,
            video: self.videoOptions)
    }

    private func makeStats(_ input: Input) -> WatchStats {
        let maxMbHit = self.options.maxMegabytes != nil
            && input.totalBytes / (1024 * 1024) >= (self.options.maxMegabytes ?? 0)
        let maxFramesHit = if self.sourceKind == .video {
            input.returnedFrameAttempts >= self.options.maxFrames
        } else {
            input.frames.count >= self.options.maxFrames
        }
        let sampledFps = Self.computeFps(
            frameCount: input.sampling.framesSampled,
            durationNs: input.sampling.durationNs)
        let keptFps = Self.computeFps(
            frameCount: input.frames.count,
            durationNs: input.sampling.durationNs)
        let requestedAdaptiveFps = Self.computeFps(
            frameCount: input.sampling.requestedCadenceIntervals,
            durationNs: input.sampling.requestedCadenceDurationNs)
        let lowFps = self.sourceKind == .live &&
            input.sampling.requestedCadenceIntervals > 0 &&
            sampledFps < requestedAdaptiveFps * 0.8
        return WatchStats(
            totalDurationMs: input.totalDurationMs,
            samplingDurationMs: Int(input.sampling.durationNs / 1_000_000),
            requestedIdleFps: self.options.idleFps,
            requestedActiveFps: self.options.activeFps,
            captureAttempts: input.sampling.captureAttempts,
            framesSampled: input.sampling.framesSampled,
            captureFailures: input.sampling.captureFailures,
            framesDiffFiltered: input.sampling.framesDiffFiltered,
            sampledFps: sampledFps,
            keptFps: keptFps,
            lowFps: lowFps,
            framesKept: input.frames.count,
            decodeFailures: input.sourceDiagnostics.decodeFailures,
            maxFramesHit: maxFramesHit,
            maxMbHit: maxMbHit)
    }

    private static func computeFps(frameCount: Int, durationNs: UInt64) -> Double {
        guard durationNs > 0 else { return 0 }
        return Double(frameCount) / (Double(durationNs) / 1_000_000_000)
    }
}
