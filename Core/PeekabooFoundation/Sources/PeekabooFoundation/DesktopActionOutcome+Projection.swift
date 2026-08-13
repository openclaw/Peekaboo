import Foundation

extension DesktopActionOutcome {
    /// Flat transport projection of one validated desktop action outcome.
    ///
    /// The canonical state machine remains owned by ``DesktopActionOutcome``. This type has no
    /// fieldwise initializer: callers project a validated outcome, while decoding reconstructs and
    /// validates that outcome before accepting the compatibility booleans.
    public struct Projection: Codable, Equatable, Sendable {
        public let outcome: DesktopActionOutcome

        public var state: State {
            self.outcome.state
        }

        public var effect: Effect {
            self.outcome.effect
        }

        public var route: Route {
            self.outcome.route
        }

        public var deliveryMechanism: Delivery.Mechanism? {
            self.outcome.delivery?.mechanism
        }

        public var deliveryMode: Delivery.Mode? {
            self.outcome.delivery?.mode
        }

        public var evidence: Evidence {
            self.outcome.evidence
        }

        public var dispatchState: DispatchState {
            self.outcome.dispatchState
        }

        public var dispatchedUnitCount: DispatchUnitCount? {
            self.outcome.dispatchState.unitCount
        }

        public var retrySafety: RetrySafety {
            self.outcome.retrySafety
        }

        public var escalation: Escalation {
            self.outcome.escalation
        }

        public var refusalReason: RefusalReason? {
            self.outcome.refusalReason
        }

        /// Compatibility field retained for existing result consumers.
        public var mutationDispatched: Bool {
            self.outcome.dispatchState.mutationDispatched
        }

        /// Compatibility field retained for existing result consumers.
        ///
        /// `.notApplicable` is intentionally false: only a canonical `.safe` outcome is retry-safe.
        public var retrySafe: Bool {
            self.outcome.retrySafety == .safe
        }

        /// Whether a dispatched or potentially dispatched action must be observed before retrying.
        public var requiresFreshObservation: Bool {
            self.outcome.dispatchState != .none && self.outcome.escalation == .observeBeforeRetry
        }

        public init(outcome: DesktopActionOutcome) {
            self.outcome = outcome
        }

        private enum CodingKeys: String, CodingKey {
            case mutationDispatched = "mutation_dispatched"
            case retrySafe = "retry_safe"
            case requiresFreshObservation = "requires_fresh_observation"
        }

        public func encode(to encoder: any Encoder) throws {
            try self.outcome.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.mutationDispatched, forKey: .mutationDispatched)
            try container.encode(self.retrySafe, forKey: .retrySafe)
            try container.encode(self.requiresFreshObservation, forKey: .requiresFreshObservation)
        }

        public init(from decoder: any Decoder) throws {
            let outcome = try DesktopActionOutcome(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let encodedMutationDispatched = try container.decode(Bool.self, forKey: .mutationDispatched)
            let encodedRetrySafe = try container.decode(Bool.self, forKey: .retrySafe)
            let encodedRequiresFreshObservation = try container.decode(
                Bool.self,
                forKey: .requiresFreshObservation)
            let projection = Self(outcome: outcome)

            try Self.validateCompatibilityField(
                encodedMutationDispatched,
                equals: projection.mutationDispatched,
                forKey: .mutationDispatched,
                in: container)
            try Self.validateCompatibilityField(
                encodedRetrySafe,
                equals: projection.retrySafe,
                forKey: .retrySafe,
                in: container)
            try Self.validateCompatibilityField(
                encodedRequiresFreshObservation,
                equals: projection.requiresFreshObservation,
                forKey: .requiresFreshObservation,
                in: container)
            self = projection
        }

        private static func validateCompatibilityField(
            _ encoded: Bool,
            equals expected: Bool,
            forKey key: CodingKeys,
            in container: KeyedDecodingContainer<CodingKeys>) throws
        {
            guard encoded == expected else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Compatibility field contradicts the validated desktop action outcome")
            }
        }
    }

    public var projection: Projection {
        Projection(outcome: self)
    }

    /// Canonical flat projection for a refusal before any mutation dispatch.
    public static func preDispatchRefusalProjection(
        route: Route = .local,
        reason: RefusalReason) -> Projection
    {
        refused(route: route, reason: reason).projection
    }

    /// Upgrades paired legacy compatibility fields only when they prove zero dispatch.
    /// Either field on its own is insufficient evidence for the canonical state machine.
    public static func preDispatchRefusalProjection(
        route: Route = .local,
        reason: RefusalReason,
        legacyRetrySafe: Bool?,
        legacyMutationDispatched: Bool?) -> Projection?
    {
        guard legacyRetrySafe == true, legacyMutationDispatched == false else { return nil }
        return self.preDispatchRefusalProjection(route: route, reason: reason)
    }
}
