import CoreGraphics
import Foundation
import PeekabooFoundation

/// Result of element detection
public struct ElementDetectionResult: Sendable, Codable {
    /// Unique snapshot identifier
    public let snapshotId: String

    /// Path to the annotated screenshot
    public let screenshotPath: String

    /// Detected UI elements organized by type
    public let elements: DetectedElements

    /// Detection metadata
    public let metadata: DetectionMetadata

    public init(
        snapshotId: String,
        screenshotPath: String,
        elements: DetectedElements,
        metadata: DetectionMetadata)
    {
        self.snapshotId = snapshotId
        self.screenshotPath = screenshotPath
        self.elements = elements
        self.metadata = metadata
    }
}

/// Container for detected UI elements by type
public struct DetectedElements: Sendable, Codable {
    public let buttons: [DetectedElement]
    public let textFields: [DetectedElement]
    public let links: [DetectedElement]
    public let images: [DetectedElement]
    public let groups: [DetectedElement]
    public let sliders: [DetectedElement]
    public let checkboxes: [DetectedElement]
    public let menus: [DetectedElement]
    public let other: [DetectedElement]

    /// All elements as a flat array
    public var all: [DetectedElement] {
        self.buttons + self.textFields + self.links + self.images + self.groups + self.sliders + self.checkboxes + self
            .menus + self.other
    }

    /// Find element by ID
    public func findById(_ id: String) -> DetectedElement? {
        // Find element by ID
        self.all.first { $0.id == id }
    }

    public init(
        buttons: [DetectedElement] = [],
        textFields: [DetectedElement] = [],
        links: [DetectedElement] = [],
        images: [DetectedElement] = [],
        groups: [DetectedElement] = [],
        sliders: [DetectedElement] = [],
        checkboxes: [DetectedElement] = [],
        menus: [DetectedElement] = [],
        other: [DetectedElement] = [])
    {
        self.buttons = buttons
        self.textFields = textFields
        self.links = links
        self.images = images
        self.groups = groups
        self.sliders = sliders
        self.checkboxes = checkboxes
        self.menus = menus
        self.other = other
    }
}

/// A detected UI element
public struct DetectedElement: Sendable, Codable {
    /// Opaque identifier returned by element detection.
    public let id: String

    /// Element type
    public let type: ElementType

    /// Display label or text
    public let label: String?

    /// Current value (for text fields, sliders, etc.)
    public let value: String?

    /// Bounding rectangle
    public let bounds: CGRect

    /// Whether the element is enabled
    public let isEnabled: Bool

    /// Whether the element is selected/checked
    public let isSelected: Bool?

    /// Additional attributes
    public let attributes: [String: String]

    public init(
        id: String,
        type: ElementType,
        label: String? = nil,
        value: String? = nil,
        bounds: CGRect,
        isEnabled: Bool = true,
        isSelected: Bool? = nil,
        attributes: [String: String] = [:])
    {
        self.id = id
        self.type = type
        self.label = label
        self.value = value
        self.bounds = bounds
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.attributes = attributes
    }
}

// ElementType is now in PeekabooFoundation

/// Window context information for element detection
public nonisolated struct WindowContext: Sendable, Codable {
    /// Application name
    public let applicationName: String?

    /// Bundle identifier (preferred for disambiguating same-named apps)
    public let applicationBundleId: String?

    /// Process identifier (most precise when available)
    public let applicationProcessId: Int32?

    /// Window title
    public let windowTitle: String?

    /// CGWindowID for the target window (most precise window selection when available)
    public let windowID: Int?

    /// Window bounds in screen coordinates
    public let windowBounds: CGRect?

    /// Whether element detection should attempt to focus embedded web content when inputs are missing
    public let shouldFocusWebContent: Bool?

    /// Optional traversal budget to constrain AX tree collection
    public let traversalBudget: AXTraversalBudget?

    public init(
        applicationName: String? = nil,
        applicationBundleId: String? = nil,
        applicationProcessId: Int32? = nil,
        windowTitle: String? = nil,
        windowID: Int? = nil,
        windowBounds: CGRect? = nil,
        shouldFocusWebContent: Bool? = nil,
        traversalBudget: AXTraversalBudget?)
    {
        self.applicationName = applicationName
        self.applicationBundleId = applicationBundleId
        self.applicationProcessId = applicationProcessId
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.windowBounds = windowBounds
        self.shouldFocusWebContent = shouldFocusWebContent
        self.traversalBudget = traversalBudget
    }

    public init(
        applicationName: String? = nil,
        applicationBundleId: String? = nil,
        applicationProcessId: Int32? = nil,
        windowTitle: String? = nil,
        windowID: Int? = nil,
        windowBounds: CGRect? = nil,
        shouldFocusWebContent: Bool? = nil)
    {
        self.init(
            applicationName: applicationName,
            applicationBundleId: applicationBundleId,
            applicationProcessId: applicationProcessId,
            windowTitle: windowTitle,
            windowID: windowID,
            windowBounds: windowBounds,
            shouldFocusWebContent: shouldFocusWebContent,
            traversalBudget: nil)
    }
}

