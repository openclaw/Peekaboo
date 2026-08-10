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
    public let changePercent: Double
    public let reason: Reason
    public let motionBoxes: [CGRect]?

    public init(
        index: Int,
        path: String,
        file: String,
        timestampMs: Int,
        changePercent: Double,
        reason: Reason,
        motionBoxes: [CGRect]? = nil)
    {
        self.index = index
        self.path = path
        self.file = file
        self.timestampMs = timestampMs
        self.changePercent = changePercent
        self.reason = reason
        self.motionBoxes = motionBoxes
    }
}

public struct CaptureStats: Codable, Sendable, Equatable {
    public let durationMs: Int
    public let fpsIdle: Double
    public let fpsActive: Double
    public let fpsEffective: Double
    public let framesKept: Int
    public let framesDropped: Int
    public let decodeFailures: Int
    public let maxFramesHit: Bool
    public let maxMbHit: Bool

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
        self.durationMs = durationMs
        self.fpsIdle = fpsIdle
        self.fpsActive = fpsActive
        self.fpsEffective = fpsEffective
        self.framesKept = framesKept
        self.framesDropped = framesDropped
        self.decodeFailures = decodeFailures
        self.maxFramesHit = maxFramesHit
        self.maxMbHit = maxMbHit
    }

    private enum CodingKeys: String, CodingKey {
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
        self.durationMs = try container.decode(Int.self, forKey: .durationMs)
        self.fpsIdle = try container.decode(Double.self, forKey: .fpsIdle)
        self.fpsActive = try container.decode(Double.self, forKey: .fpsActive)
        self.fpsEffective = try container.decode(Double.self, forKey: .fpsEffective)
        self.framesKept = try container.decode(Int.self, forKey: .framesKept)
        self.framesDropped = try container.decode(Int.self, forKey: .framesDropped)
        self.decodeFailures = try container.decodeIfPresent(Int.self, forKey: .decodeFailures) ?? 0
        self.maxFramesHit = try container.decode(Bool.self, forKey: .maxFramesHit)
        self.maxMbHit = try container.decode(Bool.self, forKey: .maxMbHit)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
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

    public init(
        path: String,
        file: String,
        columns: Int,
        rows: Int,
        thumbSize: CGSize,
        sampledFrameIndexes: [Int])
    {
        self.path = path
        self.file = file
        self.columns = columns
        self.rows = rows
        self.thumbSize = thumbSize
        self.sampledFrameIndexes = sampledFrameIndexes
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
