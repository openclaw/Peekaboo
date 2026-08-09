import CoreGraphics
import Foundation
import PeekabooFoundation

public struct ApplicationLaunchRequest: Sendable, Codable, Equatable {
    public let applicationIdentifier: String?
    public let applicationBundleIdentifier: String?
    public let openURLs: [URL]
    public let activates: Bool
    public let waitUntilReady: Bool
    public let waitForWindow: Bool
    public let createsNewInstance: Bool

    public init(
        applicationIdentifier: String? = nil,
        applicationBundleIdentifier: String? = nil,
        openURLs: [URL] = [],
        activates: Bool = false,
        waitUntilReady: Bool = false,
        waitForWindow: Bool = false,
        createsNewInstance: Bool = false)
    {
        self.applicationIdentifier = applicationIdentifier
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.openURLs = openURLs
        self.activates = activates
        self.waitUntilReady = waitUntilReady
        self.waitForWindow = waitForWindow
        self.createsNewInstance = createsNewInstance
    }

    private enum CodingKeys: String, CodingKey {
        case applicationIdentifier
        case applicationBundleIdentifier
        case openURLs
        case activates
        case waitUntilReady
        case waitForWindow
        case createsNewInstance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.applicationIdentifier = try container.decodeIfPresent(String.self, forKey: .applicationIdentifier)
        self.applicationBundleIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .applicationBundleIdentifier)
        self.openURLs = try container.decode([URL].self, forKey: .openURLs)
        self.activates = try container.decode(Bool.self, forKey: .activates)
        self.waitUntilReady = try container.decode(Bool.self, forKey: .waitUntilReady)
        self.waitForWindow = try container.decodeIfPresent(Bool.self, forKey: .waitForWindow) ?? false
        self.createsNewInstance = try container.decodeIfPresent(Bool.self, forKey: .createsNewInstance) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.applicationIdentifier, forKey: .applicationIdentifier)
        try container.encodeIfPresent(self.applicationBundleIdentifier, forKey: .applicationBundleIdentifier)
        try container.encode(self.openURLs, forKey: .openURLs)
        try container.encode(self.activates, forKey: .activates)
        try container.encode(self.waitUntilReady, forKey: .waitUntilReady)
        try container.encode(self.waitForWindow, forKey: .waitForWindow)
        try container.encode(self.createsNewInstance, forKey: .createsNewInstance)
    }
}

public struct ApplicationRelaunchRequest: Sendable, Codable, Equatable {
    public let targetIdentifier: String
    public let expectedTargetIdentity: ApplicationProcessIdentity?
    public let launchRequest: ApplicationLaunchRequest
    public let force: Bool
    public let waitSeconds: TimeInterval

    public init(
        targetIdentifier: String,
        expectedTargetIdentity: ApplicationProcessIdentity? = nil,
        launchRequest: ApplicationLaunchRequest,
        force: Bool = false,
        waitSeconds: TimeInterval = 2)
    {
        self.targetIdentifier = targetIdentifier
        self.expectedTargetIdentity = expectedTargetIdentity
        self.launchRequest = launchRequest
        self.force = force
        self.waitSeconds = waitSeconds
    }
}

/// Pins an application mutation to one process generation.
///
/// PIDs are reusable. Destructive callers must retain this receipt from application discovery and
/// hosts must revalidate it immediately before dispatching the mutation.
public struct ApplicationProcessIdentity: Sendable, Codable, Equatable {
    public let processIdentifier: Int32
    public let processStartIdentity: UInt64

    public init(processIdentifier: Int32, processStartIdentity: UInt64) {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
    }
}

public struct ApplicationQuitRequest: Sendable, Codable, Equatable {
    public let identifier: String
    public let force: Bool
    public let expectedIdentity: ApplicationProcessIdentity?

    public init(
        identifier: String,
        force: Bool = false,
        expectedIdentity: ApplicationProcessIdentity? = nil)
    {
        self.identifier = identifier
        self.force = force
        self.expectedIdentity = expectedIdentity
    }
}

