import Foundation

/// A closed description of what Peekaboo knows about a desktop action after execution.
///
/// Callers construct outcomes through the state-specific factories. The encoded representation
/// includes derived safety fields so other processes can consume it without reimplementing the
/// state machine; decoding validates those fields instead of trusting them.
public struct DesktopActionOutcome: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case confirmedChange = "confirmed_change"
        case confirmedNoChange = "confirmed_no_change"
        case partial
        case dispatchedUnverified = "dispatched_unverified"
        case suspectedNoop = "suspected_noop"
        case refused
        case indeterminate
    }

    public enum Effect: String, Codable, Sendable {
        case confirmed
        case partial
        case unverifiable
        case suspectedNoop = "suspected_noop"
        case refused
    }

    public enum Route: String, Codable, Sendable {
        case local
        case bridge
    }

    public struct Delivery: Codable, Equatable, Sendable {
        public enum Mechanism: String, Codable, Sendable {
            /// A single logical operation composed from two or more concrete delivery mechanisms.
            /// The unit count remains the exact sum of the constituent dispatches.
            case composite
            case accessibilityAction = "accessibility_action"
            case accessibilityValue = "accessibility_value"
            case processTargetedEvents = "process_targeted_events"
            case windowTargetedEvents = "window_targeted_events"
            case globalEvents = "global_events"
            case clipboardTransaction = "clipboard_transaction"
            case nativeFramework = "native_framework"
            case browserProtocol = "browser_protocol"
            case capturePipeline = "capture_pipeline"
        }

        public enum Mode: String, Codable, Sendable {
            case background
            case foreground
        }

        public let mechanism: Mechanism
        public let mode: Mode

        public init(mechanism: Mechanism, mode: Mode) {
            self.mechanism = mechanism
            self.mode = mode
        }
    }

    public enum Evidence: String, Codable, Sendable {
        case verifiedChange = "verified_change"
        case verifiedNoChange = "verified_no_change"
        case primaryChangeVerifiedCleanupFailed = "primary_change_verified_cleanup_failed"
        case deliveryAccepted = "delivery_accepted"
        case operationStillRunning = "operation_still_running"
        case observedNoChange = "observed_no_change"
        case requestRefused = "request_refused"
        case responseLost = "response_lost"
        case completionUnknown = "completion_unknown"
    }

    public enum DispatchedUnverifiedEvidence: String, Codable, Sendable {
        case deliveryAccepted = "delivery_accepted"
        case operationStillRunning = "operation_still_running"

        fileprivate var evidence: Evidence {
            switch self {
            case .deliveryAccepted: .deliveryAccepted
            case .operationStillRunning: .operationStillRunning
            }
        }
    }

    public enum IndeterminateEvidence: String, Codable, Sendable {
        case responseLost = "response_lost"
        case completionUnknown = "completion_unknown"

        fileprivate var evidence: Evidence {
            switch self {
            case .responseLost: .responseLost
            case .completionUnknown: .completionUnknown
            }
        }
    }

    public struct DispatchUnitCount: Codable, Equatable, Hashable, RawRepresentable, Sendable {
        public static let one = Self(validatedRawValue: 1)

        public let rawValue: Int

        public init?(_ value: Int) {
            self.init(rawValue: value)
        }

        public init?(rawValue: Int) {
            guard rawValue > 0 else { return nil }
            self.rawValue = rawValue
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(Int.self)
            guard let value = Self(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "A dispatched unit count must be positive")
            }
            self = value
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(self.rawValue)
        }

        private init(validatedRawValue: Int) {
            self.rawValue = validatedRawValue
        }
    }

    public enum DispatchState: Equatable, Sendable {
        case none
        case dispatched(unitCount: DispatchUnitCount?)
        case mayHaveDispatched(unitCount: DispatchUnitCount?)

        public var unitCount: DispatchUnitCount? {
            switch self {
            case .none: nil
            case let .dispatched(unitCount), let .mayHaveDispatched(unitCount): unitCount
            }
        }

        public var mutationDispatched: Bool {
            switch self {
            case .none: false
            case .dispatched, .mayHaveDispatched: true
            }
        }

        fileprivate var kind: Kind {
            switch self {
            case .none: .none
            case .dispatched: .dispatched
            case .mayHaveDispatched: .mayHaveDispatched
            }
        }

        fileprivate enum Kind: String, Codable {
            case none
            case dispatched
            case mayHaveDispatched = "may_have_dispatched"
        }
    }

    public enum RetrySafety: String, Codable, Sendable {
        case safe
        case unsafe
        case notApplicable = "not_applicable"
    }

    public enum Escalation: String, Codable, Sendable {
        case none
        case correctRequest = "correct_request"
        case grantPermission = "grant_permission"
        case refreshTarget = "refresh_target"
        case reconnectSession = "reconnect_session"
        case updateRuntime = "update_runtime"
        case recoverSideEffect = "recover_side_effect"
        case observeBeforeRetry = "observe_before_retry"
    }

    public enum RefusalReason: String, Codable, Sendable {
        case invalidRequest = "invalid_request"
        case permissionDenied = "permission_denied"
        case targetUnavailable = "target_unavailable"
        case transportSessionUnavailable = "transport_session_unavailable"
        case requestCancelled = "request_cancelled"
        case runtimeIncompatible = "runtime_incompatible"
        case foregroundConsentRequired = "foreground_consent_required"
        case operationUnsupported = "operation_unsupported"

        fileprivate var escalation: Escalation {
            switch self {
            case .invalidRequest, .foregroundConsentRequired, .operationUnsupported:
                .correctRequest
            case .permissionDenied:
                .grantPermission
            case .targetUnavailable:
                .refreshTarget
            case .transportSessionUnavailable:
                .reconnectSession
            case .requestCancelled:
                .none
            case .runtimeIncompatible:
                .updateRuntime
            }
        }
    }

    /// Shared policy for deciding whether a returned action outcome can represent a successful
    /// operation at a caller boundary.
    ///
    /// Confirmation and dispatch acceptance are deliberately separate. Some surfaces require a
    /// verified effect, while compatibility surfaces may accept an honestly reported unverified
    /// dispatch. A delivery-mode requirement applies only to states that dispatched work;
    /// `confirmedNoChange` remains valid because it proves that no dispatch was necessary.
    public struct SuccessPolicy: Equatable, Sendable {
        public let acceptsDispatchedUnverified: Bool
        public let acceptsSuspectedNoop: Bool
        public let requiredDeliveryMode: Delivery.Mode?

        public init(
            acceptsDispatchedUnverified: Bool,
            acceptsSuspectedNoop: Bool = false,
            requiredDeliveryMode: Delivery.Mode? = nil)
        {
            self.acceptsDispatchedUnverified = acceptsDispatchedUnverified
            self.acceptsSuspectedNoop = acceptsSuspectedNoop
            self.requiredDeliveryMode = requiredDeliveryMode
        }

        public static let confirmed = Self(acceptsDispatchedUnverified: false)
        public static let confirmedOrDispatched = Self(acceptsDispatchedUnverified: true)
        public static let observation = Self(
            acceptsDispatchedUnverified: true,
            acceptsSuspectedNoop: true)

        public static func confirmed(
            requiring deliveryMode: Delivery.Mode) -> Self
        {
            Self(
                acceptsDispatchedUnverified: false,
                requiredDeliveryMode: deliveryMode)
        }

        public static func confirmedOrDispatched(
            requiring deliveryMode: Delivery.Mode) -> Self
        {
            Self(
                acceptsDispatchedUnverified: true,
                requiredDeliveryMode: deliveryMode)
        }

        public static func observation(
            requiring deliveryMode: Delivery.Mode) -> Self
        {
            Self(
                acceptsDispatchedUnverified: true,
                acceptsSuspectedNoop: true,
                requiredDeliveryMode: deliveryMode)
        }

        public func accepts(_ outcome: DesktopActionOutcome) -> Bool {
            let acceptedState = switch outcome.state {
            case .confirmedChange, .confirmedNoChange:
                true
            case .dispatchedUnverified:
                self.acceptsDispatchedUnverified
            case .suspectedNoop:
                self.acceptsSuspectedNoop
            case .partial, .refused, .indeterminate:
                false
            }
            guard acceptedState else { return false }
            guard outcome.state != .confirmedNoChange,
                  let requiredDeliveryMode = self.requiredDeliveryMode
            else {
                return true
            }
            return outcome.delivery?.mode == requiredDeliveryMode
        }
    }

    public let state: State
    public let route: Route
    public let delivery: Delivery?
    public let evidence: Evidence
    public let dispatchState: DispatchState
    public let retrySafety: RetrySafety
    public let escalation: Escalation
    public let refusalReason: RefusalReason?

    public var effect: Effect {
        switch self.state {
        case .confirmedChange, .confirmedNoChange: .confirmed
        case .partial: .partial
        case .dispatchedUnverified, .indeterminate: .unverifiable
        case .suspectedNoop: .suspectedNoop
        case .refused: .refused
        }
    }

    public var isConfirmed: Bool {
        self.effect == .confirmed
    }

    public func isAccepted(by policy: SuccessPolicy) -> Bool {
        policy.accepts(self)
    }

    private init(
        state: State,
        route: Route,
        delivery: Delivery?,
        evidence: Evidence,
        dispatchState: DispatchState,
        retrySafety: RetrySafety,
        escalation: Escalation,
        refusalReason: RefusalReason? = nil)
    {
        self.state = state
        self.route = route
        self.delivery = delivery
        self.evidence = evidence
        self.dispatchState = dispatchState
        self.retrySafety = retrySafety
        self.escalation = escalation
        self.refusalReason = refusalReason
    }

    public static func confirmedChange(
        route: Route = .local,
        delivery: Delivery,
        unitCount: DispatchUnitCount? = nil) -> DesktopActionOutcome
    {
        Self(
            state: .confirmedChange,
            route: route,
            delivery: delivery,
            evidence: .verifiedChange,
            dispatchState: .dispatched(unitCount: unitCount),
            retrySafety: .notApplicable,
            escalation: .none)
    }

    public static func confirmedNoChange(route: Route = .local) -> DesktopActionOutcome {
        Self(
            state: .confirmedNoChange,
            route: route,
            delivery: nil,
            evidence: .verifiedNoChange,
            dispatchState: .none,
            retrySafety: .notApplicable,
            escalation: .none)
    }

    public static func partial(
        route: Route = .local,
        delivery: Delivery,
        unitCount: DispatchUnitCount? = nil) -> DesktopActionOutcome
    {
        Self(
            state: .partial,
            route: route,
            delivery: delivery,
            evidence: .primaryChangeVerifiedCleanupFailed,
            dispatchState: .dispatched(unitCount: unitCount),
            retrySafety: .unsafe,
            escalation: .recoverSideEffect)
    }

    public static func dispatchedUnverified(
        route: Route = .local,
        delivery: Delivery,
        evidence: DispatchedUnverifiedEvidence,
        unitCount: DispatchUnitCount? = nil) -> DesktopActionOutcome
    {
        Self(
            state: .dispatchedUnverified,
            route: route,
            delivery: delivery,
            evidence: evidence.evidence,
            dispatchState: .dispatched(unitCount: unitCount),
            retrySafety: .unsafe,
            escalation: .observeBeforeRetry)
    }

    public static func suspectedNoop(
        route: Route = .local,
        delivery: Delivery,
        unitCount: DispatchUnitCount? = nil) -> DesktopActionOutcome
    {
        Self(
            state: .suspectedNoop,
            route: route,
            delivery: delivery,
            evidence: .observedNoChange,
            dispatchState: .dispatched(unitCount: unitCount),
            retrySafety: .safe,
            escalation: .refreshTarget)
    }

    public static func refused(
        route: Route = .local,
        reason: RefusalReason) -> DesktopActionOutcome
    {
        Self(
            state: .refused,
            route: route,
            delivery: nil,
            evidence: .requestRefused,
            dispatchState: .none,
            retrySafety: .safe,
            escalation: reason.escalation,
            refusalReason: reason)
    }

    public static func indeterminate(
        route: Route = .local,
        delivery: Delivery? = nil,
        evidence: IndeterminateEvidence,
        unitCount: DispatchUnitCount? = nil) -> DesktopActionOutcome
    {
        Self(
            state: .indeterminate,
            route: route,
            delivery: delivery,
            evidence: evidence.evidence,
            dispatchState: .mayHaveDispatched(unitCount: unitCount),
            retrySafety: .unsafe,
            escalation: .observeBeforeRetry)
    }

    /// Reassigns only the transport route of an already-validated outcome.
    ///
    /// Bridge code uses this at its ownership boundary instead of rebuilding state-specific
    /// fields and risking a second, contradictory outcome model.
    public func routed(to route: Route) -> DesktopActionOutcome {
        Self(
            state: self.state,
            route: route,
            delivery: self.delivery,
            evidence: self.evidence,
            dispatchState: self.dispatchState,
            retrySafety: self.retrySafety,
            escalation: self.escalation,
            refusalReason: self.refusalReason)
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case effect
        case route
        case deliveryMechanism = "delivery_mechanism"
        case deliveryMode = "delivery_mode"
        case evidence
        case dispatchState = "dispatch_state"
        case dispatchedUnitCount = "dispatched_unit_count"
        case retrySafety = "retry_safety"
        case escalation
        case refusalReason = "refusal_reason"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.state, forKey: .state)
        try container.encode(self.effect, forKey: .effect)
        try container.encode(self.route, forKey: .route)
        try container.encodeIfPresent(self.delivery?.mechanism, forKey: .deliveryMechanism)
        try container.encodeIfPresent(self.delivery?.mode, forKey: .deliveryMode)
        try container.encode(self.evidence, forKey: .evidence)
        try container.encode(self.dispatchState.kind, forKey: .dispatchState)
        try container.encodeIfPresent(self.dispatchState.unitCount?.rawValue, forKey: .dispatchedUnitCount)
        try container.encode(self.retrySafety, forKey: .retrySafety)
        try container.encode(self.escalation, forKey: .escalation)
        try container.encodeIfPresent(self.refusalReason, forKey: .refusalReason)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(State.self, forKey: .state)
        let encodedEffect = try container.decode(Effect.self, forKey: .effect)
        let route = try container.decode(Route.self, forKey: .route)
        let deliveryMechanism = try container.decodeIfPresent(Delivery.Mechanism.self, forKey: .deliveryMechanism)
        let deliveryMode = try container.decodeIfPresent(Delivery.Mode.self, forKey: .deliveryMode)
        let delivery: Delivery? = try Self.decodeDelivery(
            mechanism: deliveryMechanism,
            mode: deliveryMode,
            container: container)
        let evidence = try container.decode(Evidence.self, forKey: .evidence)
        let dispatchKind = try container.decode(DispatchState.Kind.self, forKey: .dispatchState)
        let unitCount = try container.decodeIfPresent(Int.self, forKey: .dispatchedUnitCount)
        let dispatchState = try Self.decodeDispatchState(
            kind: dispatchKind,
            unitCount: unitCount,
            container: container)
        let retrySafety = try container.decode(RetrySafety.self, forKey: .retrySafety)
        let escalation = try container.decode(Escalation.self, forKey: .escalation)
        let refusalReason = try container.decodeIfPresent(RefusalReason.self, forKey: .refusalReason)

        let outcome = Self(
            state: state,
            route: route,
            delivery: delivery,
            evidence: evidence,
            dispatchState: dispatchState,
            retrySafety: retrySafety,
            escalation: escalation,
            refusalReason: refusalReason)
        guard outcome.effect == encodedEffect else {
            throw DecodingError.dataCorruptedError(
                forKey: .effect,
                in: container,
                debugDescription: "Effect does not match desktop action state")
        }
        try outcome.validateDecoded(in: container)
        self = outcome
    }

    private static func decodeDelivery(
        mechanism: Delivery.Mechanism?,
        mode: Delivery.Mode?,
        container: KeyedDecodingContainer<CodingKeys>) throws -> Delivery?
    {
        switch (mechanism, mode) {
        case let (.some(mechanism), .some(mode)):
            Delivery(mechanism: mechanism, mode: mode)
        case (nil, nil):
            nil
        case (.some, nil), (nil, .some):
            throw DecodingError.dataCorruptedError(
                forKey: mechanism == nil ? .deliveryMechanism : .deliveryMode,
                in: container,
                debugDescription: "Delivery mechanism and mode must be encoded together")
        }
    }

    private static func decodeDispatchState(
        kind: DispatchState.Kind,
        unitCount: Int?,
        container: KeyedDecodingContainer<CodingKeys>) throws -> DispatchState
    {
        let validatedUnitCount: DispatchUnitCount?
        if let unitCount {
            guard let value = DispatchUnitCount(unitCount) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .dispatchedUnitCount,
                    in: container,
                    debugDescription: "A dispatched unit count must be positive")
            }
            validatedUnitCount = value
        } else {
            validatedUnitCount = nil
        }
        switch kind {
        case .none:
            guard unitCount == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .dispatchedUnitCount,
                    in: container,
                    debugDescription: "A non-dispatched action cannot have a unit count")
            }
            return .none
        case .dispatched:
            return .dispatched(unitCount: validatedUnitCount)
        case .mayHaveDispatched:
            return .mayHaveDispatched(unitCount: validatedUnitCount)
        }
    }

    private func validateDecoded(in container: KeyedDecodingContainer<CodingKeys>) throws {
        let isValid = switch self.state {
        case .confirmedChange:
            self.delivery != nil &&
                self.evidence == .verifiedChange &&
                self.dispatchState.kind == .dispatched &&
                self.retrySafety == .notApplicable &&
                self.escalation == .none &&
                self.refusalReason == nil
        case .confirmedNoChange:
            self.delivery == nil &&
                self.evidence == .verifiedNoChange &&
                self.dispatchState == .none &&
                self.retrySafety == .notApplicable &&
                self.escalation == .none &&
                self.refusalReason == nil
        case .partial:
            self.delivery != nil &&
                self.evidence == .primaryChangeVerifiedCleanupFailed &&
                self.dispatchState.kind == .dispatched &&
                self.retrySafety == .unsafe &&
                self.escalation == .recoverSideEffect &&
                self.refusalReason == nil
        case .dispatchedUnverified:
            self.delivery != nil &&
                [.deliveryAccepted, .operationStillRunning].contains(self.evidence) &&
                self.dispatchState.kind == .dispatched &&
                self.retrySafety == .unsafe &&
                self.escalation == .observeBeforeRetry &&
                self.refusalReason == nil
        case .suspectedNoop:
            self.delivery != nil &&
                self.evidence == .observedNoChange &&
                self.dispatchState.kind == .dispatched &&
                self.retrySafety == .safe &&
                self.escalation == .refreshTarget &&
                self.refusalReason == nil
        case .refused:
            self.delivery == nil &&
                self.evidence == .requestRefused &&
                self.dispatchState == .none &&
                self.retrySafety == .safe &&
                self.refusalReason?.escalation == self.escalation
        case .indeterminate:
            [.responseLost, .completionUnknown].contains(self.evidence) &&
                self.dispatchState.kind == .mayHaveDispatched &&
                self.retrySafety == .unsafe &&
                self.escalation == .observeBeforeRetry &&
                self.refusalReason == nil
        }
        guard isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .state,
                in: container,
                debugDescription: "Desktop action fields are inconsistent with state \(self.state.rawValue)")
        }
    }
}

