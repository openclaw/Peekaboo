import Darwin
import Foundation
import PeekabooAutomationKit

public struct PeekabooBridgeProtocolVersion: Codable, Sendable, Comparable, Hashable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: PeekabooBridgeProtocolVersion, rhs: PeekabooBridgeProtocolVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        return lhs.minor < rhs.minor
    }
}

public enum PeekabooBridgeHostKind: String, Codable, Sendable, CaseIterable {
    case gui
    case helper
    case onDemand
    case inProcess
}

public enum PeekabooBridgePermissionKind: String, Codable, Sendable {
    case screenRecording
    case accessibility
    case postEvent
    case appleScript
}

public enum PeekabooBridgeOperation: String, Codable, Sendable, CaseIterable, Hashable {
    // Core
    case permissionsStatus
    case requestPostEventPermission
    case daemonStatus
    case daemonStop
    // Browser MCP
    case browserStatus
    case browserConnect
    case browserDisconnect
    case browserExecute
    // Capture
    case captureScreen
    case captureWindow
    case captureFrontmost
    case captureArea
    case detectElements
    case inspectAccessibilityTree
    case desktopObservation
    // Input & automation
    case click
    case type
    case typeActions
    case targetedTypeActions
    case setValue
    case performAction
    case scroll
    case hotkey
    case targetedHotkey
    case targetedClick
    case exactWindowTargetedClick
    case swipe
    case drag
    case moveMouse
    case waitForElement
    // Windows
    case listWindows
    case focusWindow
    case moveWindow
    case resizeWindow
    case setWindowBounds
    case closeWindow
    case minimizeWindow
    case maximizeWindow
    case getFocusedWindow
    // Applications
    case listApplications
    case findApplication
    case getFrontmostApplication
    case isApplicationRunning
    case launchApplication
    case launchApplicationWithOptions
    case relaunchApplicationWithOptions
    case activateApplication
    case quitApplication
    case hideApplication
    case unhideApplication
    case hideOtherApplications
    case showAllApplications
    // Menus
    case listMenus
    case listFrontmostMenus
    case clickMenuItem
    case clickMenuItemByName
    // Menu bar extras
    case listMenuExtras
    case clickMenuExtra
    case menuExtraOpenMenuFrame
    case listMenuBarItems
    case clickMenuBarItemNamed
    case clickMenuBarItemIndex
    // Dock
    case listDockItems
    case launchDockItem
    case rightClickDockItem
    case hideDock
    case showDock
    case isDockHidden
    case findDockItem
    // Dialogs
    case dialogFindActive
    case dialogClickButton
    case dialogEnterText
    case dialogHandleFile
    case dialogDismiss
    case dialogListElements
    // Snapshots/cache
    case createSnapshot
    case storeDetectionResult
    case getDetectionResult
    case storeScreenshot
    case storeAnnotatedScreenshot
    case listSnapshots
    case getMostRecentSnapshot
    case invalidateImplicitLatestSnapshot
    case cleanSnapshot
    case cleanSnapshotsOlderThan
    case cleanAllSnapshots
    case _appleScriptProbe

    /// Filters operations to cases a peer at `version` can decode.
    public static func compatible(
        _ operations: Set<Self>,
        with version: PeekabooBridgeProtocolVersion) -> Set<Self>
    {
        var compatible = operations
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 1) {
            compatible.remove(.targetedHotkey)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 2) {
            compatible.remove(.requestPostEventPermission)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 3) {
            compatible.remove(.setValue)
            compatible.remove(.performAction)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 4) {
            compatible.remove(.browserStatus)
            compatible.remove(.browserConnect)
            compatible.remove(.browserDisconnect)
            compatible.remove(.browserExecute)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 5) {
            compatible.remove(.desktopObservation)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 6) {
            compatible.remove(.targetedClick)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 7) {
            compatible.remove(.inspectAccessibilityTree)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 8) {
            compatible.remove(.targetedTypeActions)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 9) {
            compatible.remove(.launchApplicationWithOptions)
            compatible.remove(.relaunchApplicationWithOptions)
            compatible.remove(.invalidateImplicitLatestSnapshot)
            compatible.remove(.exactWindowTargetedClick)
        }
        return compatible
    }
}

public struct PeekabooBridgeClientIdentity: Codable, Sendable {
    public let bundleIdentifier: String?
    public let teamIdentifier: String?
    public let processIdentifier: pid_t
    public let hostname: String?

    public init(
        bundleIdentifier: String?,
        teamIdentifier: String?,
        processIdentifier: pid_t,
        hostname: String? = nil)
    {
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.processIdentifier = processIdentifier
        self.hostname = hostname
    }
}

public struct PeekabooBridgeHandshake: Codable, Sendable {
    public let protocolVersion: PeekabooBridgeProtocolVersion
    public let client: PeekabooBridgeClientIdentity
    public let requestedHostKind: PeekabooBridgeHostKind?

    public init(
        protocolVersion: PeekabooBridgeProtocolVersion,
        client: PeekabooBridgeClientIdentity,
        requestedHostKind: PeekabooBridgeHostKind? = nil)
    {
        self.protocolVersion = protocolVersion
        self.client = client
        self.requestedHostKind = requestedHostKind
    }
}

public struct PeekabooBridgeHandshakeResponse: Codable, Sendable {
    public let negotiatedVersion: PeekabooBridgeProtocolVersion
    public let hostKind: PeekabooBridgeHostKind
    public let build: String?
    public let supportedOperations: [PeekabooBridgeOperation]
    /// Current permission status of the host process (TCC grants).
    public let permissions: PermissionsStatus?
    /// Operations that are currently enabled given the host's permission status.
    public let enabledOperations: [PeekabooBridgeOperation]?
    /// Map of operation rawValue to the permissions it requires so clients can surface missing grants.
    public let permissionTags: [String: [PeekabooBridgePermissionKind]]

