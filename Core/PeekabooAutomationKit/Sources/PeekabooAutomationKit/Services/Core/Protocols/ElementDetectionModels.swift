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

    /// Whether the enabled element exposes an actionable control surface.
    /// Explicit AX action metadata wins; older/synthetic elements retain the role-based fallback.
    public var isActionable: Bool {
        guard self.knownIsEnabled != false else { return false }
        if self.isValueSettable == true {
            return true
        }
        if let explicit = self.attributes["isActionable"] {
            return explicit == "true"
        }
        switch self.type {
        case .button, .textField, .link, .slider, .checkbox, .menu, .radioButton, .menuItem:
            return true
        case .image, .group, .staticText, .window, .dialog, .other:
            return false
        }
    }

    public var isValueSettable: Bool? {
        self.attributes["isValueSettable"].flatMap(Bool.init)
    }

    /// The element's per-window Accessibility focus state at observation time.
    public var isFocused: Bool? {
        self.attributes["isFocused"].flatMap(Bool.init)
    }

    public var isOCRSemanticEvidence: Bool {
        OCRSemanticEvidencePolicy.isSemanticEvidence(
            id: self.id,
            isStaticText: self.type == .staticText,
            isActionable: self.isActionable,
            description: self.attributes["description"],
            source: self.attributes["source"])
    }

    public var knownIsEnabled: Bool? {
        guard let enabledKnown = self.attributes["axEnabledKnown"] else {
            return self.isEnabled
        }
        return enabledKnown == "true" ? self.isEnabled : nil
    }

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

public enum OCRSemanticEvidencePolicy {
    public static let interactionRefusalMessage =
        "OCR text is semantic evidence, not an actionable element. Use explicit coordinates with the exact " +
        "snapshot/reference receipt when a pixel action is intentional."

    public static func isSemanticEvidence(
        id: String,
        isStaticText: Bool,
        isActionable: Bool,
        description: String?,
        source: String? = nil) -> Bool
    {
        if source?.caseInsensitiveCompare("ocr") == .orderedSame {
            return true
        }
        return id.lowercased().hasPrefix("ocr_") &&
            isStaticText &&
            !isActionable &&
            description?.caseInsensitiveCompare("ocr") == .orderedSame
    }
}

// ElementType is now in PeekabooFoundation

/// Window context information for element detection
public nonisolated struct WindowContext: Sendable, Codable {
    /// Application name
    public let applicationName: String?

    /// Bundle identifier (preferred for disambiguating same-named apps)
    public let applicationBundleId: String?

    /// Canonical bundle path of the resolved application.
    public let applicationBundlePath: String?

    /// Canonical executable path of the resolved application.
    public let applicationExecutablePath: String?

    /// Process identifier (most precise when available)
    public let applicationProcessId: Int32?

    /// Window title
    public let windowTitle: String?

    /// CGWindowID for the target window (most precise window selection when available)
    public let windowID: Int?

    /// Window bounds in screen coordinates
    public let windowBounds: CGRect?

    /// Process-generation receipt captured with the observed window.
    /// An exact context without this capture-time receipt is observation-only and must not be used for actions.
    public let windowMutationIdentity: WindowMutationIdentity?

    /// Exact non-value-bearing identity of the sole element that reported AXFocused=true in this window.
    public let focusedElement: FocusedElementIdentity?

    /// Whether element detection should attempt to focus embedded web content when inputs are missing
    public let shouldFocusWebContent: Bool?

    /// Whether detection should append the application's menu-bar accessibility tree
    public let includeMenuBarElements: Bool?

    /// Optional traversal budget to constrain AX tree collection
    public let traversalBudget: AXTraversalBudget?

    /// Whether the caller requires a fresh AX traversal instead of the short-lived tree cache.
    public let requiresFreshAccessibilityTree: Bool?

    /// Optional caller deadline for the AX traversal itself.
    public let accessibilityTimeoutSeconds: TimeInterval?

    public init(
        applicationName: String? = nil,
        applicationBundleId: String? = nil,
        applicationBundlePath: String? = nil,
        applicationExecutablePath: String? = nil,
        applicationProcessId: Int32? = nil,
        windowTitle: String? = nil,
        windowID: Int? = nil,
        windowBounds: CGRect? = nil,
        windowMutationIdentity: WindowMutationIdentity? = nil,
        focusedElement: FocusedElementIdentity? = nil,
        shouldFocusWebContent: Bool? = nil,
        includeMenuBarElements: Bool? = nil,
        traversalBudget: AXTraversalBudget?,
        requiresFreshAccessibilityTree: Bool = false,
        accessibilityTimeoutSeconds: TimeInterval? = nil)
    {
        self.applicationName = applicationName
        self.applicationBundleId = applicationBundleId
        self.applicationBundlePath = applicationBundlePath
        self.applicationExecutablePath = applicationExecutablePath
        self.applicationProcessId = applicationProcessId
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.windowBounds = windowBounds
        self.windowMutationIdentity = windowMutationIdentity
        self.focusedElement = focusedElement
        self.shouldFocusWebContent = shouldFocusWebContent
        self.includeMenuBarElements = includeMenuBarElements
        self.traversalBudget = traversalBudget
        self.requiresFreshAccessibilityTree = requiresFreshAccessibilityTree
        self.accessibilityTimeoutSeconds = accessibilityTimeoutSeconds
    }

    public init(
        applicationName: String? = nil,
        applicationBundleId: String? = nil,
        applicationBundlePath: String? = nil,
        applicationExecutablePath: String? = nil,
        applicationProcessId: Int32? = nil,
        windowTitle: String? = nil,
        windowID: Int? = nil,
        windowBounds: CGRect? = nil,
        windowMutationIdentity: WindowMutationIdentity? = nil,
        focusedElement: FocusedElementIdentity? = nil,
        shouldFocusWebContent: Bool? = nil,
        includeMenuBarElements: Bool? = nil,
        requiresFreshAccessibilityTree: Bool = false,
        accessibilityTimeoutSeconds: TimeInterval? = nil)
    {
        self.init(
            applicationName: applicationName,
            applicationBundleId: applicationBundleId,
            applicationBundlePath: applicationBundlePath,
            applicationExecutablePath: applicationExecutablePath,
            applicationProcessId: applicationProcessId,
            windowTitle: windowTitle,
            windowID: windowID,
            windowBounds: windowBounds,
            windowMutationIdentity: windowMutationIdentity,
            focusedElement: focusedElement,
            shouldFocusWebContent: shouldFocusWebContent,
            includeMenuBarElements: includeMenuBarElements,
            traversalBudget: nil,
            requiresFreshAccessibilityTree: requiresFreshAccessibilityTree,
            accessibilityTimeoutSeconds: accessibilityTimeoutSeconds)
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

    /// Capture-owned coordinate mapping for the delivered raster, including an optional ROI viewport.
    public let captureCoordinateContext: CaptureCoordinateContext?

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
        case captureCoordinateContext
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
        desktopMutationPreservationAllowed: Bool? = nil,
        captureCoordinateContext: CaptureCoordinateContext? = nil)
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
        self.captureCoordinateContext = captureCoordinateContext
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
        self.captureCoordinateContext = try container.decodeIfPresent(
            CaptureCoordinateContext.self,
            forKey: .captureCoordinateContext)
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
        try container.encodeIfPresent(self.captureCoordinateContext, forKey: .captureCoordinateContext)
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