/// Canonical generation-bound process or window attribution for desktop action results and failures.
public struct DesktopActionTargetReceipt: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let processStartIdentity: UInt64
    public let windowID: Int?

    public init(processIdentifier: Int32, processStartIdentity: UInt64, windowID: Int? = nil) {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.windowID = windowID
    }

    private enum CodingKeys: String, CodingKey {
        case processIdentifier = "pid"
        case processStartIdentity = "process_start_identity"
        case processStartIdentityDecimal = "process_start_identity_decimal"
        case windowID = "window_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
        let processStartIdentity = try container.decode(UInt64.self, forKey: .processStartIdentity)
        let decimal = try container.decodeIfPresent(String.self, forKey: .processStartIdentityDecimal)
        let windowID = try container.decodeIfPresent(Int.self, forKey: .windowID)
        guard processIdentifier > 0,
              processStartIdentity > 0,
              decimal == nil || decimal == String(processStartIdentity),
              windowID.map({ $0 > 0 }) ?? true
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .processStartIdentityDecimal,
                in: container,
                debugDescription: "Desktop action target receipt fields are inconsistent")
        }
        self.init(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            windowID: windowID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.processIdentifier, forKey: .processIdentifier)
        try container.encode(self.processStartIdentity, forKey: .processStartIdentity)
        try container.encode(String(self.processStartIdentity), forKey: .processStartIdentityDecimal)
        try container.encodeIfPresent(self.windowID, forKey: .windowID)
    }
}

