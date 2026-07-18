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

    func getWindowID(from element: Element) -> CGWindowID? {
        self.resolver.windowID(from: element)
    }

    // MARK: - AX Lookup

    func findWindow(byID windowID: CGWindowID, in app: NSRunningApplication) -> AXWindowHandle? {
        guard let element = self.resolver.findWindow(by: windowID, in: app) else { return nil }
        return AXWindowHandle(app: AXApp(app), element: element)
    }

    func findWindow(byID windowID: CGWindowID) -> AXWindowHandle? {
        guard let result = self.resolver.findWindow(by: windowID) else { return nil }
        return AXWindowHandle(app: AXApp(result.app), element: result.window)
    }

    func focusedWindowID(for app: NSRunningApplication, timeout: TimeInterval) -> CGWindowID? {
        guard timeout > 0 else { return nil }
        let axApp = AXApp(app)
        axApp.element.setMessagingTimeout(Float(timeout))
        defer { axApp.element.setMessagingTimeout(0) }
        return axApp.focusedWindow().flatMap { self.getWindowID(from: $0) }
    }

    // MARK: - Window Information

    public func getWindowInfo(windowID: CGWindowID) -> WindowIdentityInfo? {
        guard let info = self.resolver.windowInfo(windowID: windowID) else { return nil }

        // Compute AX identifier lazily.
        let axIdentifier = self.findWindow(byID: windowID)?.element.identifier()

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

    // MARK: - Existence

    public func windowExists(windowID: CGWindowID) -> Bool {
        self.resolver.windowExists(windowID: windowID)
    }

    public func isWindowOnScreen(windowID: CGWindowID) -> Bool {
        self.windowExists(windowID: windowID)
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

    private nonisolated static func ownerPID(from window: [String: Any]) -> pid_t? {
        self.intValue(window[kCGWindowOwnerPID as String]).map(pid_t.init)
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
