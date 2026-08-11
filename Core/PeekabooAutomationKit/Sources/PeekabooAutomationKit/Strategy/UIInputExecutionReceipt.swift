import CoreGraphics
import Foundation
import PeekabooFoundation

/// Canonical outcome and routing metadata for one UI input execution.
public struct UIInputExecutionReceipt: Codable, Equatable, Sendable {
    /// The action phase result before the dispatcher assigns strategy, path, fallback, and timing.
    ///
    /// Keeping this phase nested under the canonical execution receipt prevents action drivers
    /// from fabricating dispatcher-owned routing metadata while avoiding a parallel result family.
    public struct Action: Codable, Equatable, Sendable {
        public let outcome: DesktopActionOutcome
        public let actionName: String?
        public let anchorPoint: CGPoint?
        public let elementRole: String?

        public init(
            outcome: DesktopActionOutcome,
            actionName: String? = nil,
            anchorPoint: CGPoint? = nil,
            elementRole: String? = nil)
        {
            self.outcome = outcome
            self.actionName = actionName
            self.anchorPoint = anchorPoint
            self.elementRole = elementRole
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

    public init(
        outcome: DesktopActionOutcome,
        verb: UIInputVerb,
        strategy: UIInputStrategy,
        path: UIInputExecutionPath,
        fallbackReason: UIInputFallbackReason?,
        bundleIdentifier: String?,
        elementRole: String?,
        actionName: String?,
        anchorPoint: CGPoint?,
        duration: TimeInterval)
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
}
