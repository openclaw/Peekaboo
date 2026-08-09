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
    public let maxFramesHit: Bool
    public let maxMbHit: Bool

    public init(
        durationMs: Int,
        fpsIdle: Double,
        fpsActive: Double,
        fpsEffective: Double,
        framesKept: Int,
        framesDropped: Int,
        maxFramesHit: Bool,
        maxMbHit: Bool)
    {
        self.durationMs = durationMs
        self.fpsIdle = fpsIdle
        self.fpsActive = fpsActive
        self.fpsEffective = fpsEffective
        self.framesKept = framesKept
        self.framesDropped = framesDropped
        self.maxFramesHit = maxFramesHit
        self.maxMbHit = maxMbHit
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