    public init(
        negotiatedVersion: PeekabooBridgeProtocolVersion,
        hostKind: PeekabooBridgeHostKind,
        build: String?,
        supportedOperations: [PeekabooBridgeOperation],
        permissions: PermissionsStatus? = nil,
        enabledOperations: [PeekabooBridgeOperation]? = nil,
        permissionTags: [String: [PeekabooBridgePermissionKind]] = [:])
    {
        self.negotiatedVersion = negotiatedVersion
        self.hostKind = hostKind
        self.build = build
        self.supportedOperations = supportedOperations
        self.permissions = permissions
        self.enabledOperations = enabledOperations
        self.permissionTags = permissionTags
    }

    private enum CodingKeys: String, CodingKey {
        case negotiatedVersion
        case hostKind
        case build
        case supportedOperations
        case permissions
        case enabledOperations
        case permissionTags
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.negotiatedVersion = try container.decode(PeekabooBridgeProtocolVersion.self, forKey: .negotiatedVersion)
        self.hostKind = try container.decode(PeekabooBridgeHostKind.self, forKey: .hostKind)
        self.build = try container.decodeIfPresent(String.self, forKey: .build)
        self.supportedOperations = try container.decode([PeekabooBridgeOperation].self, forKey: .supportedOperations)
        self.permissions = try container.decodeIfPresent(PermissionsStatus.self, forKey: .permissions)
        self.enabledOperations = try container.decodeIfPresent(
            [PeekabooBridgeOperation].self,
            forKey: .enabledOperations)
        self.permissionTags = try container.decodeIfPresent(
            [String: [PeekabooBridgePermissionKind]].self,
            forKey: .permissionTags) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.negotiatedVersion, forKey: .negotiatedVersion)
        try container.encode(self.hostKind, forKey: .hostKind)
        try container.encodeIfPresent(self.build, forKey: .build)
        try container.encode(self.supportedOperations, forKey: .supportedOperations)
        try container.encodeIfPresent(self.permissions, forKey: .permissions)
        try container.encodeIfPresent(self.enabledOperations, forKey: .enabledOperations)
        if !self.permissionTags.isEmpty {
            try container.encode(self.permissionTags, forKey: .permissionTags)
        }
    }
}

public enum PeekabooBridgeErrorCode: String, Codable, Sendable {
    case permissionDenied
    case notFound
    case timeout
    case invalidRequest
    case operationNotSupported
    case serverBusy
    case versionMismatch
    case unauthorizedClient
    case decodingFailed
    case internalError
}

public enum PeekabooBridgeErrorKind: String, Codable, Sendable {
    case elementNotFound
    case snapshotNotFound
    case snapshotStale
}

public struct PeekabooBridgeErrorEnvelope: Codable, Sendable, LocalizedError {
    public let code: PeekabooBridgeErrorCode
    public let message: String
    public let details: String?
    public let permission: PeekabooBridgePermissionKind?
    public let kind: PeekabooBridgeErrorKind?
    public let context: String?
    public let operationMayHaveCompleted: Bool

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case details
        case permission
        case kind
        case context
        case operationMayHaveCompleted
    }

    public init(
        code: PeekabooBridgeErrorCode,
        message: String,
        details: String? = nil,
        permission: PeekabooBridgePermissionKind? = nil,
        kind: PeekabooBridgeErrorKind? = nil,
        context: String? = nil,
        operationMayHaveCompleted: Bool = false)
    {
        self.code = code
        self.message = message
        self.details = details
        self.permission = permission
        self.kind = kind
        self.context = context
        self.operationMayHaveCompleted = operationMayHaveCompleted
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decode(PeekabooBridgeErrorCode.self, forKey: .code)
        self.message = try container.decode(String.self, forKey: .message)
        self.details = try container.decodeIfPresent(String.self, forKey: .details)
        self.permission = try container.decodeIfPresent(PeekabooBridgePermissionKind.self, forKey: .permission)
        self.context = try container.decodeIfPresent(String.self, forKey: .context)
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind)
        self.kind = rawKind.flatMap(PeekabooBridgeErrorKind.init(rawValue:))
        self.operationMayHaveCompleted = try container.decodeIfPresent(
            Bool.self,
            forKey: .operationMayHaveCompleted) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.code, forKey: .code)
        try container.encode(self.message, forKey: .message)
        try container.encodeIfPresent(self.details, forKey: .details)
        try container.encodeIfPresent(self.permission, forKey: .permission)
        try container.encodeIfPresent(self.kind?.rawValue, forKey: .kind)
        try container.encodeIfPresent(self.context, forKey: .context)
        if self.operationMayHaveCompleted {
            try container.encode(true, forKey: .operationMayHaveCompleted)
        }
    }

    public var errorDescription: String? {
        self.message
    }
}

extension PeekabooBridgeErrorEnvelope: PendingSnapshotFailureDispositionProviding {
    public var mayCompleteSnapshotWorkAfterFailure: Bool {
        if self.operationMayHaveCompleted {
            return true
        }
        return switch self.code {
        case .timeout:
            true
        case .internalError:
            self.message == "Bridge host returned no response"
        case .decodingFailed:
            self.message == "Bridge host returned an invalid response"
        default:
            false
        }
    }
}
