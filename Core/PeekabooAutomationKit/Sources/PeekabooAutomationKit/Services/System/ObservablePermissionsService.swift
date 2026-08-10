import Foundation
import Observation
import os.log

@MainActor
public protocol ObservablePermissionsServiceProtocol: AnyObject {
    var screenRecordingStatus: ObservablePermissionsService.PermissionState { get }
    var accessibilityStatus: ObservablePermissionsService.PermissionState { get }
    var appleScriptStatus: ObservablePermissionsService.PermissionState { get }
    var postEventStatus: ObservablePermissionsService.PermissionState { get }
    var hasAllPermissions: Bool { get }
    /// Refresh permission states, optionally including Event Synthesizing.
    func checkPermissions(includeOptionalPermissions: Bool, forceScreenRecordingProbe: Bool) async
    /// Trigger the screen recording permission prompt if needed.
    func requestScreenRecording() async
    /// Trigger the accessibility permission prompt if needed.
    func requestAccessibility() async
    /// Legacy source-compatible no-op; current Peekaboo operations do not use AppleScript.
    @available(*, deprecated, message: "Peekaboo no longer uses AppleScript automation")
    func requestAppleScript() async
    /// Trigger the event-synthesizing permission prompt if needed.
    func requestPostEvent() async
}

/// Observable wrapper for PermissionsService that provides UI-friendly state management
@available(macOS 14.0, *)
@Observable
@MainActor
public final class ObservablePermissionsService: ObservablePermissionsServiceProtocol {
    // MARK: - Properties

    /// Core permissions service
    private let core: PermissionsService

    /// Current permission status
    public private(set) var status: PermissionsStatus

    /// Individual permission states for UI binding
    public private(set) var screenRecordingStatus: PermissionState = .notDetermined
    public private(set) var accessibilityStatus: PermissionState = .notDetermined
    public private(set) var appleScriptStatus: PermissionState = .notDetermined
    public private(set) var postEventStatus: PermissionState = .notDetermined

    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "ObservablePermissions")

    // MARK: - Permission State

    public enum PermissionState: String, Sendable {
        case notDetermined
        case denied
        case authorized

        public var displayName: String {
            switch self {
            case .notDetermined: "Not Determined"
            case .denied: "Denied"
            case .authorized: "Authorized"
            }
        }
    }

    // MARK: - Initialization

    @MainActor
    public init(core: PermissionsService = PermissionsService()) {
        self.core = core
        self.status = core.checkAllPermissions()
        self.updatePermissionStates()
    }

    // MARK: - Public Methods

    /// Check permissions and update state.
    public func checkPermissions(
        includeOptionalPermissions: Bool = true,
        forceScreenRecordingProbe: Bool = false) async
    {
        self.logger.debug("Checking all permissions")
        let screenRecording = await self.core.checkScreenRecordingPermissionLive(forceProbe: forceScreenRecordingProbe)
        let accessibility = self.core.checkAccessibilityPermission()
        let postEvent = includeOptionalPermissions
            ? self.core.checkPostEventPermission()
            : self.status.postEvent
        self.status = PermissionsStatus(
            screenRecording: screenRecording,
            accessibility: accessibility,
            appleScript: self.status.appleScript,
            postEvent: postEvent)
        self.updatePermissionStates()
    }

    /// Request screen recording permission
    public func requestScreenRecording() async {
        let granted = self.core.requestScreenRecordingPermission(interactive: true)
        self.updateStatus(screenRecording: granted)
        await self.checkPermissions(includeOptionalPermissions: false, forceScreenRecordingProbe: true)
    }

    /// Request accessibility permission
    public func requestAccessibility() async {
        let granted = self.core.requestAccessibilityPermission(interactive: true)
        self.updateStatus(accessibility: granted)
        await self.checkPermissions(includeOptionalPermissions: false, forceScreenRecordingProbe: true)
    }

    /// Legacy source-compatible no-op; it never probes, prompts, or launches a target application.
    @available(*, deprecated, message: "Peekaboo no longer uses AppleScript automation")
    public func requestAppleScript() async {
        self.updateStatus(appleScript: false)
    }

    /// Request event-synthesizing permission
    public func requestPostEvent() async {
        let granted = self.core.requestPostEventPermission(interactive: true)
        self.updateStatus(postEvent: granted)
        await self.checkPermissions(includeOptionalPermissions: true, forceScreenRecordingProbe: true)
    }

    /// Check if all permissions are granted
    public var hasAllPermissions: Bool {
        self.status.allGranted
    }

    /// Get list of missing permissions
    public var missingPermissions: [String] {
        self.status.missingPermissions
    }

    // MARK: - Private Methods

    private func updatePermissionStates() {
        self.screenRecordingStatus = self.status.screenRecording ? .authorized : .denied
        self.accessibilityStatus = self.status.accessibility ? .authorized : .denied
        self.appleScriptStatus = self.status.appleScript ? .authorized : .denied
        self.postEventStatus = self.status.postEvent ? .authorized : .denied
    }

    private func updateStatus(
        screenRecording: Bool? = nil,
        accessibility: Bool? = nil,
        appleScript: Bool? = nil,
        postEvent: Bool? = nil)
    {
        self.status = PermissionsStatus(
            screenRecording: screenRecording ?? self.status.screenRecording,
            accessibility: accessibility ?? self.status.accessibility,
            appleScript: appleScript ?? self.status.appleScript,
            postEvent: postEvent ?? self.status.postEvent)
        self.updatePermissionStates()
    }
}

