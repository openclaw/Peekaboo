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

    public init(
        direction: PeekabooFoundation.ScrollDirection,
        amount: Int,
        target: String? = nil,
        smooth: Bool = false,
        delay: Int = 10,
        snapshotId: String? = nil)
    {
        self.direction = direction
        self.amount = amount
        self.target = target
        self.smooth = smooth
        self.delay = delay
        self.snapshotId = snapshotId
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

    public init(
        role: String,
        title: String?,
        value: String?,
        frame: CGRect,
        applicationName: String,
        bundleIdentifier: String,
        processId: Int)
    {
        self.role = role
        self.title = title
        self.value = value
        self.frame = frame
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.processId = processId
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
            try container.encode(value)
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