/// User-facing failure context paired with a non-confirmed desktop action outcome.
public struct DesktopActionFailure: Codable, Equatable, LocalizedError, Sendable {
    public let outcome: DesktopActionOutcome
    public let message: String
    public let hint: String?
    public let causeDescription: String?
    public let targetReceipt: DesktopActionTargetReceipt?
    public let selectedLeafEvidence: [DesktopSelectedLeafEvidence]?

    public init?(
        outcome: DesktopActionOutcome,
        message: String,
        hint: String? = nil,
        causeDescription: String? = nil,
        targetReceipt: DesktopActionTargetReceipt? = nil,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil)
    {
        guard !outcome.isConfirmed,
              selectedLeafEvidence == nil || outcome.dispatchState.mutationDispatched,
              selectedLeafEvidence?.isEmpty != true,
              selectedLeafEvidence?.allSatisfy(\.isCanonical) != false
        else { return nil }
        self.outcome = outcome
        self.message = message
        self.hint = hint
        self.causeDescription = causeDescription
        self.targetReceipt = targetReceipt
        self.selectedLeafEvidence = selectedLeafEvidence
    }

    public static func partial(
        route: DesktopActionOutcome.Route = .local,
        delivery: DesktopActionOutcome.Delivery,
        unitCount: DesktopActionOutcome.DispatchUnitCount? = nil,
        message: String,
        hint: String? = nil,
        causeDescription: String? = nil) -> DesktopActionFailure
    {
        Self(
            validatedOutcome: .partial(route: route, delivery: delivery, unitCount: unitCount),
            message: message,
            hint: hint,
            causeDescription: causeDescription)
    }

