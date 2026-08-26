import Foundation
import PeekabooFoundation

/// Shared target and outcome validation for result-aware automation consumers.
///
/// Providers own the result facts. Consumers select an explicit acceptance policy and target
/// requirement instead of repeating the action-state matrix or rebuilding target receipts.
public enum UIAutomationActionResultSemantics {
    public enum TargetRequirement: Equatable, Sendable {
        case optional
        case required
        case exact(DesktopTargetIdentity)
        /// The provider target may add compatible evidence, such as refining a process to an exact window.
        case compatible(DesktopTargetIdentity)

        fileprivate var expectedIdentity: DesktopTargetIdentity? {
            switch self {
            case .optional, .required:
                nil
            case let .exact(identity), let .compatible(identity):
                identity
            }
        }
    }

    /// Projects a native input destination to its stable process/window identity when one exists.
    public static func targetIdentity(for target: UIAutomationTarget) throws -> DesktopTargetIdentity? {
        switch target {
        case .foreground:
            nil
        case let .process(process):
            try process.identity.map { try DesktopTargetIdentity(processIdentity: $0) }
        case let .exactWindow(window):
            DesktopTargetIdentity(exactWindow: window)
        }
    }

    public static func actionTargetReceipt(for target: UIAutomationTarget) throws -> DesktopActionTargetReceipt? {
        try self.targetIdentity(for: target)?.actionTargetReceipt
    }

    public static func keyboardDelivery(for target: UIAutomationTarget) -> DesktopActionOutcome.Delivery {
        target.keyboardDelivery
    }

    /// Applies one acceptance policy to a result pinned to an exact process generation.
    ///
    /// A provider refusal before dispatch remains authoritative even when target evidence is absent
    /// or contradictory. After dispatch, contradictory target evidence takes precedence over the
    /// provider outcome, while a missing target is reported only after accepting the outcome.
    @discardableResult
    public static func requireAcceptedExactProcessResult(
        _ result: UIAutomationActionResult<some Sendable>,
        expectedIdentity: ApplicationProcessIdentity,
        policy: DesktopActionOutcome.SuccessPolicy,
        operation: String,
        missingOutcomeMessage: String? = nil,
        missingTargetMessage: String? = nil,
        contradictoryTargetMessage: String? = nil,
        rejectedOutcomeMessage: String? = nil,
        missingOutcomeHint: String = "Observe the target before retrying and update the runtime host.",
        targetHint: String = "Observe the target before retrying and update the runtime host.",
        rejectedOutcomeHint: String =
            "Follow the canonical escalation metadata before deciding whether to retry.") throws
        -> DesktopActionOutcome
    {
        guard let outcome = result.outcome else {
            return try self.requireAcceptedOutcome(
                result.outcome,
                policy: policy,
                operation: operation,
                missingOutcomeMessage: missingOutcomeMessage,
                missingOutcomeHint: missingOutcomeHint,
                rejectedOutcomeHint: rejectedOutcomeHint)
        }
        if outcome.state == .refused, outcome.dispatchState == .none {
            return try self.requireAcceptedOutcome(
                outcome,
                policy: policy,
                operation: operation,
                rejectedOutcomeMessage: rejectedOutcomeMessage,
                rejectedOutcomeHint: rejectedOutcomeHint)
        }
        if let returnedIdentity = result.targetIdentity?.processIdentity,
           returnedIdentity != expectedIdentity
        {
            throw DesktopActionFailure.indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: contradictoryTargetMessage ?? "\(operation) returned a contradictory process target.",
                hint: targetHint)
        }

