import CoreGraphics
import Foundation

/// UI automation snapshot data for storing captured screen state and element information.
public nonisolated struct UIAutomationSnapshot: Codable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    /// PID of the process that created the snapshot (e.g. `peekaboo` CLI, a host menubar app).
    public var creatorProcessId: Int32?
    public var screenshotPath: String?
    public var annotatedPath: String?
    public var uiMap: [String: UIElement]
    public var lastUpdateTime: Date
    public var applicationName: String?
    public var applicationBundleId: String?
    public var applicationProcessId: Int32?
    public var windowTitle: String?
    public var windowBounds: CGRect?
    public var windowMutationIdentity: WindowMutationIdentity?
    public var focusedElement: FocusedElementIdentity?
    public var captureCoordinateContext: CaptureCoordinateContext?
    public var menuBar: MenuBarData?
    public var windowID: CGWindowID?
    public var windowAXIdentifier: String?
    public var lastFocusTime: Date?

    public init(
        version: Int = UIAutomationSnapshot.currentVersion,
        creatorProcessId: Int32? = nil,
        screenshotPath: String? = nil,
        annotatedPath: String? = nil,
        uiMap: [String: UIElement] = [:],
        lastUpdateTime: Date = Date(),
        applicationName: String? = nil,
        applicationBundleId: String? = nil,
        applicationProcessId: Int32? = nil,
        windowTitle: String? = nil,
        windowBounds: CGRect? = nil,
        windowMutationIdentity: WindowMutationIdentity? = nil,
        focusedElement: FocusedElementIdentity? = nil,
        captureCoordinateContext: CaptureCoordinateContext? = nil,
        menuBar: MenuBarData? = nil,
        windowID: CGWindowID? = nil,
        windowAXIdentifier: String? = nil,
        lastFocusTime: Date? = nil)
    {
        self.version = version
        self.creatorProcessId = creatorProcessId
        self.screenshotPath = screenshotPath
        self.annotatedPath = annotatedPath
        self.uiMap = uiMap
        self.lastUpdateTime = lastUpdateTime
        self.applicationName = applicationName
        self.applicationBundleId = applicationBundleId
        self.applicationProcessId = applicationProcessId
        self.windowTitle = windowTitle
        self.windowBounds = windowBounds
        self.windowMutationIdentity = windowMutationIdentity
        self.focusedElement = focusedElement
        self.captureCoordinateContext = captureCoordinateContext
        self.menuBar = menuBar
        self.windowID = windowID
        self.windowAXIdentifier = windowAXIdentifier
        self.lastFocusTime = lastFocusTime
    }
}

/// UI element information stored in snapshot
public nonisolated struct UIElement: Codable, Sendable {
    public let id: String
    public let elementId: String
    public let role: String
    public let title: String?
    public let label: String?
    public let value: String?
    public let description: String?
    public let help: String?
    public let roleDescription: String?
    public let identifier: String?
    public let confidence: Double?
    public var frame: CGRect
    public let isActionable: Bool
    public let isEnabled: Bool?
    public let isSelected: Bool?
    public let isValueSettable: Bool?
    public let parentId: String?
    public let children: [String]
    public let keyboardShortcut: String?

    public var isOCRSemanticEvidence: Bool {
        OCRSemanticEvidencePolicy.isSemanticEvidence(
            id: self.id,
            isStaticText: self.role.caseInsensitiveCompare("AXStaticText") == .orderedSame ||
                self.role.caseInsensitiveCompare("staticText") == .orderedSame,
            isActionable: self.isActionable,
            description: self.description)
    }

    public init(
        id: String,
        elementId: String,
        role: String,
        title: String? = nil,
        label: String? = nil,
        value: String? = nil,
        description: String? = nil,
        help: String? = nil,
        roleDescription: String? = nil,
        identifier: String? = nil,
        confidence: Double? = nil,
        frame: CGRect,
        isActionable: Bool,
        isEnabled: Bool? = nil,
        isSelected: Bool? = nil,
        isValueSettable: Bool? = nil,
        parentId: String? = nil,
        children: [String] = [],
        keyboardShortcut: String? = nil)
    {
        self.id = id
        self.elementId = elementId
        self.role = role
        self.title = title
        self.label = label
        self.value = value
        self.description = description
        self.help = help
        self.roleDescription = roleDescription
        self.identifier = identifier
        self.confidence = confidence
        self.frame = frame
        self.isActionable = isActionable
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.isValueSettable = isValueSettable
        self.parentId = parentId
        self.children = children
        self.keyboardShortcut = keyboardShortcut
    }
}

/// Menu bar information
public nonisolated struct MenuBarData: Codable, Sendable {
    public let menus: [Menu]

    public init(menus: [Menu]) {
        self.menus = menus
    }

    public struct Menu: Codable, Sendable {
        public let title: String
        public let items: [MenuItem]
        public let enabled: Bool

        public init(title: String, items: [MenuItem], enabled: Bool) {
            self.title = title
            self.items = items
            self.enabled = enabled
        }
    }

    public struct MenuItem: Codable, Sendable {
        public let title: String
        public let enabled: Bool
        public let hasSubmenu: Bool
        public let keyboardShortcut: String?
        public let items: [MenuItem]?

        public init(
            title: String,
            enabled: Bool,
            hasSubmenu: Bool,
            keyboardShortcut: String? = nil,
            items: [MenuItem]? = nil)
        {
            self.title = title
            self.enabled = enabled
            self.hasSubmenu = hasSubmenu
            self.keyboardShortcut = keyboardShortcut
            self.items = items
        }
    }
}

/// Snapshot storage error types
public enum SnapshotError: LocalizedError, Sendable {
    case invalidSnapshotReference(String)
    case snapshotNotFound
    case noValidSnapshotFound
    case versionMismatch(found: Int, expected: Int)
    case corruptedData
    case storageError(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidSnapshotReference(reference):
            "Invalid snapshot reference '\(reference)'; expected ps1_ followed by 32 lowercase hexadecimal digits"
        case .snapshotNotFound:
            "Snapshot not found or expired"
        case .noValidSnapshotFound:
            "No valid snapshot found. Create a new snapshot first."
        case let .versionMismatch(found, expected):
            "Snapshot version mismatch (found: \(found), expected: \(expected))"
        case .corruptedData:
            "Snapshot data is corrupted"
        case let .storageError(reason):
            "Storage error: \(reason)"
        }
    }
}
