import CoreGraphics
import Foundation

public struct CaptureOptionsSnapshot: Codable, Sendable, Equatable {
    public let duration: TimeInterval
    public let idleFps: Double
    public let activeFps: Double
    public let changeThresholdPercent: Double
    public let heartbeatSeconds: TimeInterval
    public let quietMsToIdle: Int
    public let maxFrames: Int
    public let maxMegabytes: Int?
    public let highlightChanges: Bool
    public let captureFocus: CaptureFocus
    public let resolutionCap: CGFloat?
    public let diffStrategy: CaptureOptions.DiffStrategy
    public let diffBudgetMs: Int?
    public let video: CaptureVideoOptionsSnapshot?

    public init(
        duration: TimeInterval,
        idleFps: Double,
        activeFps: Double,
        changeThresholdPercent: Double,
        heartbeatSeconds: TimeInterval,
        quietMsToIdle: Int,
        maxFrames: Int,
        maxMegabytes: Int?,
        highlightChanges: Bool,
        captureFocus: CaptureFocus,
        resolutionCap: CGFloat?,
        diffStrategy: CaptureOptions.DiffStrategy,
        diffBudgetMs: Int?,
        video: CaptureVideoOptionsSnapshot? = nil)
    {
        self.duration = duration
        self.idleFps = idleFps
        self.activeFps = activeFps
        self.changeThresholdPercent = changeThresholdPercent
        self.heartbeatSeconds = heartbeatSeconds
        self.quietMsToIdle = quietMsToIdle
        self.maxFrames = maxFrames
        self.maxMegabytes = maxMegabytes
        self.highlightChanges = highlightChanges
        self.captureFocus = captureFocus
        self.resolutionCap = resolutionCap
        self.diffStrategy = diffStrategy
        self.diffBudgetMs = diffBudgetMs
        self.video = video
    }
}

public struct CaptureVideoOptionsSnapshot: Codable, Sendable, Equatable {
    public let sampleFps: Double?
    public let everyMs: Int?
    public let effectiveFps: Double
    public let startMs: Int?
    public let endMs: Int?
    public let keepAllFrames: Bool

    public init(
        sampleFps: Double?,
        everyMs: Int?,
        effectiveFps: Double,
        startMs: Int?,
        endMs: Int?,
        keepAllFrames: Bool)
    {
        self.sampleFps = sampleFps
        self.everyMs = everyMs
        self.effectiveFps = effectiveFps
        self.startMs = startMs
        self.endMs = endMs
        self.keepAllFrames = keepAllFrames
    }
}

public struct CaptureVideoArtifactCustody: Codable, Sendable, Equatable {
    public let path: String
    public let byteCount: Int
    public let sha256: String
    public let device: UInt64
    public let inode: UInt64

    public init(path: String, byteCount: Int, sha256: String, device: UInt64, inode: UInt64) {
        self.path = path
        self.byteCount = byteCount
        self.sha256 = sha256
        self.device = device
        self.inode = inode
    }
}

public struct CaptureSessionResult: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case live, video }

    public let source: Source
    public let videoIn: String?
    public let videoOut: String?
    public let videoArtifactCustody: CaptureVideoArtifactCustody?

    public let frames: [CaptureFrameInfo]
    public let contactSheet: CaptureContactSheet
    public let metadataFile: String
    public let stats: CaptureStats
    public let scope: CaptureScope
    public let diffAlgorithm: String
    public let diffScale: String
    public let options: CaptureOptionsSnapshot
    public let warnings: [CaptureWarning]

    // Convenience: denormalized contact sheet info for agent/CLI surfaces
    public var contactColumns: Int {
        self.contactSheet.columns
    }

    public var contactRows: Int {
        self.contactSheet.rows
    }

    public var contactSampledIndexes: [Int] {
        self.contactSheet.sampledFrameIndexes
    }

    public var contactThumbSize: CGSize {
        self.contactSheet.thumbSize
    }

    public init(
        source: Source,
        videoIn: String?,
        videoOut: String?,
        videoArtifactCustody: CaptureVideoArtifactCustody? = nil,
        frames: [CaptureFrameInfo],
        contactSheet: CaptureContactSheet,
        metadataFile: String,
        stats: CaptureStats,
        scope: CaptureScope,
        diffAlgorithm: String,
        diffScale: String,
        options: CaptureOptionsSnapshot,
        warnings: [CaptureWarning])
    {
        self.source = source
        self.videoIn = videoIn
        self.videoOut = videoOut
        self.videoArtifactCustody = videoArtifactCustody
        self.frames = frames
        self.contactSheet = contactSheet
        self.metadataFile = metadataFile
        self.stats = stats
        self.scope = scope
        self.diffAlgorithm = diffAlgorithm
        self.diffScale = diffScale
        self.options = options
        self.warnings = warnings
    }
}

/// Shared summary for emitting capture metadata across CLI and MCP surfaces.
public struct CaptureMetaSummary: Sendable, Equatable {
    public let frames: [String]
    public let contactPath: String
    public let metadataPath: String
    public let diffAlgorithm: String
    public let diffScale: String
    public let contactColumns: Int
    public let contactRows: Int
    public let contactThumbSize: CGSize
    public let contactSampledIndexes: [Int]
    public let artifactSHA256: [String: String]

    public static func make(from result: CaptureSessionResult) -> CaptureMetaSummary {
        CaptureMetaSummary(
            frames: result.frames.map(\.path),
            contactPath: result.contactSheet.path,
            metadataPath: result.metadataFile,
            diffAlgorithm: result.diffAlgorithm,
            diffScale: result.diffScale,
            contactColumns: result.contactSheet.columns,
            contactRows: result.contactSheet.rows,
            contactThumbSize: result.contactSheet.thumbSize,
            contactSampledIndexes: result.contactSheet.sampledFrameIndexes,
            artifactSHA256: Dictionary(uniqueKeysWithValues: (
                result.frames.compactMap { frame in
                    frame.sha256.map { (frame.path, $0) }
                } +
                    [result.contactSheet.sha256.map { (result.contactSheet.path, $0) }].compactMap(\.self) +
                    [result.videoArtifactCustody.map { ($0.path, $0.sha256) }].compactMap(\.self))))
    }
}
