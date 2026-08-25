import CoreGraphics
import Foundation
import PeekabooFoundation

/// Target for click operations
public enum ClickTarget: Sendable, Codable {
    /// Click an element by its opaque detected ID.
    case elementId(String)

    /// Click at specific coordinates
    case coordinates(CGPoint)

    /// Click on element matching query
    case query(String)

    private enum CodingKeys: String, CodingKey { case kind, value, x, y }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "elementId":
            self = try .elementId(container.decode(String.self, forKey: .value))
        case "coordinates":
            let x = try container.decode(CGFloat.self, forKey: .x)
            let y = try container.decode(CGFloat.self, forKey: .y)
            self = .coordinates(CGPoint(x: x, y: y))
        case "query":
            self = try .query(container.decode(String.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown ClickTarget kind: \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .elementId(id):
            try container.encode("elementId", forKey: .kind)
            try container.encode(id, forKey: .value)
        case let .coordinates(point):
            try container.encode("coordinates", forKey: .kind)
            try container.encode(point.x, forKey: .x)
            try container.encode(point.y, forKey: .y)
        case let .query(query):
            try container.encode("query", forKey: .kind)
            try container.encode(query, forKey: .value)
        }
    }
}

// ClickType is now in PeekabooFoundation

// ScrollDirection is now in PeekabooFoundation

// SwipeDirection is now in PeekabooFoundation

// ModifierKey is now in PeekabooFoundation

public struct ScrollRequest: Sendable, Codable {
    public var direction: PeekabooFoundation.ScrollDirection
    public var amount: Int
    public var target: String?
    public var smooth: Bool
    public var delay: Int
    public var snapshotId: String?
    /// Capture-owned exact window expected to contain the background scroll target.
    ///
    /// Remote callers include this receipt so Bridge can bind even a post-dispatch failure to the
    /// same immutable process generation, WindowServer ID, and bounds that selected the element.
    /// The execution owner still resolves the snapshot independently and rejects any mismatch
    /// before dispatch.
    public var expectedWindow: UIAutomationTarget.ExactWindow?
    /// Explicit consent to use global synthetic pointer events.
    ///
    /// Background scrolls are accessibility-action-only and never move or otherwise reuse the
    /// physical pointer. Foreground scrolls may synthesize wheel events at the resolved target.
    public var foreground: Bool

    public init(
        direction: PeekabooFoundation.ScrollDirection,
        amount: Int,
        target: String? = nil,
        smooth: Bool = false,
        delay: Int = 0,
        snapshotId: String? = nil,
        expectedWindow: UIAutomationTarget.ExactWindow? = nil,
        foreground: Bool = false)
    {
        self.direction = direction
        self.amount = amount
        self.target = target
        self.smooth = smooth
        self.delay = delay
        self.snapshotId = snapshotId
        self.expectedWindow = expectedWindow
        self.foreground = foreground
    }

    private enum CodingKeys: String, CodingKey {
        case direction
        case amount
        case target
        case smooth
        case delay
        case snapshotId
        case expectedWindow
        case foreground
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.direction = try container.decode(PeekabooFoundation.ScrollDirection.self, forKey: .direction)
        self.amount = try container.decode(Int.self, forKey: .amount)
        self.target = try container.decodeIfPresent(String.self, forKey: .target)
        self.smooth = try container.decodeIfPresent(Bool.self, forKey: .smooth) ?? false
        self.delay = try container.decodeIfPresent(Int.self, forKey: .delay) ?? 0
        self.snapshotId = try container.decodeIfPresent(String.self, forKey: .snapshotId)
        self.expectedWindow = try container.decodeIfPresent(
            UIAutomationTarget.ExactWindow.self,
            forKey: .expectedWindow)
        self.foreground = try container.decodeIfPresent(Bool.self, forKey: .foreground) ?? false
    }
}

/// Result of waiting for an element
public struct WaitForElementResult: Sendable, Codable {
    public let found: Bool
    public let element: DetectedElement?
    public let waitTime: TimeInterval
    public let warnings: [String]

