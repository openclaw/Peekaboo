import PeekabooCore
import PeekabooFoundation

extension PasteCommand {
    static func pasteDelivery(for target: UIAutomationTarget) -> DesktopActionOutcome.Delivery {
        if target.exactWindow != nil {
            return .init(mechanism: .windowTargetedEvents, mode: .background)
        }
        if target.processIdentity != nil {
            return .init(mechanism: .processTargetedEvents, mode: .background)
        }
        return .init(mechanism: .globalEvents, mode: .foreground)
    }

    static func pasteTargetReceipt(for target: UIAutomationTarget) -> DesktopActionTargetReceipt? {
        if let exactWindow = target.exactWindow {
            return DesktopActionTargetReceipt(
                processIdentifier: exactWindow.identity.ownerProcessIdentifier,
                processStartIdentity: exactWindow.identity.ownerProcessStartIdentity,
                windowID: exactWindow.identity.windowID
            )
        }
        guard let processIdentity = target.processIdentity else { return nil }
        return DesktopActionTargetReceipt(
            processIdentifier: processIdentity.processIdentifier,
            processStartIdentity: processIdentity.processStartIdentity
        )
    }

    static func validateBackgroundTextResult(
        _ result: UIAutomationActionResult<TypeResult>,
        authorizedTarget: UIAutomationTarget
    ) throws -> DesktopTargetIdentity {
        let authorizedIdentity = try self.desktopTargetIdentity(for: authorizedTarget)
        let authorizedReceipt = self.pasteTargetReceipt(for: authorizedTarget)
        guard let returnedIdentity = result.targetIdentity else {
            throw DesktopActionFailure.indeterminate(
                route: result.outcome?.route ?? .local,
                delivery: result.outcome?.delivery ?? self.pasteDelivery(for: authorizedTarget),
                evidence: .completionUnknown,
                unitCount: result.outcome?.dispatchState.unitCount ?? .one,
                message: "Background text paste returned without its target identity.",
                hint: "Observe the exact target before retrying and update the runtime host."
            )
            .attributed(to: authorizedReceipt)
        }
        let resultTargetIdentity: DesktopTargetIdentity
        do {
            resultTargetIdentity = try authorizedIdentity.coalescing(returnedIdentity)
        } catch {
            // Contradictory provider targets cannot safely be attributed to either claimed target.
            throw DesktopActionFailure.indeterminate(
                route: result.outcome?.route ?? .local,
                delivery: result.outcome?.delivery ?? self.pasteDelivery(for: authorizedTarget),
                evidence: .completionUnknown,
                unitCount: result.outcome?.dispatchState.unitCount ?? .one,
                message: "Background text paste returned a target different from its authorization.",
                hint: "Observe both targets before retrying and update the runtime host.",
                causeDescription: error.localizedDescription
            )
        }
        let resultReceipt = self.pasteTargetReceipt(for: resultTargetIdentity.target)
        guard let outcome = result.outcome else {
            throw DesktopActionFailure.indeterminate(
                delivery: self.pasteDelivery(for: authorizedTarget),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Background text paste returned without a canonical outcome.",
                hint: "Observe the exact target before retrying and update the runtime host."
            )
            .attributed(to: resultReceipt)
        }
        if let failure = DesktopActionFailure(
            outcome: outcome,
            message: "Background text paste did not return a confirmed outcome.",
            hint: "Follow the canonical escalation metadata before deciding whether to retry.",
            targetReceipt: resultReceipt
        ) {
            throw failure
        }
        return resultTargetIdentity
    }

    private static func desktopTargetIdentity(for target: UIAutomationTarget) throws -> DesktopTargetIdentity {
        if let exactWindow = target.exactWindow {
            return DesktopTargetIdentity(exactWindow: exactWindow)
        }
        guard let processIdentity = target.processIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Background text paste has no process-generation authorization.",
                hint: "Refresh the application inventory before retrying."
            )
        }
        return try DesktopTargetIdentity(processIdentity: processIdentity)
    }
}