/// Metadata about element detection
public struct DetectionMetadata: Sendable, Codable {
    /// Time taken for detection
    public let detectionTime: TimeInterval

    /// Number of elements detected
    public let elementCount: Int

    /// Detection method used
    public let method: String

    /// Any warnings during detection
    public let warnings: [String]

    /// Window context information (if available)
    public let windowContext: WindowContext?

    /// Whether a dialog was captured instead of a regular window
    public let isDialog: Bool

    /// Truncation metadata if traversal budgets were reached
    public let truncationInfo: DetectionTruncationInfo?

    /// Host-confirmed completion boundary for focus-capable bridge detection.
    public let desktopMutationCompletedAt: Date?

    /// Whether no overlapping desktop mutation invalidated this observation before publication.
    public let desktopMutationPreservationAllowed: Bool?

    private enum CodingKeys: String, CodingKey {
        case detectionTime
        case elementCount
        case method
        case warnings
        case windowContext
        case isDialog
        case truncationInfo
        case desktopMutationCompletedAt
        case desktopMutationCompletedAtReferenceDateSeconds
        case desktopMutationPreservationAllowed
    }

    public init(
        detectionTime: TimeInterval,
        elementCount: Int,
        method: String,
        warnings: [String] = [],
        windowContext: WindowContext? = nil,
        isDialog: Bool = false,
        truncationInfo: DetectionTruncationInfo?,
        desktopMutationCompletedAt: Date? = nil,
        desktopMutationPreservationAllowed: Bool? = nil)
    {
        self.detectionTime = detectionTime
        self.elementCount = elementCount
        self.method = method
        self.warnings = warnings
        self.windowContext = windowContext
        self.isDialog = isDialog
        self.truncationInfo = truncationInfo
        self.desktopMutationCompletedAt = desktopMutationCompletedAt
        self.desktopMutationPreservationAllowed = desktopMutationPreservationAllowed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.detectionTime = try container.decode(TimeInterval.self, forKey: .detectionTime)
        self.elementCount = try container.decode(Int.self, forKey: .elementCount)
        self.method = try container.decode(String.self, forKey: .method)
        self.warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        self.windowContext = try container.decodeIfPresent(WindowContext.self, forKey: .windowContext)
        self.isDialog = try container.decodeIfPresent(Bool.self, forKey: .isDialog) ?? false
        self.truncationInfo = try container.decodeIfPresent(
            DetectionTruncationInfo.self,
            forKey: .truncationInfo)
        if let seconds = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .desktopMutationCompletedAtReferenceDateSeconds)
        {
            self.desktopMutationCompletedAt = Date(timeIntervalSinceReferenceDate: seconds)
        } else {
            self.desktopMutationCompletedAt = try container.decodeIfPresent(
                Date.self,
                forKey: .desktopMutationCompletedAt)
        }
        self.desktopMutationPreservationAllowed = try container.decodeIfPresent(
            Bool.self,
            forKey: .desktopMutationPreservationAllowed)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.detectionTime, forKey: .detectionTime)
        try container.encode(self.elementCount, forKey: .elementCount)
        try container.encode(self.method, forKey: .method)
        try container.encode(self.warnings, forKey: .warnings)
        try container.encodeIfPresent(self.windowContext, forKey: .windowContext)
        try container.encode(self.isDialog, forKey: .isDialog)
        try container.encodeIfPresent(self.truncationInfo, forKey: .truncationInfo)
        try container.encodeIfPresent(
            self.desktopMutationCompletedAt?.timeIntervalSinceReferenceDate,
            forKey: .desktopMutationCompletedAtReferenceDateSeconds)
        try container.encodeIfPresent(
            self.desktopMutationPreservationAllowed,
            forKey: .desktopMutationPreservationAllowed)
    }

    public init(
        detectionTime: TimeInterval,
        elementCount: Int,
        method: String,
        warnings: [String] = [],
        windowContext: WindowContext? = nil,
        isDialog: Bool = false)
    {
        self.init(
            detectionTime: detectionTime,
            elementCount: elementCount,
            method: method,
            warnings: warnings,
            windowContext: windowContext,
            isDialog: isDialog,
            truncationInfo: nil)
    }
}