    public init(found: Bool, element: DetectedElement?, waitTime: TimeInterval, warnings: [String] = []) {
        self.found = found
        self.element = element
        self.waitTime = waitTime
        self.warnings = warnings
    }

    public init(found: Bool, element: DetectedElement?, waitTime: TimeInterval) {
        self.init(found: found, element: element, waitTime: waitTime, warnings: [])
    }
}

public struct UIFocusInfo: Sendable, Codable {
    public let role: String
    public let title: String?
    public let value: String?
    public let frame: CGRect
    public let applicationName: String
    public let bundleIdentifier: String
    public let processId: Int
    public let windowID: Int?
    public let identifier: String?

    public init(
        role: String,
        title: String?,
        value: String?,
        frame: CGRect,
        applicationName: String,
        bundleIdentifier: String,
        processId: Int,
        windowID: Int? = nil,
        identifier: String? = nil)
    {
        self.role = role
        self.title = title
        self.value = value
        self.frame = frame
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.processId = processId
        self.windowID = windowID
        self.identifier = identifier
    }
}

/// Stable, non-value-bearing identity for the element that received a background click.
public struct FocusedElementIdentity: Sendable, Codable, Equatable {
    public let processIdentifier: Int32
    public let windowID: Int
    public let role: String
    public let title: String?
    public let identifier: String?
    public let frame: CGRect

    public init(
        processIdentifier: Int32,
        windowID: Int,
        role: String,
        title: String? = nil,
        identifier: String? = nil,
        frame: CGRect)
    {
        self.processIdentifier = processIdentifier
        self.windowID = windowID
        self.role = role
        self.title = title
        self.identifier = identifier
        self.frame = frame
    }

    public init?(_ focus: UIFocusInfo) {
        guard let windowID = focus.windowID,
              let processIdentifier = Int32(exactly: focus.processId),
              !focus.frame.isEmpty
        else { return nil }
        self.init(
            processIdentifier: processIdentifier,
            windowID: windowID,
            role: focus.role,
            title: focus.title,
            identifier: focus.identifier,
            frame: focus.frame)
    }
}

/// Typed reasons an exact-window focused-element receipt could not be established.
public enum FocusedElementReceiptError: LocalizedError, Equatable, Sendable {
    case missingProcessIdentifier
    case missingWindowIdentifier
    case missingWindowBounds
    case missingElementFrame
    case focusedAttributeNotSettable
    case focusedAttributeUnreadable
    case focusNotConfirmed
    case noFocusedElement
    case multipleFocusedElements
    case elementOutsideWindow
    case processMismatch
    case windowMismatch
    case roleMismatch
    case frameMismatch
    case identifierMismatch
    case titleMismatch

    public var errorDescription: String? {
        switch self {
        case .missingProcessIdentifier:
            "The focused element has no target process identifier."
        case .missingWindowIdentifier:
            "The focused element has no exact owning window identifier."
        case .missingWindowBounds:
            "The focused element target has no immutable window bounds receipt."
        case .missingElementFrame:
            "The focused element has no non-empty accessibility frame."
        case .focusedAttributeNotSettable:
            "The selected element does not expose a writable AXFocused attribute."
        case .focusedAttributeUnreadable:
            "The selected element's AXFocused attribute could not be read."
        case .focusNotConfirmed:
            "The selected element did not report AXFocused=true after the native focus request."
        case .noFocusedElement:
            "The exact target window reports no focused element."
        case .multipleFocusedElements:
            "The exact target window reports multiple focused elements."
        case .elementOutsideWindow:
            "The focused element frame is outside the exact target window bounds."
        case .processMismatch:
            "The focused element belongs to a different process."
        case .windowMismatch:
            "The focused element belongs to a different window."
        case .roleMismatch:
            "The focused element role changed."
        case .frameMismatch:
            "The focused element frame changed."
        case .identifierMismatch:
            "The focused element identifier changed."
        case .titleMismatch:
            "The focused element title changed."
        }
    }
}