        let acceptedOutcome = try self.requireAcceptedOutcome(
            outcome,
            policy: policy,
            operation: operation,
            targetReceipt: expectedIdentity.actionTargetReceipt,
            rejectedOutcomeMessage: rejectedOutcomeMessage,
            rejectedOutcomeHint: rejectedOutcomeHint)
        guard result.targetIdentity?.processIdentity == expectedIdentity else {
            throw DesktopActionFailure.indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: missingTargetMessage ?? "\(operation) returned without its exact process target.",
                hint: targetHint)
        }
        return acceptedOutcome
    }

    public static func requireAcceptedOutcome(
        _ result: UIAutomationActionResult<some Sendable>,
        policy: DesktopActionOutcome.SuccessPolicy,
        targetRequirement: TargetRequirement = .optional,
        operation: String,
        missingOutcomeMessage: String? = nil,
        missingTargetMessage: String? = nil,
        rejectedOutcomeMessage: String? = nil,
        missingOutcomeHint: String = "Observe the target before retrying and update the runtime host.",
        missingTargetHint: String = "Observe the target before retrying and update the runtime host.",
        contradictoryTargetMessage: String? = nil,
        contradictoryTargetHint: String = "Observe both targets before retrying and update the runtime host.",
        rejectedOutcomeHint: String =
            "Follow the canonical escalation metadata before deciding whether to retry.",
        disallowedDeliveryMessage: String? = nil,
        disallowedDeliveryHint: String? = nil,
        missingOutcomeRoute: DesktopActionOutcome.Route = .local,
        missingOutcomeDelivery: DesktopActionOutcome.Delivery? = nil,
        missingOutcomeUnitCount: DesktopActionOutcome.DispatchUnitCount? = nil) throws
        -> DesktopActionOutcome
    {
        guard let outcome = result.outcome else {
            return try self.requireAcceptedOutcome(
                nil,
                policy: policy,
                operation: operation,
                targetReceipt: targetRequirement.expectedIdentity?.actionTargetReceipt,
                missingOutcomeMessage: missingOutcomeMessage,
                rejectedOutcomeMessage: rejectedOutcomeMessage,
                missingOutcomeHint: missingOutcomeHint,
                rejectedOutcomeHint: rejectedOutcomeHint,
                disallowedDeliveryMessage: disallowedDeliveryMessage,
                disallowedDeliveryHint: disallowedDeliveryHint,
                missingOutcomeRoute: missingOutcomeRoute,
                missingOutcomeDelivery: missingOutcomeDelivery,
                missingOutcomeUnitCount: missingOutcomeUnitCount)
        }

        try self.validateTarget(
            result.targetIdentity,
            outcome: outcome,
            requirement: targetRequirement,
            operation: operation,
            message: missingTargetMessage,
            hint: missingTargetHint,
            contradictoryMessage: contradictoryTargetMessage,
            contradictoryHint: contradictoryTargetHint,
            fallbackDelivery: missingOutcomeDelivery)

        return try self.requireAcceptedOutcome(
            outcome,
            policy: policy,
            operation: operation,
            targetReceipt: result.actionTargetReceipt ?? targetRequirement.expectedIdentity?.actionTargetReceipt,
            missingOutcomeMessage: missingOutcomeMessage,
            rejectedOutcomeMessage: rejectedOutcomeMessage,
            missingOutcomeHint: missingOutcomeHint,
            rejectedOutcomeHint: rejectedOutcomeHint,
            disallowedDeliveryMessage: disallowedDeliveryMessage,
            disallowedDeliveryHint: disallowedDeliveryHint,
            missingOutcomeRoute: missingOutcomeRoute,
            missingOutcomeDelivery: missingOutcomeDelivery,
            missingOutcomeUnitCount: missingOutcomeUnitCount)
    }

    public static func requireAcceptedOutcome(
        _ outcome: DesktopActionOutcome?,
        policy: DesktopActionOutcome.SuccessPolicy,
        operation: String,
        targetReceipt: DesktopActionTargetReceipt? = nil,
        missingOutcomeMessage: String? = nil,
        rejectedOutcomeMessage: String? = nil,
        missingOutcomeHint: String = "Observe the target before retrying and update the runtime host.",
        rejectedOutcomeHint: String =
            "Follow the canonical escalation metadata before deciding whether to retry.",
        disallowedDeliveryMessage: String? = nil,
        disallowedDeliveryHint: String? = nil,
        missingOutcomeRoute: DesktopActionOutcome.Route = .local,
        missingOutcomeDelivery: DesktopActionOutcome.Delivery? = nil,
        missingOutcomeUnitCount: DesktopActionOutcome.DispatchUnitCount? = nil) throws
        -> DesktopActionOutcome
    {
        guard let outcome else {
            throw DesktopActionFailure.indeterminate(
                route: missingOutcomeRoute,
                delivery: missingOutcomeDelivery,
                evidence: .completionUnknown,
                unitCount: missingOutcomeUnitCount,
                message: missingOutcomeMessage ?? "\(operation) returned without a canonical outcome.",
                hint: missingOutcomeHint)
                .attributed(to: targetReceipt)
        }
        guard policy.accepts(outcome) else {
            if outcome.isConfirmed {
                throw DesktopActionFailure.indeterminate(
                    route: outcome.route,
                    delivery: outcome.delivery,
                    evidence: .completionUnknown,
                    unitCount: outcome.dispatchState.unitCount,
                    message: disallowedDeliveryMessage ?? rejectedOutcomeMessage ??
                        "\(operation) returned a confirmed outcome with disallowed delivery semantics.",
                    hint: disallowedDeliveryHint ?? rejectedOutcomeHint)
                    .attributed(to: targetReceipt)
            }
            guard let failure = DesktopActionFailure(
                outcome: outcome,
                message: rejectedOutcomeMessage ?? "\(operation) did not return an accepted outcome.",
                hint: rejectedOutcomeHint,
                targetReceipt: targetReceipt)
            else {
                preconditionFailure("A rejected non-confirmed outcome must construct a failure")
            }
            throw failure
        }
        return outcome
    }

    /// Requires proof that a mutation changed its destination, rather than merely confirming that
    /// no work occurred. This is the appropriate boundary for non-idempotent requests such as
    /// typing non-empty text, where `confirmedNoChange` cannot satisfy the caller's intent.
    public static func requireConfirmedChange(
        _ result: UIAutomationActionResult<some Sendable>,
        deliveryMode: DesktopActionOutcome.Delivery.Mode,
        targetRequirement: TargetRequirement = .optional,
        operation: String) throws -> DesktopActionOutcome
    {
        let outcome = try self.requireAcceptedOutcome(
            result,
            policy: .confirmed(requiring: deliveryMode),
            targetRequirement: targetRequirement,
            operation: operation)
        guard outcome.state == .confirmedChange else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: outcome.route,
                reason: .targetUnavailable,
                message: "\(operation) did not confirm any change at its destination.",
                hint: "Observe the target before deciding whether to retry.")
                .attributed(to: result.actionTargetReceipt ?? targetRequirement.expectedIdentity?.actionTargetReceipt)
        }
        return outcome
    }

    @discardableResult
    public static func validateTarget(
        _ identity: DesktopTargetIdentity?,
        outcome: DesktopActionOutcome?,
        requirement: TargetRequirement,
        operation: String,
        message: String? = nil,
        hint: String = "Observe the target before retrying and update the runtime host.",
        contradictoryMessage: String? = nil,
        contradictoryHint: String = "Observe both targets before retrying and update the runtime host.",
        fallbackDelivery: DesktopActionOutcome.Delivery? = nil) throws -> DesktopTargetIdentity?
    {
        if identity == nil,
           outcome?.state == .refused,
           outcome?.dispatchState == DesktopActionOutcome.DispatchState.none
        {
            return nil
        }
        if case let .compatible(expected) = requirement {
            guard let identity else {
                throw DesktopActionFailure.indeterminate(
                    route: outcome?.route ?? .local,
                    delivery: outcome?.delivery ?? fallbackDelivery,
                    evidence: .completionUnknown,
                    unitCount: outcome?.dispatchState.unitCount ?? .one,
                    message: message ?? "\(operation) returned without its required target identity.",
                    hint: hint)
                    .attributed(to: expected.actionTargetReceipt)
            }
            do {
                return try expected.coalescing(identity)
            } catch {
                throw DesktopActionFailure.indeterminate(
                    route: outcome?.route ?? .local,
                    delivery: outcome?.delivery ?? fallbackDelivery,
                    evidence: .completionUnknown,
                    unitCount: outcome?.dispatchState.unitCount ?? .one,
                    message: contradictoryMessage ?? "\(operation) returned a contradictory target identity.",
                    hint: contradictoryHint,
                    causeDescription: error.localizedDescription)
                    .attributed(to: expected.actionTargetReceipt)
            }
        }

        let targetMatches: Bool = switch requirement {
        case .optional:
            true
        case .required:
            identity != nil
        case let .exact(expected):
            identity == expected
        case .compatible:
            preconditionFailure("Compatible targets are resolved before exact target matching")
        }
        guard !targetMatches else { return identity }
        if outcome?.state == .refused,
           outcome?.dispatchState == DesktopActionOutcome.DispatchState.none
        {
            return identity
        }

        let expectedReceipt = requirement.expectedIdentity?.actionTargetReceipt
        throw DesktopActionFailure.indeterminate(
            route: outcome?.route ?? .local,
            delivery: outcome?.delivery ?? fallbackDelivery,
            evidence: .completionUnknown,
            unitCount: outcome?.dispatchState.unitCount,
            message: message ?? "\(operation) returned without its required target identity.",
            hint: hint)
            .attributed(to: expectedReceipt)
    }
}

extension UIAutomationActionResult {
    public var actionTargetReceipt: DesktopActionTargetReceipt? {
        self.targetIdentity?.actionTargetReceipt
    }
}
