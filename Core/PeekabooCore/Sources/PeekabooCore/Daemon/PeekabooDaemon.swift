import Foundation
import os.log
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

@MainActor
public final class PeekabooDaemon: PeekabooConditionalDaemonControlProviding {
    public struct Configuration: Sendable {
        public let mode: PeekabooDaemonMode
        public let bridgeSocketPath: String
        public let bridgeHostingEnabled: Bool
        public let allowlistedTeams: Set<String>
        public let allowlistedBundles: Set<String>
        public let allowedOperations: Set<PeekabooBridgeOperation>
        public let windowTrackingEnabled: Bool
        public let windowPollInterval: TimeInterval
        public let hostKind: PeekabooBridgeHostKind
        public let exitOnStop: Bool
        public let idleTimeout: TimeInterval?

        public init(
            mode: PeekabooDaemonMode,
            bridgeSocketPath: String = PeekabooBridgeConstants.daemonSocketPath,
            allowlistedTeams: Set<String> = ["Y5PE65HELJ"],
            allowlistedBundles: Set<String> = [],
            allowedOperations: Set<PeekabooBridgeOperation> = PeekabooBridgeOperation.remoteDefaultAllowlist,
            windowTrackingEnabled: Bool = true,
            windowPollInterval: TimeInterval = 1.0,
            hostKind: PeekabooBridgeHostKind,
            exitOnStop: Bool = false,
            idleTimeout: TimeInterval? = nil,
            bridgeHostingEnabled: Bool = true)
        {
            self.mode = mode
            self.bridgeSocketPath = bridgeSocketPath
            self.bridgeHostingEnabled = bridgeHostingEnabled
            self.allowlistedTeams = allowlistedTeams
            self.allowlistedBundles = allowlistedBundles
            self.allowedOperations = allowedOperations
            self.windowTrackingEnabled = windowTrackingEnabled
            self.windowPollInterval = windowPollInterval
            self.hostKind = hostKind
            self.exitOnStop = exitOnStop
            self.idleTimeout = idleTimeout
        }

        public static func auto(
            bridgeSocketPath: String = PeekabooBridgeConstants.daemonSocketPath,
            windowPollInterval: TimeInterval = 1.0,
            idleTimeout: TimeInterval = 300) -> Configuration
        {
            Configuration(
                mode: .auto,
                bridgeSocketPath: bridgeSocketPath,
                allowlistedTeams: [],
                windowTrackingEnabled: true,
                windowPollInterval: windowPollInterval,
                hostKind: .onDemand,
                idleTimeout: idleTimeout)
        }

        public static func manual(
            bridgeSocketPath: String = PeekabooBridgeConstants.daemonSocketPath,
            windowPollInterval: TimeInterval = 1.0) -> Configuration
        {
            Configuration(
                mode: .manual,
                bridgeSocketPath: bridgeSocketPath,
                allowlistedTeams: [],
                windowTrackingEnabled: true,
                windowPollInterval: windowPollInterval,
                hostKind: .onDemand)
        }

        public static func mcp(
            bridgeSocketPath: String = PeekabooBridgeConstants.peekabooSocketPath,
            windowPollInterval: TimeInterval = 1.0) -> Configuration
        {
            Configuration(
                mode: .mcp,
                bridgeSocketPath: bridgeSocketPath,
                allowlistedTeams: [],
                windowTrackingEnabled: true,
                windowPollInterval: windowPollInterval,
                hostKind: .inProcess,
                exitOnStop: true)
        }