/// Next step for every refusal that means "the exact target window does not hold this
/// application's keyboard focus".
///
/// Background keystrokes are posted to the application, which routes them to whichever window holds
/// its own keyboard focus — not to the window the caller named. Failing closed is therefore correct,
/// but the caller still has a route that reaches an unfocused window: an accessibility value write.
/// Keep this text attached to those refusals so background writing never ends in a dead end.
public enum BackgroundKeyboardFocusRemediation {
    public static let message = "Background keystrokes follow the application's own keyboard focus " +
        "and cannot be aimed at a window that does not hold it; such a window also refuses " +
        "accessibility focus requests, so no amount of retrying moves focus there in the " +
        "background. To write into this window without focusing it, observe it and set its editable " +
        "element's accessibility value (`set-value` command, `set_value` tool). Use foreground " +
        "delivery only when the window may take focus."
}

public struct ExactWindowKeyboardTarget: Sendable, Codable, Equatable {
    public let windowIdentity: WindowMutationIdentity
    public let windowBounds: CGRect
    public let focusedElement: FocusedElementIdentity

    public init(
        windowIdentity: WindowMutationIdentity,
        windowBounds: CGRect,
        focusedElement: FocusedElementIdentity)
    {
        self.windowIdentity = windowIdentity
        self.windowBounds = windowBounds
        self.focusedElement = focusedElement
    }
}

/// One exact-window background text operation that first establishes renderer focus at a
/// capture-owned point, then sends the requested keyboard actions without releasing the
/// target's desktop-operation lane.
public struct ExactWindowPixelFocusTypeRequest: Sendable, Codable {
    public let point: CGPoint
    public let actions: [TypeAction]
    public let cadence: TypingCadence
    public let snapshotID: String
    public let windowIdentity: WindowMutationIdentity
    public let windowBounds: CGRect

    public init(
        point: CGPoint,
        actions: [TypeAction],
        cadence: TypingCadence,
        snapshotID: String,
        windowIdentity: WindowMutationIdentity,
        windowBounds: CGRect)
    {
        self.point = point
        self.actions = actions
        self.cadence = cadence
        self.snapshotID = snapshotID
        self.windowIdentity = windowIdentity
        self.windowBounds = windowBounds
    }
}

public enum PointerModifier: String, Sendable, Codable, CaseIterable {
    case command
    case shift
    case option
    case control
}

public enum SharedDesktopRestorationStatus: String, Sendable, Codable, Equatable {
    case notNeeded = "not_needed"
    case restored
    /// The state no longer matched Peekaboo's last write, so newer user or application state won.
    case preservedNewerState = "preserved_newer_state"
}

public struct ForegroundModifierClickRequest: Sendable, Codable {
    private enum CodingKeys: String, CodingKey {
        case point
        case clickType
        case modifiers
        case snapshotID
        case windowIdentity
        case windowBounds
    }

    public let point: CGPoint
    public let clickType: ClickType
    public let modifiers: [PointerModifier]
    public let snapshotID: String
    public let windowIdentity: WindowMutationIdentity
    public let windowBounds: CGRect

    public init(
        point: CGPoint,
        clickType: ClickType,
        modifiers: [PointerModifier],
        snapshotID: String,
        windowIdentity: WindowMutationIdentity,
        windowBounds: CGRect)
    {
        self.point = point
        self.clickType = clickType
        self.modifiers = modifiers
        self.snapshotID = snapshotID
        self.windowIdentity = windowIdentity
        self.windowBounds = windowBounds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.point = try container.decode(CGPoint.self, forKey: .point)
        self.clickType = try container.decode(ClickType.self, forKey: .clickType)
        self.modifiers = try container.decode([PointerModifier].self, forKey: .modifiers)
        // Pre-fix protocol 1.33 clients omitted this field. Preserve wire decoding so the
        // host leaf can refuse the empty authority before focus or input instead of dropping the response.
        self.snapshotID = try container.decodeIfPresent(String.self, forKey: .snapshotID) ?? ""
        self.windowIdentity = try container.decode(WindowMutationIdentity.self, forKey: .windowIdentity)
        self.windowBounds = try container.decode(CGRect.self, forKey: .windowBounds)
    }
}

