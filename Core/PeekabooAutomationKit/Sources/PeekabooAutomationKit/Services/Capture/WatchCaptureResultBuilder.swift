import Foundation

struct WatchCaptureResultBuilder {
    let sourceKind: CaptureSessionResult.Source
    let videoIn: String?
    let videoOut: String?
    let scope: CaptureScope
    let options: CaptureOptions
    let videoOptions: CaptureVideoOptionsSnapshot?
    let diffScale: String

    struct Input {
        let frames: [CaptureFrameInfo]
        let contactSheet: CaptureContactSheet
        let metadataURL: URL
        let durationMs: Int
        let framesDropped: Int
        let frameAttempts: Int
        let totalBytes: Int
        let warnings: [CaptureWarning]
        let sourceDiagnostics: CaptureFrameSourceDiagnostics
    }

    func build(_ input: Input) -> CaptureSessionResult {
        CaptureSessionResult(
            source: self.sourceKind,
            videoIn: self.videoIn,
            videoOut: self.videoOut,
            frames: input.frames,
            contactSheet: input.contactSheet,
            metadataFile: input.metadataURL.path,
            stats: self.makeStats(input),
            scope: self.scope,
            diffAlgorithm: self.options.diffStrategy.rawValue,
            diffScale: self.diffScale,
            options: self.makeOptionsSnapshot(),
            warnings: self.captureWarnings(
                frames: input.frames,
                warnings: input.warnings,
                sourceDiagnostics: input.sourceDiagnostics))
    }

    private func captureWarnings(
        frames: [CaptureFrameInfo],
        warnings: [CaptureWarning],
        sourceDiagnostics: CaptureFrameSourceDiagnostics) -> [CaptureWarning]
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
        let hadCaptureLoss = sourceDiagnostics.decodeFailures > 0 ||
            warnings.contains(where: { $0.code == .transientCaptureFailure })
        if frames.count < 2, !hadCaptureLoss {
            output.append(WatchWarning(code: .noMotion, message: "No motion detected; only key frames captured"))
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
            input.frameAttempts >= self.options.maxFrames
        } else {
            input.frames.count >= self.options.maxFrames
        }
        return WatchStats(
            durationMs: input.durationMs,
            fpsIdle: self.options.idleFps,
            fpsActive: self.options.activeFps,
            fpsEffective: Self.computeEffectiveFps(frameCount: input.frames.count, durationMs: input.durationMs),
            framesKept: input.frames.count,
            framesDropped: input.framesDropped,
            decodeFailures: input.sourceDiagnostics.decodeFailures,
            maxFramesHit: maxFramesHit,
            maxMbHit: maxMbHit)
    }

    private static func computeEffectiveFps(frameCount: Int, durationMs: Int) -> Double {
        guard durationMs > 0 else { return 0 }
        return Double(frameCount) / (Double(durationMs) / 1000.0)
    }
}