    public static func dispatchedUnverified(
        route: DesktopActionOutcome.Route = .local,
        delivery: DesktopActionOutcome.Delivery,
        evidence: DesktopActionOutcome.DispatchedUnverifiedEvidence,
        unitCount: DesktopActionOutcome.DispatchUnitCount? = nil,
        message: String,
        hint: String? = nil,
        causeDescription: String? = nil) -> DesktopActionFailure
    {
        Self(
            validatedOutcome: .dispatchedUnverified(
                route: route,
                delivery: delivery,
                evidence: evidence,
                unitCount: unitCount),
            message: message,
            hint: hint,
            causeDescription: causeDescription)
    }

    public static func suspectedNoop(
        route: DesktopActionOutcome.Route = .local,
        delivery: DesktopActionOutcome.Delivery,
        unitCount: DesktopActionOutcome.DispatchUnitCount? = nil,
        message: String,
        hint: String? = nil,
        causeDescription: String? = nil) -> DesktopActionFailure
    {
        Self(
            validatedOutcome: .suspectedNoop(route: route, delivery: delivery, unitCount: unitCount),
            message: message,
            hint: hint,
            causeDescription: causeDescription)
    }

    public static func refused(
        route: DesktopActionOutcome.Route = .local,
        reason: DesktopActionOutcome.RefusalReason,
        message: String,
        hint: String? = nil,
        causeDescription: String? = nil) -> DesktopActionFailure
    {
        Self(
            validatedOutcome: .refused(route: route, reason: reason),
            message: message,
            hint: hint,
            causeDescription: causeDescription)
    }

