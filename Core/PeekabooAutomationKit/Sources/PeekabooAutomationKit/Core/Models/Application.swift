import CoreGraphics
import Foundation

// MARK: - Application & Window Models

/// Information about a window.
///
/// Contains details about a window including its title, unique identifier,
/// position in the window list, bounds, visibility status, and screen information.
public struct WindowInfo: Codable, Sendable {
    public let window_title: String
    public let window_id: UInt32?
    public let window_index: Int?
    public let bounds: WindowBounds?
    public let is_on_screen: Bool?
    public let screen_index: Int?
    public let screen_name: String?
    public let is_frontmost: Bool?
    public let is_key: Bool?
    public let layer: Int?
    public let subrole: String?

    public init(
        window_title: String,
        window_id: UInt32? = nil,
        window_index: Int? = nil,
        bounds: WindowBounds? = nil,
        is_on_screen: Bool? = nil,
        screen_index: Int? = nil,
        screen_name: String? = nil,
        is_frontmost: Bool? = nil,
        is_key: Bool? = nil,
        layer: Int? = nil,
        subrole: String? = nil)
    {
        self.window_title = window_title
        self.window_id = window_id
        self.window_index = window_index
        self.bounds = bounds
        self.is_on_screen = is_on_screen
        self.screen_index = screen_index
        self.screen_name = screen_name
        self.is_frontmost = is_frontmost
        self.is_key = is_key
        self.layer = layer
        self.subrole = subrole
    }
}

/// Window position and dimensions.
///
/// Represents the rectangular bounds of a window on screen,
/// including its origin point (x, y) and size (width, height).
public struct WindowBounds: Codable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Basic information about a target application.
///
/// A simplified application info structure used in window list responses
/// to identify the owning application.
public struct TargetApplicationInfo: Codable, Sendable {
    public let app_name: String
    public let bundle_id: String?
    public let pid: Int32

    public init(
        app_name: String,
        bundle_id: String? = nil,
        pid: Int32)
    {
        self.app_name = app_name
        self.bundle_id = bundle_id
        self.pid = pid
    }
}

/// Container for window list results.
///
/// Contains an array of windows belonging to a specific application,
/// along with information about the target application.
public struct WindowListData: Codable, Sendable {
    public let windows: [WindowInfo]
    public let target_application_info: TargetApplicationInfo
    public let inventory_completeness: String?
    public let inventory_warnings: [String]?

    public init(
        windows: [WindowInfo],
        target_application_info: TargetApplicationInfo,
        inventory_completeness: String? = nil,
        inventory_warnings: [String]? = nil)
    {
        self.windows = windows
        self.target_application_info = target_application_info
        self.inventory_completeness = inventory_completeness
        self.inventory_warnings = inventory_warnings
    }
}
