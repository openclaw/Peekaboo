import CoreGraphics
import PeekabooAutomation
import PeekabooFoundation

@MainActor
enum MCPGlobalPointerActionResult {
    private static let delivery = DesktopActionOutcome.Delivery(
        mechanism: .globalEvents,
        mode: .foreground)

    static func drag(
        automation: any UIAutomationServiceProtocol,
        request: DragOperationRequest) async throws -> UIAutomationActionResult<Void>
    {
        if let results = automation as? any UIAutomationGlobalPointerActionResultProviding {
            return try await results.dragWithOutcome(request)
        }
        try await automation.drag(request)
        return UIAutomationActionResult(payload: (), outcome: nil)
    }

    static func move(
        automation: any UIAutomationServiceProtocol,
        to point: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws -> UIAutomationActionResult<Void>
    {
        if let results = automation as? any UIAutomationGlobalPointerActionResultProviding {
            return try await results.moveMouseWithOutcome(
                to: point,
                duration: duration,
                steps: steps,
                profile: profile)
        }
        try await automation.moveMouse(to: point, duration: duration, steps: steps, profile: profile)
        return UIAutomationActionResult(payload: (), outcome: nil)
    }

    static func compose(
        setupFocus: MCPInteractionFocusResult?,
        pointerAction: UIAutomationActionResult<Void>,
        operation: String,
        route: DesktopActionOutcome.Route) throws -> UIAutomationActionResult<Void>
    {
        if let outcome = pointerAction.outcome {
            _ = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
                outcome,
                policy: .confirmedOrDispatched(requiring: .foreground),
                operation: operation,
                rejectedOutcomeMessage: "\(operation) did not return a successful outcome.",
                rejectedOutcomeHint: "Follow the canonical outcome metadata before deciding whether to retry.")
        }
        if pointerAction.targetIdentity != nil {
            let outcome = pointerAction.outcome
            let failure = DesktopActionFailure.indeterminate(
                route: outcome?.route ?? route,
                delivery: outcome?.delivery ?? self.delivery,
                evidence: .completionUnknown,
                unitCount: outcome?.dispatchState.unitCount ?? .one,
                message: "\(operation) returned an exact target for a global pointer mutation.",
                hint: "Observe the desktop before retrying and update the runtime host.")
            throw failure
        }

        var sequence = DesktopActionSequenceAccumulator()
        setupFocus?.record(into: &sequence)
        if let outcome = pointerAction.outcome {
            sequence.record(.reportedOutcome(outcome, defaultDispatchedUnitCount: .one))
        } else {
            sequence.record(.dispatched(
                route: route,
                delivery: self.delivery,
                unitCount: .one))
        }
        guard let outcome = sequence.successResolution().outcome else {
            let failure = DesktopActionFailure.indeterminate(
                route: route,
                delivery: self.delivery,
                evidence: .completionUnknown,
                unitCount: sequence.mutationDisposition.unitCount,
                message: "\(operation) completed without one canonical aggregate outcome.",
                hint: "Observe the desktop before retrying and update the runtime host.")
            throw failure
        }
        return UIAutomationActionResult(payload: (), outcome: outcome, targetIdentity: nil)
    }

    static func failure(
        _ error: any Error,
        setupFocus: MCPInteractionFocusResult?,
        operation: String,
        route: DesktopActionOutcome.Route) -> DesktopActionFailure
    {
        let leaf = error as? DesktopActionFailure ?? .indeterminate(
            route: route,
            delivery: self.delivery,
            evidence: .completionUnknown,
            unitCount: .one,
            message: "\(operation) failed after global pointer delivery may have begun.",
            hint: "Observe the desktop before retrying; replaying may repeat the action.",
            causeDescription: error.localizedDescription)
        return setupFocus?.preservingGlobalFailure(leaf, operation: operation) ?? leaf
    }

    static func route(for context: MCPToolContext) -> DesktopActionOutcome.Route {
        context.executionHost == .remote ? .bridge : .local
    }
}
