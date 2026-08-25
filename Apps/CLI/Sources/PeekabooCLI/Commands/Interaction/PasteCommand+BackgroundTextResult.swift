import PeekabooCore
import PeekabooFoundation

extension PasteCommand {
    static func pasteDelivery(for target: UIAutomationTarget) -> DesktopActionOutcome.Delivery {
        UIAutomationActionResultSemantics.keyboardDelivery(for: target)
    }

    static func pasteTargetReceipt(for target: UIAutomationTarget) -> DesktopActionTargetReceipt? {
        try? UIAutomationActionResultSemantics.actionTargetReceipt(for: target)
    }

    static func validateBackgroundTextResult(
        _ result: UIAutomationActionResult<TypeResult>,
        authorizedTarget: UIAutomationTarget
    ) throws -> DesktopTargetIdentity {
        guard let authorizedIdentity = try UIAutomationActionResultSemantics.targetIdentity(for: authorizedTarget)
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Background text paste has no process-generation authorization.",
                hint: "Refresh the application inventory before retrying."
            )
        }
        let resultTargetIdentity = try UIAutomationActionResultSemantics.validateTarget(
            result.targetIdentity,
            outcome: result.outcome,
            requirement: .compatible(authorizedIdentity),
            operation: "Background text paste",
            message: "Background text paste returned without its target identity.",
            hint: "Observe the exact target before retrying and update the runtime host.",
            contradictoryMessage: "Background text paste returned a target different from its authorization.",
            fallbackDelivery: self.pasteDelivery(for: authorizedTarget)
        )
        _ = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
            result.outcome,
            policy: .confirmed(requiring: .background),
            operation: "Background text paste",
            targetReceipt: resultTargetIdentity?.actionTargetReceipt ?? authorizedIdentity.actionTargetReceipt,
            missingOutcomeMessage: "Background text paste returned without a canonical outcome.",
            rejectedOutcomeMessage: "Background text paste did not return a confirmed outcome.",
            missingOutcomeHint: "Observe the exact target before retrying and update the runtime host.",
            disallowedDeliveryMessage: "Background text paste reported foreground delivery.",
            disallowedDeliveryHint: "Observe the exact target before retrying and update the runtime host.",
            missingOutcomeDelivery: self.pasteDelivery(for: authorizedTarget),
            missingOutcomeUnitCount: .one
        )
        guard let resultTargetIdentity else {
            preconditionFailure("An accepted background text outcome must retain one coalesced target identity")
        }
        return resultTargetIdentity
    }
}
