import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import os.log

public struct WindowTrackerStatus: Sendable, Codable {
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

public struct WindowTrackerConfiguration: Sendable {
    public let pollInterval: TimeInterval
    public let useAXNotifications: Bool

    public init(pollInterval: TimeInterval = 1.0, useAXNotifications: Bool = true) {
        self.pollInterval = pollInterval
        self.useAXNotifications = useAXNotifications
    }
}

@MainActor
public final class WindowTrackerService: WindowTrackingProviding {
    private struct TrackedWindow {
        let bounds: CGRect
        let ownerProcessIdentifier: pid_t
    }

    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "WindowTracker")
    private let config: WindowTrackerConfiguration
    private let windowIdentityService = WindowIdentityService()
    private let exactWindowIdentityProvider: @MainActor (CGWindowID) -> SystemWindowIdentity?
    private let visibleWindowInfoProvider: @MainActor () -> [[String: Any]]?

    private var windows: [CGWindowID: TrackedWindow] = [:]
    private var watchers: [NotificationWatcher] = []
    private var pollTask: Task<Void, Never>?
    private var lastEventAt: Date?
    private var lastPollAt: Date?

    public init(configuration: WindowTrackerConfiguration = WindowTrackerConfiguration()) {
        self.config = configuration
        self.exactWindowIdentityProvider = SystemIdentityResolver.windowIdentity
        self.visibleWindowInfoProvider = WindowInfoHelper.getVisibleWindows
    }

    init(
        configuration: WindowTrackerConfiguration = WindowTrackerConfiguration(),
        exactWindowIdentityProvider: @escaping @MainActor (CGWindowID) -> SystemWindowIdentity?,
        visibleWindowInfoProvider: @escaping @MainActor () -> [[String: Any]]? = WindowInfoHelper.getVisibleWindows)
    {
        self.config = configuration
        self.exactWindowIdentityProvider = exactWindowIdentityProvider
        self.visibleWindowInfoProvider = visibleWindowInfoProvider
    }

    public func start() {
        guard self.pollTask == nil else { return }

        if self.config.useAXNotifications {
            self.installAXObservers()
        }

        self.pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    public func stop() {
        self.pollTask?.cancel()
        self.pollTask = nil

        for watcher in self.watchers {
            watcher.stop()
        }
        self.watchers.removeAll()
        self.windows.removeAll()
    }

    public func windowBounds(for windowID: CGWindowID) -> CGRect? {
        self.windows[windowID]?.bounds
    }

    public func windowOwnerProcessIdentifier(for windowID: CGWindowID) -> pid_t? {
        guard let ownerProcessIdentifier = self.windows[windowID]?.ownerProcessIdentifier,
              ownerProcessIdentifier > 0
        else {
            return nil
        }
        return ownerProcessIdentifier
    }

    public func refreshWindow(for windowID: CGWindowID) {
        self.refreshWindow(windowID: windowID)
    }

    public func status() -> WindowTrackerStatus {
        WindowTrackerStatus(
            trackedWindows: self.windows.count,
            lastEventAt: self.lastEventAt,
            lastPollAt: self.lastPollAt,
            axObserverCount: self.watchers.count,
            cgPollIntervalMs: Int(self.config.pollInterval * 1000.0))
    }

    private func installAXObservers() {
        let notifications: [AXNotification] = [
            .windowCreated,
            .windowMoved,
            .windowResized,
            .windowMinimized,
            .windowDeminiaturized,
            .uiElementDestroyed,
            .mainWindowChanged,
            .focusedWindowChanged,
        ]

        for notification in notifications {
            let watcher = NotificationWatcher(globalNotification: notification) { [weak self] pid, event, raw, info in
                self?.handleNotification(pid: pid, notification: event, rawElement: raw, userInfo: info)
            }

            do {
                try watcher.start()
                self.watchers.append(watcher)
            } catch {
                self.logger.warning("Failed to register AX notification \(notification.rawValue): \(error)")
            }
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            let start = Date()
            self.refreshAllWindows()
            self.lastPollAt = Date()
            let elapsed = Date().timeIntervalSince(start)
            let sleepSeconds = max(0.05, self.config.pollInterval - elapsed)
            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }
    }

    private func handleNotification(
        pid: pid_t,
        notification: AXNotification,
        rawElement: AXUIElement,
        userInfo: [String: Any]?)
    {
        self.lastEventAt = Date()

        let element = Element(rawElement)
        if let windowID = self.windowIdentityService.getWindowID(from: element) {
            self.refreshWindow(windowID: windowID)
            return
        }

        if let userInfo,
           let attr = userInfo[AXAttributeNames.kAXWindowAttribute],
           let windowID = self.windowIdentityService.windowIDFromAttribute(attr)
        {
            self.refreshWindow(windowID: windowID)
            return
        }

        self.logger.debug("Window tracker event missing window ID pid=\(pid) notification=\(notification.rawValue)")
    }

    func refreshWindow(windowID: CGWindowID) {
        guard let identity = self.exactWindowIdentityProvider(windowID) else {
            self.windows[windowID] = nil
            return
        }

        self.windows[windowID] = TrackedWindow(
            bounds: identity.bounds,
            ownerProcessIdentifier: identity.ownerProcessIdentifier)
    }

    func refreshAllWindows() {
        guard let windowInfo = self.visibleWindowInfoProvider() else {
            return
        }

        var newWindows: [CGWindowID: TrackedWindow] = [:]

        for entry in windowInfo {
            guard let windowID = entry[kCGWindowNumber as String] as? Int else { continue }
            guard let trackedWindow = Self.buildTrackedWindow(from: entry) else { continue }
            newWindows[CGWindowID(windowID)] = trackedWindow
        }

        self.windows = newWindows
    }

    private static func buildTrackedWindow(from dict: [String: Any]) -> TrackedWindow? {
        guard let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }

        let bounds = CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0)

        guard let ownerPID = dict[kCGWindowOwnerPID as String] as? Int,
              let ownerProcessIdentifier = pid_t(exactly: ownerPID),
              ownerProcessIdentifier > 0
        else {
            return nil
        }

        return TrackedWindow(
            bounds: bounds,
            ownerProcessIdentifier: ownerProcessIdentifier)
    }
}
