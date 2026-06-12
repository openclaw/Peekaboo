import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

public enum PeekabooDaemonMode: String, Codable, Sendable {
    case auto
    case manual
    case mcp
}

public struct PeekabooBridgeDaemonStopRequest: Codable, Sendable {
    public let expectedPID: pid_t

    public init(expectedPID: pid_t) {
        self.expectedPID = expectedPID
    }
}

public struct PeekabooDaemonActivityStatus: Codable, Sendable {
    public let activeRequests: Int
    public let lastActivityAt: Date?
    public let idleTimeoutSeconds: Double?
    public let idleExitAt: Date?

    public init(
        activeRequests: Int,
        lastActivityAt: Date?,
        idleTimeoutSeconds: Double?,
        idleExitAt: Date?)
    {
        self.activeRequests = activeRequests
        self.lastActivityAt = lastActivityAt
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.idleExitAt = idleExitAt
    }
}

public struct PeekabooDaemonBridgeStatus: Codable, Sendable {
    public let socketPath: String
    public let hostKind: PeekabooBridgeHostKind
    public let allowedOperations: [PeekabooBridgeOperation]

    public init(
        socketPath: String,
        hostKind: PeekabooBridgeHostKind,
        allowedOperations: [PeekabooBridgeOperation])
    {
        self.socketPath = socketPath
        self.hostKind = hostKind
        self.allowedOperations = allowedOperations
    }
}

public struct PeekabooDaemonSnapshotStatus: Codable, Sendable {
    public let backend: String
    public let snapshotCount: Int
    public let lastAccessedAt: Date?
    public let storagePath: String

    public init(
        backend: String,
        snapshotCount: Int,
        lastAccessedAt: Date?,
        storagePath: String)
    {
        self.backend = backend
        self.snapshotCount = snapshotCount
        self.lastAccessedAt = lastAccessedAt
        self.storagePath = storagePath
    }
}

public struct PeekabooDaemonWindowTrackerStatus: Codable, Sendable {
    public let trackedWindows: Int
    public let lastEventAt: Date?
    public let lastPollAt: Date?
    public let axObserverCount: Int
    public let cgPollIntervalMs: Int

    public init(
        trackedWindows: Int,
        lastEventAt: Date?,
        lastPollAt: Date?,
        axObserverCount: Int,
        cgPollIntervalMs: Int)
    {
        self.trackedWindows = trackedWindows
        self.lastEventAt = lastEventAt
        self.lastPollAt = lastPollAt
        self.axObserverCount = axObserverCount
        self.cgPollIntervalMs = cgPollIntervalMs
    }
}

public struct PeekabooDaemonStatus: Codable, Sendable {
    public let running: Bool
    public let pid: pid_t?
    public let startedAt: Date?
    public let mode: PeekabooDaemonMode?
    public let bridge: PeekabooDaemonBridgeStatus?
    public let permissions: PermissionsStatus?
    public let snapshots: PeekabooDaemonSnapshotStatus?
    public let windowTracker: PeekabooDaemonWindowTrackerStatus?
    public let browser: PeekabooBridgeBrowserStatus?
    public let activity: PeekabooDaemonActivityStatus?
    public let supportsConditionalStop: Bool?

    public init(
        running: Bool,
        pid: pid_t? = nil,
        startedAt: Date? = nil,
        mode: PeekabooDaemonMode? = nil,
        bridge: PeekabooDaemonBridgeStatus? = nil,
        permissions: PermissionsStatus? = nil,
        snapshots: PeekabooDaemonSnapshotStatus? = nil,
        windowTracker: PeekabooDaemonWindowTrackerStatus? = nil,
        browser: PeekabooBridgeBrowserStatus? = nil,
        activity: PeekabooDaemonActivityStatus? = nil,
        supportsConditionalStop: Bool? = nil)
    {
        self.running = running
        self.pid = pid
        self.startedAt = startedAt
        self.mode = mode
        self.bridge = bridge
        self.permissions = permissions
        self.snapshots = snapshots
        self.windowTracker = windowTracker
        self.browser = browser
        self.activity = activity
        self.supportsConditionalStop = supportsConditionalStop
    }
}

@MainActor
public protocol PeekabooDaemonControlProviding: AnyObject, Sendable {
    func daemonStatus() async -> PeekabooDaemonStatus
    func requestStop() async -> Bool
    func recordActivityStart(operation: PeekabooBridgeOperation) async
    func recordActivityEnd(operation: PeekabooBridgeOperation) async
}

@MainActor
extension PeekabooDaemonControlProviding {
    public func recordActivityStart(operation _: PeekabooBridgeOperation) async {}
    public func recordActivityEnd(operation _: PeekabooBridgeOperation) async {}
}

@MainActor
public protocol PeekabooConditionalDaemonControlProviding: PeekabooDaemonControlProviding {
    func requestStop(expectedPID: pid_t) async -> Bool
    func admitActivity(operation: PeekabooBridgeOperation) async -> Bool
}
