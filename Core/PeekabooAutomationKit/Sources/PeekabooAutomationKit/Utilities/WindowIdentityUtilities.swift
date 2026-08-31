import AppKit
import AXorcist
import CoreGraphics
import Foundation
import os.log

/// Thin wrapper around AXorcist's AXWindowResolver to keep Peekaboo APIs stable
/// while de-duplicating AX/CG window logic.
public struct WindowIdentityInfo: Sendable {
    public let windowID: CGWindowID
    public let title: String?
    public let bounds: CGRect
    public let ownerPID: pid_t
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let layer: Int
    public let alpha: CGFloat
    public let axIdentifier: String?

    public var isRenderable: Bool {
        self.layer == 0 && self.bounds.width >= 50 && self.bounds.height >= 50 && self.alpha > 0
    }

    public var windowLayer: Int {
        self.layer
    } // Backward compatibility

    public var isMainWindow: Bool {
        self.layer == 0 && self.alpha > 0
    }

    public var isDialog: Bool {
        self.layer >= 10 && self.layer < 1000
    }

    public init(
        windowID: CGWindowID,
        title: String?,
        bounds: CGRect,
        ownerPID: pid_t,
        applicationName: String?,
        bundleIdentifier: String?,
        layer: Int,
        alpha: CGFloat,
        axIdentifier: String?)
    {
        self.windowID = windowID
        self.title = title
        self.bounds = bounds
        self.ownerPID = ownerPID
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.layer = layer
        self.alpha = alpha
        self.axIdentifier = axIdentifier
    }

    /// Convenience to preserve older label windowLayer
    public init(
        windowID: CGWindowID,
        title: String?,
        bounds: CGRect,
        ownerPID: pid_t,
        applicationName: String?,
        bundleIdentifier: String?,
        windowLayer: Int,
        alpha: CGFloat,
        axIdentifier: String?)
    {
        self.init(
            windowID: windowID,
            title: title,
            bounds: bounds,
            ownerPID: ownerPID,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            layer: windowLayer,
            alpha: alpha,
            axIdentifier: axIdentifier)
    }
}