/// Protocol defining application and window management operations
@MainActor
public protocol ApplicationServiceProtocol: Sendable {
    /// Whether this service implements the full `ApplicationLaunchRequest` contract.
    var supportsApplicationLaunchOptions: Bool { get }

    /// Whether launch requests can require a distinct process even when the app is already running.
    var supportsNewApplicationInstanceLaunch: Bool { get }

    /// Whether launch requests can wait for a regular app to expose a real window.
    var supportsApplicationWindowReadiness: Bool { get }

    /// Whether this service keeps quit/wait/launch in one host-side transaction.
    var supportsApplicationRelaunch: Bool { get }

    /// Whether quit requests can be pinned to an exact process generation.
    var supportsProcessGenerationPinnedApplicationQuit: Bool { get }

    /// List all running applications
    /// - Returns: UnifiedToolOutput containing application information
    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData>

    /// Find an application by name or bundle ID
    /// - Parameter identifier: Application name or bundle ID (supports fuzzy matching)
    /// - Returns: Application information if found
    func findApplication(identifier: String) async throws -> ServiceApplicationInfo

    /// List all windows for a specific application
    /// - Parameters:
    ///   - appIdentifier: Application name or bundle ID
    ///   - timeout: Optional timeout in seconds (defaults to 2 seconds)
    /// - Returns: UnifiedToolOutput containing window information
    func listWindows(for appIdentifier: String, timeout: Float?) async throws
        -> UnifiedToolOutput<ServiceWindowListData>

    /// Get information about the frontmost application
    /// - Returns: Application information
    func getFrontmostApplication() async throws -> ServiceApplicationInfo

    /// Check if an application is running
    /// - Parameter identifier: Application name or bundle ID
    /// - Returns: True if the application is running
    func isApplicationRunning(identifier: String) async throws -> Bool

    /// Launch an application
    /// - Parameter identifier: Application name or bundle ID
    /// - Returns: Application information after launch
    func launchApplication(identifier: String) async throws -> ServiceApplicationInfo

    /// Launch an application or open URLs using the runtime host's GUI session.
    func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo

    /// Quit, wait, and launch while keeping the runtime host alive for the entire transaction.
    func relaunchApplication(request: ApplicationRelaunchRequest) async throws -> ServiceApplicationInfo

    /// Activate (bring to front) an application
    /// - Parameter identifier: Application name or bundle ID
    func activateApplication(identifier: String) async throws

    /// Quit an application
    /// - Parameters:
    ///   - identifier: Application name or bundle ID
    ///   - force: Force quit without saving
    /// - Returns: True if the application was successfully quit
    func quitApplication(identifier: String, force: Bool) async throws -> Bool

    /// Quit only while the resolved process still matches the discovery receipt.
    func quitApplication(request: ApplicationQuitRequest) async throws -> Bool

    /// Hide an application
    /// - Parameter identifier: Application name or bundle ID
    func hideApplication(identifier: String) async throws

    /// Unhide an application
    /// - Parameter identifier: Application name or bundle ID
    func unhideApplication(identifier: String) async throws

    /// Hide all other applications
    /// - Parameter identifier: Application to keep visible
    func hideOtherApplications(identifier: String) async throws

    /// Show all hidden applications
    func showAllApplications() async throws
}

extension ApplicationServiceProtocol {
    public var supportsApplicationLaunchOptions: Bool {
        false
    }

    public var supportsNewApplicationInstanceLaunch: Bool {
        false
    }

    public var supportsApplicationWindowReadiness: Bool {
        false
    }

    public var supportsApplicationRelaunch: Bool {
        false
    }

    public var supportsProcessGenerationPinnedApplicationQuit: Bool {
        false
    }