    /// Constructs the canonical, retry-safe projection for a refusal before any mutation dispatch.
    public static func preDispatchRefusal(
        route: DesktopActionOutcome.Route = .local,
        reason: DesktopActionOutcome.RefusalReason,
        message: String,
        hint: String? = nil,
        causeDescription: String? = nil) -> DesktopActionFailure
    {
        .refused(
            route: route,
            reason: reason,
            message: message,
            hint: hint,
            causeDescription: causeDescription)
    }

    /// Fails a step only when its implementation reported a non-confirmed canonical outcome.
    /// Legacy implementations that report no outcome retain their existing compatibility behavior.
    public static func requireConfirmedIfReported(
        _ outcome: DesktopActionOutcome?,
        operation: String,
        hint: String = "Follow the canonical escalation metadata before deciding whether to retry.") throws
    {
        guard let outcome,
              let failure = Self(
                  outcome: outcome,
                  message: "\(operation) did not return a confirmed outcome.",
                  hint: hint)
        else { return }
        throw failure
    }

    public static func indeterminate(
        route: DesktopActionOutcome.Route = .local,
        delivery: DesktopActionOutcome.Delivery? = nil,
        evidence: DesktopActionOutcome.IndeterminateEvidence,
        unitCount: DesktopActionOutcome.DispatchUnitCount? = nil,
        message: String,
        hint: String? = nil,
        causeDescription: String? = nil) -> DesktopActionFailure
    {
        Self(
            validatedOutcome: .indeterminate(
                route: route,
                delivery: delivery,
                evidence: evidence,
                unitCount: unitCount),
            message: message,
            hint: hint,
            causeDescription: causeDescription)
    }