        public static func embeddedMCP(
            windowPollInterval: TimeInterval = 1.0) -> Configuration
        {
            Configuration(
                mode: .mcp,
                bridgeSocketPath: PeekabooBridgeConstants.daemonSocketPath,
                allowlistedTeams: [],
                windowTrackingEnabled: true,
                windowPollInterval: windowPollInterval,
                hostKind: .inProcess,
                exitOnStop: false,
                bridgeHostingEnabled: false)
        }
    }

    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "Daemon")
    private let configuration: Configuration
    private let services: PeekabooServices
    private let startTime: Date
    private var bridgeHost: PeekabooBridgeHost?
    private var windowTracker: WindowTrackerService?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var isStopping = false
    private var activeRequestCount = 0
    private var lastActivityAt: Date?
    private var idleShutdownTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.services = PeekabooServices(snapshotManager: InMemorySnapshotManager())
        self.startTime = Date()
    }

    public func start() async {
        do {
            try await self.startChecked()
        } catch {
            self.logger.error("Failed to start Peekaboo daemon: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func startChecked() async throws {
        self.services.installAgentRuntimeDefaults()
        self.services.ensureVisualizerConnection()

        if self.configuration.windowTrackingEnabled {
            let tracker = WindowTrackerService(
                configuration: WindowTrackerConfiguration(pollInterval: self.configuration.windowPollInterval))
            tracker.start()
            WindowMovementTracking.provider = tracker
            self.windowTracker = tracker
        }

        if self.bridgeHost == nil, self.configuration.bridgeHostingEnabled {
            do {
                let bridgeHost = try await PeekabooBridgeBootstrap.startHostChecked(
                    services: self.services,
                    hostKind: self.configuration.hostKind,
                    socketPath: self.configuration.bridgeSocketPath,
                    allowlistedTeams: self.configuration.allowlistedTeams,
                    allowlistedBundles: self.configuration.allowlistedBundles,
                    daemonControl: self,
                    allowedOperations: self.configuration.allowedOperations)
                if self.isStopping {
                    await bridgeHost.stop()
                    self.windowTracker?.stop()
                    self.windowTracker = nil
                    WindowMovementTracking.provider = nil
                    return
                }
                self.bridgeHost = bridgeHost
            } catch {
                self.windowTracker?.stop()
                self.windowTracker = nil
                WindowMovementTracking.provider = nil
                throw error
            }
        }

        self.logger.info("Peekaboo daemon started mode=\(self.configuration.mode.rawValue)")
        self.lastActivityAt = Date()
        self.scheduleIdleShutdownIfNeeded()
    }

    public func runUntilStop() async {
        do {
            try await self.runUntilStopChecked()
        } catch {
            self.logger.error("Failed to run Peekaboo daemon: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func runUntilStopChecked() async throws {
        try await self.startChecked()
        guard !self.isStopping else { return }
        await withCheckedContinuation { continuation in
            if self.isStopping {
                continuation.resume()
            } else {
                self.stopContinuation = continuation
            }
        }
        await self.shutdownTask?.value
    }

    public func daemonStatus() async -> PeekabooDaemonStatus {
        let permissions = self.services.permissions.checkAllPermissions()
        let snapshots = await self.snapshotStatus()
        let trackerStatus = self.windowTracker?.status()

        let bridgeStatus = self.configuration.bridgeHostingEnabled
            ? PeekabooDaemonBridgeStatus(
                socketPath: self.configuration.bridgeSocketPath,
                hostKind: self.configuration.hostKind,
                allowedOperations: Array(self.configuration.allowedOperations).sorted { $0.rawValue < $1.rawValue })
            : nil

        let windowStatus = trackerStatus.map { status in
            PeekabooDaemonWindowTrackerStatus(
                trackedWindows: status.trackedWindows,
                lastEventAt: status.lastEventAt,
                lastPollAt: status.lastPollAt,
                axObserverCount: status.axObserverCount,
                cgPollIntervalMs: status.cgPollIntervalMs)
        }

        return await PeekabooDaemonStatus(
            running: true,
            pid: getpid(),
            startedAt: self.startTime,
            mode: self.configuration.mode,
            bridge: bridgeStatus,
            permissions: permissions,
            snapshots: snapshots,
            windowTracker: windowStatus,
            browser: try? self.services.browserStatus(channel: nil),
            activity: self.activityStatus(now: Date()),
            supportsConditionalStop: true)
    }

    public func requestStop() async -> Bool {
        await self.requestStopIfIdle()
    }

    public func requestStop(expectedPID: pid_t) async -> Bool {
        guard expectedPID == getpid() else { return false }
        return await self.requestStopIfIdle()
    }

    private func requestStopIfIdle() async -> Bool {
        guard !self.isStopping, self.activeRequestCount == 0 else { return false }
        self.isStopping = true
        self.shutdownTask = Task { [self] in
            await self.finishStop()
        }
        return true
    }

    public func waitUntilStopped() async {
        await self.shutdownTask?.value
    }

    private func finishStop() async {
        await self.shutdown()
        self.stopContinuation?.resume()
        self.stopContinuation = nil

        if self.configuration.exitOnStop {
            exit(0)
        }
    }

    public func recordActivityStart(operation: PeekabooBridgeOperation) async {
        _ = await self.admitActivity(operation: operation)
    }

    public func admitActivity(operation: PeekabooBridgeOperation) async -> Bool {
        guard !self.isStopping else { return false }
        self.activeRequestCount += 1
        self.lastActivityAt = Date()
        self.idleShutdownTask?.cancel()
        self.idleShutdownTask = nil
        self.logger.debug("daemon activity started op=\(operation.rawValue)")
        return true
    }

    public func recordActivityEnd(operation: PeekabooBridgeOperation) async {
        guard !self.isStopping else { return }
        self.activeRequestCount = max(0, self.activeRequestCount - 1)
        self.lastActivityAt = Date()
        self.logger.debug("daemon activity ended op=\(operation.rawValue)")
        self.scheduleIdleShutdownIfNeeded()
    }

    private func shutdown() async {
        self.idleShutdownTask?.cancel()
        self.idleShutdownTask = nil

        if let host = self.bridgeHost {
            await host.stop()
            self.bridgeHost = nil
        }

        await self.services.browser.disconnect()

        self.windowTracker?.stop()
        self.windowTracker = nil
        WindowMovementTracking.provider = nil
    }

    private func snapshotStatus() async -> PeekabooDaemonSnapshotStatus {
        let list = await (try? self.services.snapshots.listSnapshots()) ?? []
        let lastAccessed = list.map(\ .lastAccessedAt).max()
        let backend: String = self.services.snapshots is InMemorySnapshotManager ? "memory" : "disk"
        return PeekabooDaemonSnapshotStatus(
            backend: backend,
            snapshotCount: list.count,
            lastAccessedAt: lastAccessed,
            storagePath: self.services.snapshots.getSnapshotStoragePath())
    }

    private func activityStatus(now: Date) -> PeekabooDaemonActivityStatus {
        let idleExitAt = self.idleExitDate(now: now)
        return PeekabooDaemonActivityStatus(
            activeRequests: self.activeRequestCount,
            lastActivityAt: self.lastActivityAt,
            idleTimeoutSeconds: self.configuration.idleTimeout,
            idleExitAt: idleExitAt)
    }

    private func idleExitDate(now: Date) -> Date? {
        guard let idleTimeout = self.configuration.idleTimeout,
              self.activeRequestCount == 0,
              let lastActivityAt = self.lastActivityAt
        else {
            return nil
        }

        let deadline = lastActivityAt.addingTimeInterval(idleTimeout)
        return deadline > now ? deadline : now
    }

    private func scheduleIdleShutdownIfNeeded() {
        guard !self.isStopping,
              self.activeRequestCount == 0,
              let idleTimeout = self.configuration.idleTimeout,
              idleTimeout > 0
        else {
            return
        }

        self.idleShutdownTask?.cancel()
        let lastActivityAt = self.lastActivityAt ?? Date()
        let remaining = max(0.05, lastActivityAt.addingTimeInterval(idleTimeout).timeIntervalSinceNow)
        self.idleShutdownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            await self?.stopIfIdleTimedOut()
        }
    }

    private func stopIfIdleTimedOut() async {
        guard !self.isStopping,
              self.activeRequestCount == 0,
              let idleTimeout = self.configuration.idleTimeout,
              let lastActivityAt = self.lastActivityAt,
              Date().timeIntervalSince(lastActivityAt) >= idleTimeout
        else {
            self.scheduleIdleShutdownIfNeeded()
            return
        }

        self.idleShutdownTask = nil
        self.logger.info("Peekaboo daemon idle timeout reached; stopping")
        _ = await self.requestStop()
    }
}