    public func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        guard let identifier = request.applicationIdentifier,
              request.openURLs.isEmpty,
              request.activates,
              !request.waitUntilReady,
              !request.waitForWindow,
              !request.createsNewInstance
        else {
            throw PeekabooError.serviceUnavailable(
                "This application service does not support launch options; update the Peekaboo runtime host")
        }
        return try await self.launchApplication(identifier: identifier)
    }

    public func relaunchApplication(request _: ApplicationRelaunchRequest) async throws -> ServiceApplicationInfo {
        throw PeekabooError.serviceUnavailable(
            "This application service does not support atomic relaunch; update the Peekaboo runtime host")
    }

    public func quitApplication(request: ApplicationQuitRequest) async throws -> Bool {
        guard request.expectedIdentity == nil else {
            throw PeekabooError.serviceUnavailable(
                "This application service does not support process-generation-pinned quit; update the runtime host")
        }
        return try await self.quitApplication(identifier: request.identifier, force: request.force)
    }
}

/// Information about an application for service layer
public struct ServiceApplicationInfo: Sendable, Codable, Equatable {
    /// Process identifier
    public let processIdentifier: Int32

    /// Process-generation token captured while this application was resolved.
    ///
    /// Older Bridge hosts omit this field. Destructive callers must treat `nil` as unpinned and
    /// fail closed instead of relying on the reusable numeric PID alone.
    public let processStartIdentity: UInt64?

    /// Bundle identifier (e.g., "com.apple.Safari")
    public let bundleIdentifier: String?

    /// Application name
    public let name: String

    /// Path to the application bundle
    public let bundlePath: String?

    /// Whether the application is currently active (frontmost)
    public let isActive: Bool

    /// Whether the application is hidden
    public let isHidden: Bool

    /// Number of windows
    public var windowCount: Int

    /// Exact WindowServer identifiers known for the application's current windows.
    ///
    /// Older Bridge hosts omit this field, so callers must treat `nil` as unknown rather than
    /// claiming the application has no windows. A non-`nil` value is a point-in-time snapshot.
    public let windowIDs: [Int]?

    /// macOS activation policy, when known.
    public let activationPolicy: ServiceApplicationActivationPolicy?

    /// Whether LaunchServices reports that the app has finished launching.
    public let isFinishedLaunching: Bool?

    public init(
        processIdentifier: Int32,
        processStartIdentity: UInt64? = nil,
        bundleIdentifier: String?,
        name: String,
        bundlePath: String? = nil,
        isActive: Bool = false,
        isHidden: Bool = false,
        windowCount: Int = 0,
        windowIDs: [Int]? = nil,
        activationPolicy: ServiceApplicationActivationPolicy? = nil,
        isFinishedLaunching: Bool? = nil)
    {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.bundlePath = bundlePath
        self.isActive = isActive
        self.isHidden = isHidden
        self.windowCount = windowCount
        self.windowIDs = windowIDs
        self.activationPolicy = activationPolicy
        self.isFinishedLaunching = isFinishedLaunching
    }

    public var processIdentity: ApplicationProcessIdentity? {
        self.processStartIdentity.map {
            ApplicationProcessIdentity(
                processIdentifier: self.processIdentifier,
                processStartIdentity: $0)
        }
    }
}

public enum ServiceApplicationActivationPolicy: String, Sendable, Codable, Equatable {
    case regular
    case accessory
    case prohibited
    case unknown
}

/// Information about a window for service layer
public enum WindowSharingState: Int, Codable, Sendable {
    case none = 0
    case readOnly = 1
    case readWrite = 2
}

/// Pins a destructive window mutation to one WindowServer ID and one process generation.
///
/// A numeric CGWindowID and PID can both be recycled. Callers must retain this receipt from the
/// window-selection result and hosts must revalidate its immutable capture-time bounds after
/// mutation admission and immediately before native dispatch. `isMinimized` is only a state hint;
/// it is never identity evidence.
public struct WindowMutationIdentity: Sendable, Codable, Equatable {
    public let windowID: Int
    public let ownerProcessIdentifier: Int32
    public let ownerProcessStartIdentity: UInt64
    public let capturedBounds: CGRect?
    public let isMinimized: Bool?

    public init(
        windowID: Int,
        ownerProcessIdentifier: Int32,
        ownerProcessStartIdentity: UInt64,
        capturedBounds: CGRect? = nil,
        isMinimized: Bool? = nil)
    {
        self.windowID = windowID
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.ownerProcessStartIdentity = ownerProcessStartIdentity
        self.capturedBounds = capturedBounds
        self.isMinimized = isMinimized
    }

