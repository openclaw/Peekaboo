import CoreGraphics
import Foundation

// MARK: - Application & Window Models

/// Information about a running application.
///
/// Contains metadata about an application including its name, bundle identifier,
/// process ID, activation state, and number of windows.
public struct ApplicationInfo: Codable, Sendable {
    public let app_name: String
    public let bundle_id: String
    public let pid: Int32
    public let is_active: Bool
    public let window_count: Int

    public init(
        app_name: String,
        bundle_id: String,
        pid: Int32,
        is_active: Bool,
        window_count: Int)
    {
        self.app_name = app_name
        self.bundle_id = bundle_id
        self.pid = pid
        self.is_active = is_active
        self.window_count = window_count
    }
}

/// Container for application list results.
///
/// Wraps an array of ApplicationInfo objects returned when listing
/// all running applications on the system.
public struct ApplicationListData: Codable, Sendable {
    public let applications: [ApplicationInfo]

    public init(applications: [ApplicationInfo]) {
        self.applications = applications
    }
}

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

    public init(
        windows: [WindowInfo],
        target_application_info: TargetApplicationInfo)
    {
        self.windows = windows
        self.target_application_info = target_application_info
    }
}

// MARK: - Window Specifier

/// Specifies how to identify a window for operations.
///
/// Windows can be identified either by their title (with fuzzy matching)
/// or by their index in the window list.
public enum WindowSpecifier: Sendable {
    case title(String)
    case index(Int)
}

// MARK: - Window Details Options

/// Options for including additional window details.
///
/// Controls which optional window properties are included when listing windows,
/// allowing users to request additional information like bounds or off-screen status.
public enum WindowDetailOption: String, CaseIterable, Codable, Sendable {
    case off_screen
    case bounds
    case ids
}