@MainActor
public final class WindowIdentityService {
    private let resolver = AXWindowResolver()
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "WindowIdentity")

    public init() {}

    // MARK: - CGWindowID Extraction

    func getWindowID(from element: Element, messagingTimeout: Float = 0.25) -> CGWindowID? {
        try? element.withMessagingTimeout(messagingTimeout) { childWindow in
            self.resolver.windowID(from: childWindow)
        }
    }

    // MARK: - AX Lookup

    func findWindow(byID windowID: CGWindowID, in app: NSRunningApplication) -> AXWindowHandle? {
        self.findWindow(byID: windowID, in: app, messagingTimeout: 1)
    }

    /// Resolve an exact WindowServer ID through a process-scoped AX query with a hard messaging timeout.
    ///
    /// The generic resolver intentionally has broad fallbacks, but state mutations must not spend the
    /// process-wide 10-second AX budget (or scan unrelated apps) while holding the Bridge mutation gate.
    func findWindow(
        byID windowID: CGWindowID,
        messagingTimeout: Float) -> AXWindowHandle?
    {
        guard let info = self.exactWindowServerInfo(windowID: windowID),
              let app = NSRunningApplication(processIdentifier: info.ownerPID)
        else {
            return nil
        }

        return self.findWindow(byID: windowID, in: app, messagingTimeout: messagingTimeout)
    }

    private func findWindow(
        byID windowID: CGWindowID,
        in app: NSRunningApplication,
        messagingTimeout: Float) -> AXWindowHandle?
    {
        let appElement = Element(AXUIElementCreateApplication(app.processIdentifier))
        guard let windows = try? appElement.withMessagingTimeout(
            messagingTimeout,
            operation: { $0.windows() })
        else {
            return nil
        }
        for window in windows {
            let matches = try? window.withMessagingTimeout(messagingTimeout) { childWindow in
                self.resolver.windowID(from: childWindow) == windowID
            }
            if matches == true {
                return AXWindowHandle(app: AXApp(app), element: window)
            }
        }
        return nil
    }

    func findWindow(byID windowID: CGWindowID) -> AXWindowHandle? {
        self.findWindow(byID: windowID, messagingTimeout: 1)
    }

    func focusedWindowID(for app: NSRunningApplication, timeout: TimeInterval) -> CGWindowID? {
        guard timeout > 0 else { return nil }
        let axApp = AXApp(app)
        guard let focusedWindow = try? axApp.element.withMessagingTimeout(
            Float(timeout),
            operation: { _ in axApp.focusedWindow() })
        else {
            return nil
        }
        return try? focusedWindow.withMessagingTimeout(Float(timeout)) { window in
            self.resolver.windowID(from: window)
        }
    }

    // MARK: - Window Information

    public func getWindowInfo(windowID: CGWindowID) -> WindowIdentityInfo? {
        guard let info = self.exactWindowServerInfo(windowID: windowID) else { return nil }

        // Compute AX identifier lazily.
        let axIdentifier: String? = if let handle = self.findWindow(byID: windowID, messagingTimeout: 1) {
            try? handle.element.withMessagingTimeout(1) { window in
                window.identifier()
            }
        } else {
            nil
        }

        return WindowIdentityInfo(
            windowID: info.windowID,
            title: info.title,
            bounds: info.bounds,
            ownerPID: info.ownerPID,
            applicationName: info.applicationName,
            bundleIdentifier: info.bundleIdentifier,
            layer: info.layer,
            alpha: info.alpha,
            axIdentifier: axIdentifier)
    }

    /// Return exact WindowServer metadata without making any Accessibility call.
    func getWindowServerInfo(windowID: CGWindowID) -> WindowIdentityInfo? {
        self.exactWindowServerInfo(windowID: windowID)
    }

    /// List windows for a running application using CGWindow metadata.
    public func getWindows(for app: NSRunningApplication) -> [WindowIdentityInfo] {
        guard let windowDicts = WindowInfoHelper.getWindows(for: app.processIdentifier) else {
            return []
        }

        return windowDicts.compactMap { dict in
            guard let id = dict[kCGWindowNumber as String] as? Int else { return nil }
            let title = dict[kCGWindowName as String] as? String
            let ownerPID = dict[kCGWindowOwnerPID as String] as? Int ?? Int(app.processIdentifier)
            let layer = dict[kCGWindowLayer as String] as? Int ?? 0
            let alpha = dict[kCGWindowAlpha as String] as? CGFloat ?? 1.0
            var boundsRect: CGRect = .zero
            if let bounds = dict[kCGWindowBounds as String] as? [String: CGFloat] {
                boundsRect = CGRect(
                    x: bounds["X"] ?? 0,
                    y: bounds["Y"] ?? 0,
                    width: bounds["Width"] ?? 0,
                    height: bounds["Height"] ?? 0)
            }

            return WindowIdentityInfo(
                windowID: CGWindowID(id),
                title: title,
                bounds: boundsRect,
                ownerPID: pid_t(ownerPID),
                applicationName: app.localizedName,
                bundleIdentifier: app.bundleIdentifier,
                layer: layer,
                alpha: alpha,
                axIdentifier: nil)
        }
    }

    /// Capture the WindowServer catalog once for application inventory.
    ///
    /// `ApplicationService.listApplications()` used to copy the global catalog once per running
    /// process. Besides scaling poorly, that placed every read serially on MainActor. The catalog
    /// already carries owner PIDs, so one immutable snapshot can be grouped per application.
    public func getWindowCatalog() -> [WindowIdentityInfo]? {
        Self.readWindowCatalog()
    }

    nonisolated static func readWindowCatalog() -> [WindowIdentityInfo]? {
        guard let windowDicts = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }

        return windowDicts.compactMap(Self.windowIdentityInfo(from:))
    }

    // MARK: - Existence

    public func windowExists(windowID: CGWindowID) -> Bool {
        self.exactWindowServerInfo(windowID: windowID) != nil
    }

    public func isWindowOnScreen(windowID: CGWindowID) -> Bool {
        // Existence and visibility are different questions: `windowExists` also resolves minimized and
        // off-Space windows through the full catalog, so on-screen state needs the on-screen list.
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            windowID) as? [[String: Any]]
        else {
            return false
        }
        return Self.exactWindowDictionary(windowID: windowID, in: windowList) != nil
    }

    public func isTopmostRenderableWindow(windowID: CGWindowID) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]],
            let target = windowList.first(where: { Self.windowID(from: $0) == windowID }),
            let ownerPID = Self.ownerPID(from: target),
            Self.isRenderableWindow(target)
        else {
            return false
        }

        return Self.topmostRenderableWindowID(ownerPID: ownerPID, in: windowList) == windowID
    }

    nonisolated static func topmostRenderableWindowID(ownerPID: pid_t, in windowList: [[String: Any]]) -> CGWindowID? {
        windowList.first { window in
            Self.ownerPID(from: window) == ownerPID && Self.isRenderableWindow(window)
        }.flatMap(self.windowID(from:))
    }

    nonisolated static func isRenderableWindow(_ window: [String: Any]) -> Bool {
        let layer = Self.intValue(window[kCGWindowLayer as String]) ?? 0
        let alpha = Self.cgFloatValue(window[kCGWindowAlpha as String]) ?? 1.0
        let bounds = Self.bounds(from: window)
        return layer == 0 && bounds.width >= 50 && bounds.height >= 50 && alpha > 0
    }

    private nonisolated static func windowID(from window: [String: Any]) -> CGWindowID? {
        self.intValue(window[kCGWindowNumber as String]).map(CGWindowID.init)
    }

    nonisolated static func exactWindowDictionary(
        windowID: CGWindowID,
        in windowList: [[String: Any]]) -> [String: Any]?
    {
        windowList.first(where: { self.windowID(from: $0) == windowID })
    }

    private func exactWindowServerInfo(windowID: CGWindowID) -> WindowIdentityInfo? {
        Self.exactWindowServerInfo(
            windowID: windowID,
            windowListProvider: { options, relativeToWindow in
                CGWindowListCopyWindowInfo(options, relativeToWindow) as? [[String: Any]]
            })
    }

    /// Resolve one exact window through the shared catalog lookup.
    ///
    /// `optionIncludingWindow` alone omits minimized and off-Space windows, so resolving only through
    /// it reported live windows as gone while window listing — which scans `optionAll` — still returned
    /// them. The shared exact-window observation owns that fallback; a window absent from both lists
    /// stays unresolved.
    static func exactWindowServerInfo(
        windowID: CGWindowID,
        windowListProvider: (CGWindowListOption, CGWindowID) -> [[String: Any]]?) -> WindowIdentityInfo?
    {
        guard case let .found(window) = SystemIdentityResolver.exactWindowCatalogObservation(
            windowID,
            windowListProvider: windowListProvider),
            let ownerPID = Self.ownerPID(from: window)
        else {
            return nil
        }

        let application = NSRunningApplication(processIdentifier: ownerPID)
        return WindowIdentityInfo(
            windowID: windowID,
            title: window[kCGWindowName as String] as? String,
            bounds: Self.bounds(from: window),
            ownerPID: ownerPID,
            applicationName: application?.localizedName,
            bundleIdentifier: application?.bundleIdentifier,
            layer: Self.intValue(window[kCGWindowLayer as String]) ?? 0,
            alpha: Self.cgFloatValue(window[kCGWindowAlpha as String]) ?? 1,
            axIdentifier: nil)
    }

    private nonisolated static func ownerPID(from window: [String: Any]) -> pid_t? {
        self.intValue(window[kCGWindowOwnerPID as String]).map(pid_t.init)
    }

    private nonisolated static func windowIdentityInfo(from window: [String: Any]) -> WindowIdentityInfo? {
        guard let windowID = self.windowID(from: window),
              let ownerPID = self.ownerPID(from: window)
        else {
            return nil
        }
        return WindowIdentityInfo(
            windowID: windowID,
            title: window[kCGWindowName as String] as? String,
            bounds: self.bounds(from: window),
            ownerPID: ownerPID,
            applicationName: window[kCGWindowOwnerName as String] as? String,
            bundleIdentifier: nil,
            layer: self.intValue(window[kCGWindowLayer as String]) ?? 0,
            alpha: self.cgFloatValue(window[kCGWindowAlpha as String]) ?? 1,
            axIdentifier: nil)
    }

    private nonisolated static func bounds(from window: [String: Any]) -> CGRect {
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else {
            return .zero
        }

        return CGRect(
            x: Self.cgFloatValue(bounds["X"]) ?? 0,
            y: Self.cgFloatValue(bounds["Y"]) ?? 0,
            width: Self.cgFloatValue(bounds["Width"]) ?? 0,
            height: Self.cgFloatValue(bounds["Height"]) ?? 0)
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let int32Value = value as? Int32 {
            return Int(int32Value)
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private nonisolated static func cgFloatValue(_ value: Any?) -> CGFloat? {
        if let cgFloat = value as? CGFloat {
            return cgFloat
        }
        if let double = value as? Double {
            return CGFloat(double)
        }
        if let int = value as? Int {
            return CGFloat(int)
        }
        if let number = value as? NSNumber {
            return CGFloat(truncating: number)
        }
        return nil
    }

    // MARK: - AX attribute helpers

    func windowIDFromAttribute(_ attribute: Any?) -> CGWindowID? {
        if let number = attribute as? NSNumber {
            return CGWindowID(number.intValue)
        }

        if let dict = attribute as? [String: Any],
           let windowNumber = dict[kCGWindowNumber as String] as? Int
        {
            return CGWindowID(windowNumber)
        }

        self.logger.debug("windowIDFromAttribute: unsupported attribute \(String(describing: attribute))")
        return nil
    }
}
