import CoreGraphics
import Foundation

public struct CaptureFrameInfo: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable {
        case first
        case motion
        case heartbeat
        case cap
    }

    public let index: Int
    public let path: String
    public let file: String
    public let timestampMs: Int
    /// Difference from the previous retained frame when diff filtering is enabled.
    public let changePercent: Double
    public let reason: Reason
    public let motionBoxes: [CGRect]?
    /// SHA-256 of the exact PNG bytes written by the capture session.
    public let sha256: String?
    /// Capture backend that produced this retained frame, when reported by the source.
    public let captureEngine: String?

    public init(
        index: Int,
        path: String,
        file: String,
        timestampMs: Int,
        changePercent: Double,
        reason: Reason,
        motionBoxes: [CGRect]? = nil,
        sha256: String? = nil,
        captureEngine: String? = nil)
    {
        self.index = index
        self.path = path
        self.file = file
        self.timestampMs = timestampMs
        self.changePercent = changePercent
        self.reason = reason
        self.motionBoxes = motionBoxes
        self.sha256 = sha256
        self.captureEngine = captureEngine
    }
}

public struct CaptureStats: Codable, Sendable, Equatable {
    /// End-to-end session time through artifact postprocessing, before metadata persistence.
    public let totalDurationMs: Int
    /// Time spent in the sampling loop. Contact-sheet, video-finalization, and metadata work are excluded.
    public let samplingDurationMs: Int
    public let requestedIdleFps: Double
    public let requestedActiveFps: Double
    /// Source acquisitions started, including recoverable failed attempts.
    public let captureAttempts: Int
    /// Valid images delivered to retention/diff processing.
    public let framesSampled: Int
    /// Acquisition failures. Video decode failures remain separately reported by `decodeFailures`.
    public let captureFailures: Int
    /// Valid sampled frames rejected only by diff/heartbeat retention policy.
    public let framesDiffFiltered: Int
    /// Valid sampled images per second during `samplingDurationMs`.
    public let sampledFps: Double
    /// Retained frames per second during `samplingDurationMs`.
    public let keptFps: Double
    /// True when live sampling achieved less than 80% of its adaptive requested cadence.
    public let lowFps: Bool
    public let framesKept: Int
    public let decodeFailures: Int
    public let maxFramesHit: Bool
    public let maxMbHit: Bool

    /// Compatibility alias for `totalDurationMs`.
    public var durationMs: Int {
        self.totalDurationMs
    }

    /// Compatibility alias for `requestedIdleFps`.
    public var fpsIdle: Double {
        self.requestedIdleFps
    }

    /// Compatibility alias for `requestedActiveFps`.
    public var fpsActive: Double {
        self.requestedActiveFps
    }

    /// Compatibility alias for retained-frame throughput (`keptFps`).
    public var fpsEffective: Double {
        self.keptFps
    }

    /// Compatibility aggregate of capture, decode, and diff-filtered losses.
    public var framesDropped: Int {
        self.captureFailures + self.decodeFailures + self.framesDiffFiltered
    }

    public init(
        totalDurationMs: Int,
        samplingDurationMs: Int,
        requestedIdleFps: Double,
        requestedActiveFps: Double,
        captureAttempts: Int,
        framesSampled: Int,
        captureFailures: Int,
        framesDiffFiltered: Int,
        sampledFps: Double,
        keptFps: Double,
        lowFps: Bool,
        framesKept: Int,
        decodeFailures: Int = 0,
        maxFramesHit: Bool,
        maxMbHit: Bool)
    {
        self.totalDurationMs = totalDurationMs
        self.samplingDurationMs = samplingDurationMs
        self.requestedIdleFps = requestedIdleFps
        self.requestedActiveFps = requestedActiveFps
        self.captureAttempts = captureAttempts
        self.framesSampled = framesSampled
        self.captureFailures = captureFailures
        self.framesDiffFiltered = framesDiffFiltered
        self.sampledFps = sampledFps
        self.keptFps = keptFps
        self.lowFps = lowFps
        self.framesKept = framesKept
        self.decodeFailures = decodeFailures
        self.maxFramesHit = maxFramesHit
        self.maxMbHit = maxMbHit
    }

    /// Source-compatible initializer for callers that still construct the legacy aggregate.
    public init(
        durationMs: Int,
        fpsIdle: Double,
        fpsActive: Double,
        fpsEffective: Double,
        framesKept: Int,
        framesDropped: Int,
        decodeFailures: Int = 0,
        maxFramesHit: Bool,
        maxMbHit: Bool)
    {
        let diffFiltered = max(0, framesDropped - decodeFailures)
        self.totalDurationMs = durationMs
        self.samplingDurationMs = durationMs
        self.requestedIdleFps = fpsIdle
        self.requestedActiveFps = fpsActive
        self.captureAttempts = framesKept + framesDropped
        self.framesSampled = framesKept + diffFiltered
        self.captureFailures = 0
        self.framesDiffFiltered = diffFiltered
        self.sampledFps = fpsEffective
        self.keptFps = fpsEffective
        self.lowFps = false
        self.framesKept = framesKept
        self.decodeFailures = decodeFailures
        self.maxFramesHit = maxFramesHit
        self.maxMbHit = maxMbHit
    }

