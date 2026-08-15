import CoreGraphics
import Foundation
import PeekabooFoundation

/// Canonical outcome and routing metadata for one UI input execution.
public struct UIInputExecutionResult: Codable, Equatable, Sendable {
    /// The action phase result before the dispatcher assigns strategy, path, fallback, and timing.
    ///
    /// Keeping this phase nested under the canonical execution result prevents action drivers
    /// from fabricating dispatcher-owned routing metadata while avoiding a parallel result family.
    public struct Action: Codable, Equatable, Sendable {
        public let outcome: DesktopActionOutcome
        public let actionName: String?
        public let anchorPoint: CGPoint?
        public let elementRole: String?
        public let focusedElement: FocusedElementIdentity?

        public init(
            outcome: DesktopActionOutcome,
            actionName: String? = nil,
            anchorPoint: CGPoint? = nil,
            elementRole: String? = nil,
            focusedElement: FocusedElementIdentity? = nil)
        {
            self.outcome = outcome
            self.actionName = actionName
            self.anchorPoint = anchorPoint
            self.elementRole = elementRole
            self.focusedElement = focusedElement
        }
    }

    public var outcome: DesktopActionOutcome
    public var verb: UIInputVerb
    public var strategy: UIInputStrategy
    public var path: UIInputExecutionPath
    public var fallbackReason: UIInputFallbackReason?
    public var bundleIdentifier: String?
    public var elementRole: String?
    public var actionName: String?
    public var anchorPoint: CGPoint?
    public var duration: TimeInterval

    /// Preserves the shipped v4 source contract. Historical callers do not provide outcome
    /// evidence, so their result is conservatively indeterminate and retry-unsafe.
    public init(
        verb: UIInputVerb,
        strategy: UIInputStrategy,
        path: UIInputExecutionPath,
        fallbackReason: UIInputFallbackReason? = nil,
        bundleIdentifier: String? = nil,
        elementRole: String? = nil,
        actionName: String? = nil,
        anchorPoint: CGPoint? = nil,
        duration: TimeInterval = 0)
    {
        self.init(
            outcome: Self.legacyOutcome,
            verb: verb,
            strategy: strategy,
            path: path,
            fallbackReason: fallbackReason,
            bundleIdentifier: bundleIdentifier,
            elementRole: elementRole,
            actionName: actionName,
            anchorPoint: anchorPoint,
            duration: duration)
    }

    public init(
        outcome: DesktopActionOutcome,
        verb: UIInputVerb,
        strategy: UIInputStrategy,
        path: UIInputExecutionPath,
        fallbackReason: UIInputFallbackReason? = nil,
        bundleIdentifier: String? = nil,
        elementRole: String? = nil,
        actionName: String? = nil,
        anchorPoint: CGPoint? = nil,
        duration: TimeInterval = 0)
    {
        self.outcome = outcome
        self.verb = verb
        self.strategy = strategy
        self.path = path
        self.fallbackReason = fallbackReason
        self.bundleIdentifier = bundleIdentifier
        self.elementRole = elementRole
        self.actionName = actionName
        self.anchorPoint = anchorPoint
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case verb
        case strategy
        case path
        case fallbackReason
        case bundleIdentifier
        case elementRole
        case actionName
        case anchorPoint
        case duration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.outcome = try container.decodeIfPresent(DesktopActionOutcome.self, forKey: .outcome) ?? Self.legacyOutcome
        self.verb = try container.decode(UIInputVerb.self, forKey: .verb)
        self.strategy = try container.decode(UIInputStrategy.self, forKey: .strategy)
        self.path = try container.decode(UIInputExecutionPath.self, forKey: .path)
        self.fallbackReason = try container.decodeIfPresent(UIInputFallbackReason.self, forKey: .fallbackReason)
        self.bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        self.elementRole = try container.decodeIfPresent(String.self, forKey: .elementRole)
        self.actionName = try container.decodeIfPresent(String.self, forKey: .actionName)
        self.anchorPoint = try container.decodeIfPresent(CGPoint.self, forKey: .anchorPoint)
        self.duration = try container.decode(TimeInterval.self, forKey: .duration)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.outcome, forKey: .outcome)
        try container.encode(self.verb, forKey: .verb)
        try container.encode(self.strategy, forKey: .strategy)
        try container.encode(self.path, forKey: .path)
        try container.encodeIfPresent(self.fallbackReason, forKey: .fallbackReason)
        try container.encodeIfPresent(self.bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(self.elementRole, forKey: .elementRole)
        try container.encodeIfPresent(self.actionName, forKey: .actionName)
        try container.encodeIfPresent(self.anchorPoint, forKey: .anchorPoint)
        try container.encode(self.duration, forKey: .duration)
    }

    private static var legacyOutcome: DesktopActionOutcome {
        .indeterminate(evidence: .completionUnknown)
    }
}
