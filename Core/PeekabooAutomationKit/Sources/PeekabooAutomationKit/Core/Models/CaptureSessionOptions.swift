import CoreGraphics
import Foundation

/// Target scope for capture sessions.
public struct CaptureScope: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case screen
        case window
        case frontmost
        case region
    }

    public let kind: Kind
    public let screenIndex: Int?
    public let displayUUID: String?
    public let windowId: UInt32?
    /// Exact process-generation and immutable-bounds receipt for live window capture.
    ///
    /// A numeric WindowServer ID alone is reusable and cannot authorize a multi-frame capture.
    public let windowMutationIdentity: WindowMutationIdentity?
    public let applicationIdentifier: String?
    public let windowIndex: Int?
    public let region: CGRect?

    public init(
        kind: Kind,
        screenIndex: Int? = nil,
        displayUUID: String? = nil,
        windowId: UInt32? = nil,
        windowMutationIdentity: WindowMutationIdentity? = nil,
        applicationIdentifier: String? = nil,
        windowIndex: Int? = nil,
        region: CGRect? = nil)
    {
        self.kind = kind
        self.screenIndex = screenIndex
        self.displayUUID = displayUUID
        self.windowId = windowId
        self.windowMutationIdentity = windowMutationIdentity
        self.applicationIdentifier = applicationIdentifier
        self.windowIndex = windowIndex
        self.region = region
    }
}

/// Options controlling live capture behavior.
public struct CaptureOptions: Sendable, Equatable {
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
    public let diffStrategy: DiffStrategy
    public let diffBudgetMs: Int?

    public enum DiffStrategy: String, Codable, Sendable {
        case fast
        case quality
    }

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
        diffStrategy: DiffStrategy,
        diffBudgetMs: Int?)
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
    }
}