    public func withMinimizedState(_ isMinimized: Bool) -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: self.windowID,
            ownerProcessIdentifier: self.ownerProcessIdentifier,
            ownerProcessStartIdentity: self.ownerProcessStartIdentity,
            capturedBounds: self.capturedBounds,
            isMinimized: isMinimized)
    }
}

public struct ServiceWindowInfo: Sendable, Codable, Equatable {
    /// Window identifier
    public let windowID: Int

    /// Window title
    public let title: String

    /// Window bounds in screen coordinates
    public let bounds: CGRect

    /// Whether the window is minimized
    public let isMinimized: Bool

    /// Whether the window is the main window
    public let isMainWindow: Bool

    /// Whether Accessibility reports this as the app's focused/key window
    public let isKeyWindow: Bool?

    /// Whether this is the key window of the frontmost application
    public let isFrontmost: Bool?

    /// Accessibility subrole, such as AXStandardWindow or AXDialog
    public let subrole: String?

    /// Window level (z-order)
    public let windowLevel: Int

    /// Alpha value (transparency)
    public let alpha: CGFloat

    /// Window index within the application (0 = frontmost)
    public let index: Int

    /// Space (virtual desktop) ID this window belongs to
    public let spaceID: UInt64?

    /// Human-readable name of the Space (if available)
    public let spaceName: String?

    /// Screen index (position in NSScreen.screens array)
    public let screenIndex: Int?

    /// Screen name (e.g., "Built-in Display", "LG UltraFine")
    public let screenName: String?

    /// Whether the window is off-screen
    public let isOffScreen: Bool

    /// CG window layer (0 == standard app window)
    public let layer: Int

    /// Whether CoreGraphics reports the window as on-screen
    public let isOnScreen: Bool

    /// Sharing state exposed by AppKit/CoreGraphics
    public let sharingState: WindowSharingState?

    /// Whether our own NSWindow asked to hide from the Windows menu
    public let isExcludedFromWindowsMenu: Bool

    /// Process-generation receipt captured with this listing for later destructive mutations.
    public let mutationIdentity: WindowMutationIdentity?

    enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case title
        case bounds
        case isMinimized
        case isMainWindow
        case isKeyWindow
        case isFrontmost
        case subrole
        case windowLevel
        case alpha
        case index
        case spaceID
        case spaceName
        case screenIndex
        case screenName
        case isOffScreen
        case layer
        case isOnScreen
        case sharingState
        case isExcludedFromWindowsMenu
        case mutationIdentity
    }

    public init(
        windowID: Int,
        title: String,
        bounds: CGRect,
        isMinimized: Bool = false,
        isMainWindow: Bool = false,
        isKeyWindow: Bool? = nil,
        isFrontmost: Bool? = nil,
        subrole: String? = nil,
        windowLevel: Int = 0,
        alpha: CGFloat = 1.0,
        index: Int = 0,
        spaceID: UInt64? = nil,
        spaceName: String? = nil,
        screenIndex: Int? = nil,
        screenName: String? = nil,
        isOffScreen: Bool = false,
        layer: Int = 0,
        isOnScreen: Bool = true,
        sharingState: WindowSharingState? = nil,
        isExcludedFromWindowsMenu: Bool = false,
        mutationIdentity: WindowMutationIdentity? = nil)
    {
        self.windowID = windowID
        self.title = title
        self.bounds = bounds
        self.isMinimized = isMinimized
        self.isMainWindow = isMainWindow
        self.isKeyWindow = isKeyWindow
        self.isFrontmost = isFrontmost
        self.subrole = subrole
        self.windowLevel = windowLevel
        self.alpha = alpha
        self.index = index
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.screenIndex = screenIndex
        self.screenName = screenName
        self.isOffScreen = isOffScreen
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.sharingState = sharingState
        self.isExcludedFromWindowsMenu = isExcludedFromWindowsMenu
        self.mutationIdentity = mutationIdentity
    }

    public var isShareableWindow: Bool {
        guard let sharingState else {
            return true
        }
        return sharingState != .none
    }
}
