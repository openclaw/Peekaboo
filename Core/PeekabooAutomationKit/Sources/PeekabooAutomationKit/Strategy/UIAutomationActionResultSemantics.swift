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

        fileprivate var expectedIdentity: DesktopTargetIdentity? {
            guard case let .exact(identity) = self else { return nil }
            return identity
        }
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
        rejectedOutcomeHint: String =
            "Follow the canonical escalation metadata before deciding whether to retry.") throws
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
                rejectedOutcomeHint: rejectedOutcomeHint)
        }

        try self.validateTarget(
            result.targetIdentity,
            outcome: outcome,
            requirement: targetRequirement,
            operation: operation,
            message: missingTargetMessage,
            hint: missingTargetHint)

        return try self.requireAcceptedOutcome(
            outcome,
            policy: policy,
            operation: operation,
            targetReceipt: result.actionTargetReceipt ?? targetRequirement.expectedIdentity?.actionTargetReceipt,
            missingOutcomeMessage: missingOutcomeMessage,
            rejectedOutcomeMessage: rejectedOutcomeMessage,
            missingOutcomeHint: missingOutcomeHint,
            rejectedOutcomeHint: rejectedOutcomeHint)
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
            "Follow the canonical escalation metadata before deciding whether to retry.") throws
        -> DesktopActionOutcome
    {
        guard let outcome else {
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
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
                    message: rejectedOutcomeMessage ??
                        "\(operation) returned a confirmed outcome with disallowed delivery semantics.",
                    hint: rejectedOutcomeHint)
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

    public static func validateTarget(
        _ identity: DesktopTargetIdentity?,
        outcome: DesktopActionOutcome?,
        requirement: TargetRequirement,
        operation: String,
        message: String? = nil,
        hint: String = "Observe the target before retrying and update the runtime host.") throws
    {
        let targetMatches: Bool = switch requirement {
        case .optional:
            true
        case .required:
            identity != nil
        case let .exact(expected):
            identity == expected
        }
        guard !targetMatches else { return }
        if outcome?.state == .refused,
           outcome?.dispatchState == DesktopActionOutcome.DispatchState.none
        {
            return
        }

        let expectedReceipt = requirement.expectedIdentity?.actionTargetReceipt
        throw DesktopActionFailure.indeterminate(
            route: outcome?.route ?? .local,
            delivery: outcome?.delivery,
            evidence: .completionUnknown,
            unitCount: outcome?.dispatchState.unitCount,
            message: message ?? "\(operation) returned without its required target identity.",
            hint: hint)
            .attributed(to: expectedReceipt)
    }
}

extension DesktopTargetIdentity {
    public var actionTargetReceipt: DesktopActionTargetReceipt {
        if let exactWindow = self.exactWindow {
            return DesktopActionTargetReceipt(
                processIdentifier: exactWindow.identity.ownerProcessIdentifier,
                processStartIdentity: exactWindow.identity.ownerProcessStartIdentity,
                windowID: exactWindow.identity.windowID)
        }
        return DesktopActionTargetReceipt(
            processIdentifier: self.processIdentity.processIdentifier,
            processStartIdentity: self.processIdentity.processStartIdentity)
    }
}

extension UIAutomationActionResult {
    public var actionTargetReceipt: DesktopActionTargetReceipt? {
        self.targetIdentity?.actionTargetReceipt
    }
}