    private init(
        validatedOutcome outcome: DesktopActionOutcome,
        message: String,
        hint: String?,
        causeDescription: String?,
        targetReceipt: DesktopActionTargetReceipt? = nil,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil)
    {
        self.outcome = outcome
        self.message = message
        self.hint = hint
        self.causeDescription = causeDescription
        self.targetReceipt = targetReceipt
        self.selectedLeafEvidence = outcome.dispatchState.mutationDispatched ? selectedLeafEvidence : nil
    }

    public var errorDescription: String? {
        self.message
    }

    public var failureReason: String? {
        self.causeDescription
    }

    public var recoverySuggestion: String? {
        self.hint
    }

    /// Reassigns the route while preserving the validated failure state and its exact context.
    public func routed(to route: DesktopActionOutcome.Route) -> DesktopActionFailure {
        Self(
            validatedOutcome: self.outcome.routed(to: route),
            message: self.message,
            hint: self.hint,
            causeDescription: self.causeDescription,
            targetReceipt: self.targetReceipt,
            selectedLeafEvidence: self.selectedLeafEvidence)
    }

    /// Attaches a resolved target only after the execution owner has established it.
    public func attributed(to targetReceipt: DesktopActionTargetReceipt?) -> DesktopActionFailure {
        guard let targetReceipt else { return self }
        return Self(
            validatedOutcome: self.outcome,
            message: self.message,
            hint: self.hint,
            causeDescription: self.causeDescription,
            targetReceipt: targetReceipt,
            selectedLeafEvidence: self.selectedLeafEvidence)
    }