    private enum CodingKeys: String, CodingKey {
        case totalDurationMs
        case samplingDurationMs
        case requestedIdleFps
        case requestedActiveFps
        case captureAttempts
        case framesSampled
        case captureFailures
        case framesDiffFiltered
        case sampledFps
        case keptFps
        case lowFps
        // Compatibility keys retained in encoded metadata.
        case durationMs
        case fpsIdle
        case fpsActive
        case fpsEffective
        case framesKept
        case framesDropped
        case decodeFailures
        case maxFramesHit
        case maxMbHit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyDuration = try container.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        let legacyIdle = try container.decodeIfPresent(Double.self, forKey: .fpsIdle) ?? 0
        let legacyActive = try container.decodeIfPresent(Double.self, forKey: .fpsActive) ?? 0
        let legacyEffective = try container.decodeIfPresent(Double.self, forKey: .fpsEffective) ?? 0
        let legacyDropped = try container.decodeIfPresent(Int.self, forKey: .framesDropped) ?? 0

        self.totalDurationMs = try container.decodeIfPresent(Int.self, forKey: .totalDurationMs) ?? legacyDuration
        self.samplingDurationMs = try container.decodeIfPresent(Int.self, forKey: .samplingDurationMs) ??
            legacyDuration
        self.requestedIdleFps = try container.decodeIfPresent(Double.self, forKey: .requestedIdleFps) ??
            legacyIdle
        self.requestedActiveFps = try container.decodeIfPresent(Double.self, forKey: .requestedActiveFps) ??
            legacyActive
        self.framesKept = try container.decode(Int.self, forKey: .framesKept)
        self.decodeFailures = try container.decodeIfPresent(Int.self, forKey: .decodeFailures) ?? 0
        self.captureFailures = try container.decodeIfPresent(Int.self, forKey: .captureFailures) ?? 0
        self.framesDiffFiltered = try container.decodeIfPresent(Int.self, forKey: .framesDiffFiltered) ??
            max(0, legacyDropped - self.captureFailures - self.decodeFailures)
        self.framesSampled = try container.decodeIfPresent(Int.self, forKey: .framesSampled) ??
            self.framesKept + self.framesDiffFiltered
        self.captureAttempts = try container.decodeIfPresent(Int.self, forKey: .captureAttempts) ??
            self.framesSampled + self.captureFailures + self.decodeFailures
        self.sampledFps = try container.decodeIfPresent(Double.self, forKey: .sampledFps) ?? legacyEffective
        self.keptFps = try container.decodeIfPresent(Double.self, forKey: .keptFps) ?? legacyEffective
        self.lowFps = try container.decodeIfPresent(Bool.self, forKey: .lowFps) ?? false
        self.maxFramesHit = try container.decode(Bool.self, forKey: .maxFramesHit)
        self.maxMbHit = try container.decode(Bool.self, forKey: .maxMbHit)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.totalDurationMs, forKey: .totalDurationMs)
        try container.encode(self.samplingDurationMs, forKey: .samplingDurationMs)
        try container.encode(self.requestedIdleFps, forKey: .requestedIdleFps)
        try container.encode(self.requestedActiveFps, forKey: .requestedActiveFps)
        try container.encode(self.captureAttempts, forKey: .captureAttempts)
        try container.encode(self.framesSampled, forKey: .framesSampled)
        try container.encode(self.captureFailures, forKey: .captureFailures)
        try container.encode(self.framesDiffFiltered, forKey: .framesDiffFiltered)
        try container.encode(self.sampledFps, forKey: .sampledFps)
        try container.encode(self.keptFps, forKey: .keptFps)
        try container.encode(self.lowFps, forKey: .lowFps)
        try container.encode(self.durationMs, forKey: .durationMs)
        try container.encode(self.fpsIdle, forKey: .fpsIdle)
        try container.encode(self.fpsActive, forKey: .fpsActive)
        try container.encode(self.fpsEffective, forKey: .fpsEffective)
        try container.encode(self.framesKept, forKey: .framesKept)
        try container.encode(self.framesDropped, forKey: .framesDropped)
        try container.encode(self.decodeFailures, forKey: .decodeFailures)
        try container.encode(self.maxFramesHit, forKey: .maxFramesHit)
        try container.encode(self.maxMbHit, forKey: .maxMbHit)
    }
}

public struct CaptureContactSheet: Codable, Sendable, Equatable {
    public let path: String
    public let file: String
    public let columns: Int
    public let rows: Int
    public let thumbSize: CGSize
    public let sampledFrameIndexes: [Int]
    /// SHA-256 of the exact PNG bytes written by the capture session.
    public let sha256: String?

    public init(
        path: String,
        file: String,
        columns: Int,
        rows: Int,
        thumbSize: CGSize,
        sampledFrameIndexes: [Int],
        sha256: String? = nil)
    {
        self.path = path
        self.file = file
        self.columns = columns
        self.rows = rows
        self.thumbSize = thumbSize
        self.sampledFrameIndexes = sampledFrameIndexes
        self.sha256 = sha256
    }
}

public struct CaptureWarning: Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable {
        case noMotion
        case sizeCap
        case frameCap
        case windowClosed
        case displayChanged
        case lowFps
        case diffDowngraded
        case autoclean
        case transientCaptureFailure
        case videoDecodeFailure
    }

    public let code: Code
    public let message: String
    public let details: [String: String]?

    public init(code: Code, message: String, details: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}