// MARK: - Convenience Extensions

extension ObservablePermissionsService {
    /// Permission display information
    public struct PermissionInfo {
        public let type: PermissionType
        public let status: PermissionState
        public let displayName: String
        public let explanation: String
        public let settingsURL: URL?

        public enum PermissionType: String, CaseIterable {
            case screenRecording
            case accessibility
            case appleScript
            case postEvent

            public var displayName: String {
                switch self {
                case .screenRecording: "Screen Recording"
                case .accessibility: "Accessibility"
                case .appleScript: "AppleScript"
                case .postEvent: "Event Synthesizing"
                }
            }

            public var explanation: String {
                switch self {
                case .screenRecording:
                    "Required to capture screenshots and analyze screen content"
                case .accessibility:
                    "Required to interact with UI elements and send input events"
                case .appleScript:
                    "Legacy compatibility only; current Peekaboo operations use native macOS APIs"
                case .postEvent:
                    "Required to send background hotkeys to a target process"
                }
            }

            public var settingsURLString: String {
                switch self {
                case .screenRecording:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                case .accessibility:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                case .appleScript:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                case .postEvent:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                }
            }
        }
    }

    /// Get all permission information for UI display
    public var allPermissions: [PermissionInfo] {
        [
            PermissionInfo(
                type: .screenRecording,
                status: self.screenRecordingStatus,
                displayName: PermissionInfo.PermissionType.screenRecording.displayName,
                explanation: PermissionInfo.PermissionType.screenRecording.explanation,
                settingsURL: URL(string: PermissionInfo.PermissionType.screenRecording.settingsURLString)),
            PermissionInfo(
                type: .accessibility,
                status: self.accessibilityStatus,
                displayName: PermissionInfo.PermissionType.accessibility.displayName,
                explanation: PermissionInfo.PermissionType.accessibility.explanation,
                settingsURL: URL(string: PermissionInfo.PermissionType.accessibility.settingsURLString)),
            PermissionInfo(
                type: .postEvent,
                status: self.postEventStatus,
                displayName: PermissionInfo.PermissionType.postEvent.displayName,
                explanation: PermissionInfo.PermissionType.postEvent.explanation,
                settingsURL: URL(string: PermissionInfo.PermissionType.postEvent.settingsURLString)),
        ]
    }
}
