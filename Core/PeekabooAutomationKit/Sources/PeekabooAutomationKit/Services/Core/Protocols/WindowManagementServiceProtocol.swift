import CoreGraphics
import Foundation
import PeekabooFoundation

/// Protocol defining window management operations
public protocol WindowManagementServiceProtocol: Sendable {
    /// Close a window
    /// - Parameters:
    ///   - target: Window targeting options
    func closeWindow(target: WindowTarget) async throws

    /// Close a window, optionally escalating from AX to focused/global input fallbacks.
    /// Background callers must leave `allowForegroundFallback` false.
    func closeWindow(target: WindowTarget, allowForegroundFallback: Bool) async throws

    /// Close only while the exact window owner and owner process generation match the selection receipt.
    func closeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws

    /// Minimize a window
    /// - Parameters:
    ///   - target: Window targeting options
    func minimizeWindow(target: WindowTarget) async throws

    func minimizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws

    /// Restore a minimized window without activating or focusing its application.
    func restoreWindow(target: WindowTarget) async throws

    func restoreWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws

    /// Fill a window's current screen using background-safe geometry.
    /// - Parameters:
    ///   - target: Window targeting options
    func maximizeWindow(target: WindowTarget) async throws

    func maximizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws

    /// Move a window to specific coordinates
    /// - Parameters:
    ///   - target: Window targeting options
    ///   - position: New position for the window
    func moveWindow(target: WindowTarget, to position: CGPoint) async throws

    func moveWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint) async throws

    /// Resize a window
    /// - Parameters:
    ///   - target: Window targeting options
    ///   - size: New size for the window
    func resizeWindow(target: WindowTarget, to size: CGSize) async throws

    func resizeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws

    /// Set window bounds (position and size)
    /// - Parameters:
    ///   - target: Window targeting options
    ///   - bounds: New bounds for the window
    func setWindowBounds(target: WindowTarget, bounds: CGRect) async throws

    func setWindowBounds(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws

    /// Focus/activate a window
    /// - Parameters:
    ///   - target: Window targeting options
    func focusWindow(target: WindowTarget) async throws

    /// List all windows matching the target
    /// - Parameters:
    ///   - target: Window targeting options
    /// - Returns: Array of window information
    func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo]

    /// Get the currently focused window
    /// - Returns: Window information if a window is focused
    func getFocusedWindow() async throws -> ServiceWindowInfo?
}

extension WindowManagementServiceProtocol {
    public func closeWindow(target: WindowTarget, allowForegroundFallback: Bool) async throws {
        guard allowForegroundFallback else {
            throw PeekabooError.operationError(
                message: "This window service does not implement AX-only background close")
        }
        try await self.closeWindow(target: target)
    }

    public func closeWindow(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        allowForegroundFallback _: Bool) async throws
    {
        throw Self.unsupportedPinnedWindowMutation()
    }

    public func minimizeWindow(target _: WindowTarget, expectedIdentity _: WindowMutationIdentity) async throws {
        throw Self.unsupportedPinnedWindowMutation()
    }

    public func restoreWindow(target _: WindowTarget) async throws {
        throw Self.unsupportedPinnedWindowMutation()
    }

    public func restoreWindow(target _: WindowTarget, expectedIdentity _: WindowMutationIdentity) async throws {
        throw Self.unsupportedPinnedWindowMutation()
    }

    public func maximizeWindow(target _: WindowTarget, expectedIdentity _: WindowMutationIdentity) async throws {
        throw Self.unsupportedPinnedWindowMutation()
    }

    public func moveWindow(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGPoint) async throws
    {
        throw Self.unsupportedPinnedWindowMutation()
    }

    public func resizeWindow(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGSize) async throws
    {
        throw Self.unsupportedPinnedWindowMutation()
    }

    public func setWindowBounds(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        bounds _: CGRect) async throws
    {
        throw Self.unsupportedPinnedWindowMutation()
    }

    private static func unsupportedPinnedWindowMutation() -> PeekabooError {
        PeekabooError.serviceUnavailable(
            "This window service does not support process-generation-pinned mutations; update the runtime host")
    }
}

/// Options for targeting a window
public enum WindowTarget: Sendable, CustomStringConvertible, Codable {
    /// Target by application name or bundle ID
    case application(String)

    /// Target by window title (substring match)
    case title(String)

    /// Target by application and window index
    case index(app: String, index: Int)

    /// Target by application and window title (more efficient than title alone)
    case applicationAndTitle(app: String, title: String)

    /// Target the frontmost window
    case frontmost

    /// Target a specific window ID
    case windowId(Int)

    private enum CodingKeys: String, CodingKey { case kind, app, index, title, windowId }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "application":
            self = try .application(container.decode(String.self, forKey: .app))
        case "title":
            self = try .title(container.decode(String.self, forKey: .title))
        case "index":
            let app = try container.decode(String.self, forKey: .app)
            let index = try container.decode(Int.self, forKey: .index)
            self = .index(app: app, index: index)
        case "applicationAndTitle":
            let app = try container.decode(String.self, forKey: .app)
            let title = try container.decode(String.self, forKey: .title)
            self = .applicationAndTitle(app: app, title: title)
        case "frontmost":
            self = .frontmost
        case "windowId":
            self = try .windowId(container.decode(Int.self, forKey: .windowId))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown WindowTarget kind: \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .application(app):
            try container.encode("application", forKey: .kind)
            try container.encode(app, forKey: .app)
        case let .title(title):
            try container.encode("title", forKey: .kind)
            try container.encode(title, forKey: .title)
        case let .index(app, index):
            try container.encode("index", forKey: .kind)
            try container.encode(app, forKey: .app)
            try container.encode(index, forKey: .index)
        case let .applicationAndTitle(app, title):
            try container.encode("applicationAndTitle", forKey: .kind)
            try container.encode(app, forKey: .app)
            try container.encode(title, forKey: .title)
        case .frontmost:
            try container.encode("frontmost", forKey: .kind)
        case let .windowId(id):
            try container.encode("windowId", forKey: .kind)
            try container.encode(id, forKey: .windowId)
        }
    }

    public var description: String {
        switch self {
        case let .application(app):
            "application(\(app))"
        case let .title(title):
            "title(\(title))"
        case let .index(app, index):
            "index(app: \(app), index: \(index))"
        case let .applicationAndTitle(app, title):
            "applicationAndTitle(app: \(app), title: \(title))"
        case .frontmost:
            "frontmost"
        case let .windowId(id):
            "windowId(\(id))"
        }
    }
}