public struct ForegroundModifierClickResult: Sendable, Codable, Equatable {
    public let cursorRestoration: SharedDesktopRestorationStatus
    public let focusRestoration: SharedDesktopRestorationStatus

    public init(
        cursorRestoration: SharedDesktopRestorationStatus,
        focusRestoration: SharedDesktopRestorationStatus)
    {
        self.cursorRestoration = cursorRestoration
        self.focusRestoration = focusRestoration
    }
}

// TypeAction is now in PeekabooFoundation

// SpecialKey is now in PeekabooFoundation

/// Result of typing operations
public struct TypeResult: Sendable, Codable {
    public let totalCharacters: Int
    public let keyPresses: Int

    public init(totalCharacters: Int, keyPresses: Int) {
        self.totalCharacters = totalCharacters
        self.keyPresses = keyPresses
    }
}

/// Payload returned by an automation action together with its canonical execution outcome.
///
/// This remains a nominal type for source and binary compatibility with Peekaboo 4.1.0.
public struct UIAutomationActionResult<Payload: Sendable>: Sendable {
    public let payload: Payload
    public let outcome: DesktopActionOutcome?
    public let targetIdentity: DesktopTargetIdentity?
    public let selectedLeafEvidence: [DesktopSelectedLeafEvidence]?

    public init(payload: Payload, outcome: DesktopActionOutcome?) {
        self.init(payload: payload, outcome: outcome, targetIdentity: nil)
    }

    public init(
        payload: Payload,
        outcome: DesktopActionOutcome?,
        targetIdentity: DesktopTargetIdentity?)
    {
        self.init(
            payload: payload,
            outcome: outcome,
            targetIdentity: targetIdentity,
            selectedLeafEvidence: nil)
    }

    public init(
        payload: Payload,
        outcome: DesktopActionOutcome?,
        targetIdentity: DesktopTargetIdentity?,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]?)
    {
        self.payload = payload
        self.outcome = outcome
        self.targetIdentity = targetIdentity
        self.selectedLeafEvidence = selectedLeafEvidence
    }

    public init(_ result: DesktopActionResult<Payload>) {
        self.init(
            payload: result.payload,
            outcome: result.outcome,
            targetIdentity: nil,
            selectedLeafEvidence: nil)
    }

    public var desktopActionResult: DesktopActionResult<Payload> {
        DesktopActionResult(payload: self.payload, outcome: self.outcome)
    }
}

/// Value payload for direct accessibility value mutation.
public enum UIElementValue: Sendable, Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public var displayString: String {
        switch self {
        case let .bool(value):
            String(value)
        case let .int(value):
            String(value)
        case let .double(value):
            String(value)
        case let .string(value):
            value
        }
    }

    var accessibilityValue: Any {
        switch self {
        case let .bool(value):
            value
        case let .int(value):
            value
        case let .double(value):
            value
        case let .string(value):
            value
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "UIElementValue must be a boolean, number, or string")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value == 0 ? 0.0 : value)
        case let .string(value):
            try container.encode(value)
        }
    }
}

/// Result returned by element-targeted accessibility action tools.
public struct ElementActionResult: Sendable, Codable, Equatable {
    public let target: String
    public let actionName: String?
    public let anchorPoint: CGPoint?
    public let oldValue: String?
    public let newValue: String?

    public init(
        target: String,
        actionName: String?,
        anchorPoint: CGPoint?,
        oldValue: String? = nil,
        newValue: String? = nil)
    {
        self.target = target
        self.actionName = actionName
        self.anchorPoint = anchorPoint
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

/// Criteria for searching UI elements
public enum UIElementSearchCriteria: Sendable, Codable {
    case label(String)
    case identifier(String)
    case type(String)

    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)
        switch kind {
        case "label": self = .label(value)
        case "identifier": self = .identifier(value)
        case "type": self = .type(value)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown UIElementSearchCriteria kind: \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .label(value):
            try container.encode("label", forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .identifier(value):
            try container.encode("identifier", forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .type(value):
            try container.encode("type", forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}
