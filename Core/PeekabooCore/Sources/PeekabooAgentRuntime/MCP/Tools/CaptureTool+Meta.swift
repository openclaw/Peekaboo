import MCP
import PeekabooAutomationKit

enum CaptureMetaBuilder {
    static func failureMeta(_ error: any Error, mutationDispatched: Bool) -> Value {
        if let noValidFrames = error as? CaptureNoValidFramesError {
            return self.noValidFramesMeta(noValidFrames, mutationDispatched: mutationDispatched)
        }
        var meta: [String: Value] = [
            "retry_safe": .bool(!mutationDispatched),
            "mutation_dispatched": .bool(mutationDispatched),
        ]
        if mutationDispatched {
            meta["effect"] = .string("partial")
        }
        return .object(meta)
    }

    static func noValidFramesMeta(
        _ error: CaptureNoValidFramesError,
        mutationDispatched: Bool) -> Value
    {
        var meta: [String: Value] = [
            "error_code": .string("CAPTURE_NO_VALID_FRAMES"),
            "retry_safe": .bool(error.retrySafe && !mutationDispatched),
            "mutation_dispatched": .bool(mutationDispatched),
            "source": .string(error.source.rawValue),
            "frames_dropped": .int(error.framesDropped),
            "decode_failures": .int(error.decodeFailures),
        ]
        if mutationDispatched {
            meta["effect"] = .string("partial")
        }
        if let first = error.firstDecodeError {
            meta["first_decode_error"] = .string(first)
        }
        if let last = error.lastDecodeError {
            meta["last_decode_error"] = .string(last)
        }
        if let last = error.lastCaptureError {
            meta["last_capture_error"] = .string(last)
        }
        return .object(meta)
    }

    static func buildMeta(from summary: CaptureMetaSummary) -> Value {
        .object(self.summaryMeta(from: summary))
    }

    static func buildMeta(from result: CaptureSessionResult, mutationDispatched: Bool = false) -> Value {
        var meta = self.summaryMeta(from: .make(from: result))
        meta["mutation_dispatched"] = .bool(mutationDispatched)
        meta["retry_safe"] = .bool(!mutationDispatched)
        meta["source"] = .string(result.source.rawValue)
        if let videoIn = result.videoIn {
            meta["video_in"] = .string(videoIn)
        }
        if let videoOut = result.videoOut {
            meta["video_out"] = .string(videoOut)
        }
        meta["stats"] = .object([
            "total_duration_ms": .int(result.stats.totalDurationMs),
            "sampling_duration_ms": .int(result.stats.samplingDurationMs),
            "requested_idle_fps": .double(result.stats.requestedIdleFps),
            "requested_active_fps": .double(result.stats.requestedActiveFps),
            "capture_attempts": .int(result.stats.captureAttempts),
            "frames_sampled": .int(result.stats.framesSampled),
            "capture_failures": .int(result.stats.captureFailures),
            "frames_diff_filtered": .int(result.stats.framesDiffFiltered),
            "sampled_fps": .double(result.stats.sampledFps),
            "kept_fps": .double(result.stats.keptFps),
            "low_fps": .bool(result.stats.lowFps),
            // Compatibility aliases for older MCP clients.
            "duration_ms": .int(result.stats.durationMs),
            "fps_idle": .double(result.stats.fpsIdle),
            "fps_active": .double(result.stats.fpsActive),
            "fps_effective": .double(result.stats.fpsEffective),
            "frames_kept": .int(result.stats.framesKept),
            "frames_dropped": .int(result.stats.framesDropped),
            "decode_failures": .int(result.stats.decodeFailures),
            "max_frames_hit": .bool(result.stats.maxFramesHit),
            "max_mb_hit": .bool(result.stats.maxMbHit),
        ])
        meta["warnings"] = .array(result.warnings.map(self.warningMeta))
        return .object(meta)
    }

    private static func summaryMeta(from summary: CaptureMetaSummary) -> [String: Value] {
        [
            "frames": .array(summary.frames.map { .string($0) }),
            "contact": .string(summary.contactPath),
            "metadata": .string(summary.metadataPath),
            "diff_algorithm": .string(summary.diffAlgorithm),
            "diff_scale": .string(summary.diffScale),
            "contact_columns": .string("\(summary.contactColumns)"),
            "contact_rows": .string("\(summary.contactRows)"),
            "contact_thumb_width": .string("\(summary.contactThumbSize.width)"),
            "contact_thumb_height": .string("\(summary.contactThumbSize.height)"),
            "contact_sampled_indexes": .array(summary.contactSampledIndexes.map { .string("\($0)") }),
            "artifact_sha256": .object(summary.artifactSHA256.mapValues(Value.string)),
        ]
    }

    private static func warningMeta(_ warning: CaptureWarning) -> Value {
        var meta: [String: Value] = [
            "code": .string(warning.code.rawValue),
            "message": .string(warning.message),
        ]
        if let details = warning.details {
            meta["details"] = .object(details.mapValues(Value.string))
        }
        return .object(meta)
    }
}