    /// Attaches the exact selected leaves only after at least one mutation crossed dispatch.
    public func selectingLeaves(_ evidence: [DesktopSelectedLeafEvidence]?) -> DesktopActionFailure {
        guard self.outcome.dispatchState.mutationDispatched,
              let evidence,
              !evidence.isEmpty,
              evidence.allSatisfy(\.isCanonical)
        else { return self }
        return Self(
            validatedOutcome: self.outcome,
            message: self.message,
            hint: self.hint,
            causeDescription: self.causeDescription,
            targetReceipt: self.targetReceipt,
            selectedLeafEvidence: evidence)
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case message
        case hint
        case causeDescription = "cause_description"
        case targetReceipt = "target_receipt"
        case selectedLeafEvidence = "selected_leaf_evidence"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decode(DesktopActionOutcome.self, forKey: .outcome)
        guard !outcome.isConfirmed else {
            throw DecodingError.dataCorruptedError(
                forKey: .outcome,
                in: container,
                debugDescription: "DesktopActionFailure cannot carry a confirmed outcome")
        }
        self.outcome = outcome
        self.message = try container.decode(String.self, forKey: .message)
        self.hint = try container.decodeIfPresent(String.self, forKey: .hint)
        self.causeDescription = try container.decodeIfPresent(String.self, forKey: .causeDescription)
        self.targetReceipt = try container.decodeIfPresent(DesktopActionTargetReceipt.self, forKey: .targetReceipt)
        self.selectedLeafEvidence = try container.decodeIfPresent(
            [DesktopSelectedLeafEvidence].self,
            forKey: .selectedLeafEvidence)
        guard self.selectedLeafEvidence == nil || outcome.dispatchState.mutationDispatched,
              self.selectedLeafEvidence?.isEmpty != true,
              self.selectedLeafEvidence?.allSatisfy(\.isCanonical) != false
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .selectedLeafEvidence,
                in: container,
                debugDescription: "Selected-leaf failure evidence requires a dispatched mutation")
        }
    }
}
