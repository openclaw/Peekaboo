import PeekabooCore
import PeekabooFoundation

@MainActor
func commandActionRoute(for services: any PeekabooServiceProviding) -> DesktopActionOutcome.Route {
    services.executionHost == .remote ? .bridge : .local
}

/// Command-layer composition for setup actions followed by one or more mutation leaves.
///
/// `DesktopActionSequenceAccumulator` owns outcome semantics. This wrapper keeps the matching
/// stable target identity beside it so a successful focus cannot be erased by a later refusal,
/// and two successful phases cannot silently claim different targets.
@MainActor
final class CommandActionSequenceAccumulator {
    private var sequence = DesktopActionSequenceAccumulator()
    private var targetIdentityIsConsistent = true
    private(set) var targetIdentity: DesktopTargetIdentity?

    var mutationDisposition: DesktopActionMutationDisposition {
        self.sequence.mutationDisposition
    }

    var resolution: DesktopActionSequenceAccumulator.Resolution {
        self.sequence.successResolution()
    }

    func record(
        _ result: UIAutomationActionResult<some Sendable>,
        operation: String = "Desktop action",
        receiptlessStep: DesktopActionSequenceAccumulator.Step? = nil
    ) throws {
        try self.record(
            outcome: result.outcome,
            targetIdentity: result.targetIdentity,
            operation: operation,
            receiptlessStep: receiptlessStep
        )
    }

    func record(
        outcome: DesktopActionOutcome?,
        targetIdentity: DesktopTargetIdentity? = nil,
        operation: String = "Desktop action",
        receiptlessStep: DesktopActionSequenceAccumulator.Step? = nil
    ) throws {
        if let outcome {
            try Self.requireSuccessfulOutcome(
                outcome,
                targetReceipt: targetIdentity?.actionTargetReceipt,
                operation: operation
            )
            self.sequence.record(.reportedOutcome(outcome, defaultDispatchedUnitCount: .one))
        } else if let receiptlessStep {
            self.sequence.record(receiptlessStep)
        }

        guard let targetIdentity else { return }
        do {
            self.targetIdentity = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.coalesce([
                self.targetIdentity,
                targetIdentity,
            ])
        } catch {
            // Once two completed phases disagree, no target may be projected for the aggregate.
            self.targetIdentity = nil
            self.targetIdentityIsConsistent = false
            throw error
        }
    }

    /// Records a leaf whose target must come from the leaf result rather than an earlier setup phase.
    ///
    /// Legacy foreground providers can complete an action without returning exact target evidence. In
    /// that case the action outcome remains useful, but a setup-focus target must not be projected as
    /// though the leaf had attested it.
    func recordExactTargetLeaf(
        outcome: DesktopActionOutcome?,
        targetIdentity: DesktopTargetIdentity?,
        operation: String,
        receiptlessStep: DesktopActionSequenceAccumulator.Step? = nil
    ) throws {
        if targetIdentity == nil {
            self.targetIdentity = nil
            self.targetIdentityIsConsistent = false
        }
        try self.record(
            outcome: outcome,
            targetIdentity: targetIdentity,
            operation: operation,
            receiptlessStep: receiptlessStep
        )
    }

    func result<Payload: Sendable>(payload: Payload) -> UIAutomationActionResult<Payload> {
        UIAutomationActionResult(
            payload: payload,
            outcome: self.resolution.outcome,
            targetIdentity: self.targetIdentityIsConsistent ? self.targetIdentity : nil
        )
    }

    func preservingFailure(
        _ error: any Error,
        fallbackRoute: DesktopActionOutcome.Route,
        message: String,
        hint: String
    ) -> any Error {
        guard self.sequence.mutationDisposition.mutationDispatched else { return error }

        let leafFailure: DesktopActionFailure = if let failure = error as? DesktopActionFailure {
            failure
        } else {
            .preDispatchRefusal(
                route: fallbackRoute,
                reason: .targetUnavailable,
                message: error.localizedDescription,
                causeDescription: String(describing: error)
            )
        }
        let composite = self.sequence.failure(
            combining: leafFailure,
            message: message,
            hint: hint,
            causeDescription: leafFailure.causeDescription ?? error.localizedDescription
        )
        return composite.attributed(to: self.aggregateTarget(with: leafFailure))
    }

    private func aggregateTarget(with leafFailure: DesktopActionFailure) -> DesktopActionTargetReceipt? {
        guard self.targetIdentityIsConsistent else { return nil }
        let priorTarget = self.targetIdentity?.actionTargetReceipt
        switch (
            self.sequence.mutationDisposition.mutationDispatched,
            leafFailure.outcome.dispatchState.mutationDispatched
        ) {
        case (true, true):
            guard priorTarget != nil, leafFailure.targetReceipt != nil else { return nil }
            return Self.compatibleTarget(priorTarget, leafFailure.targetReceipt)
        case (true, false):
            return priorTarget
        case (false, true):
            return leafFailure.targetReceipt
        case (false, false):
            return Self.compatibleTarget(priorTarget, leafFailure.targetReceipt)
        }
    }

    private static func compatibleTarget(
        _ prior: DesktopActionTargetReceipt?,
        _ later: DesktopActionTargetReceipt?
    ) -> DesktopActionTargetReceipt? {
        switch (prior, later) {
        case let (prior?, later?):
            guard prior.processIdentifier == later.processIdentifier,
                  prior.processStartIdentity == later.processStartIdentity
            else { return nil }
            if prior.windowID == later.windowID {
                return prior
            }
            guard prior.windowID == nil || later.windowID == nil else { return nil }
            return DesktopActionTargetReceipt(
                processIdentifier: prior.processIdentifier,
                processStartIdentity: prior.processStartIdentity
            )
        case let (target?, nil), let (nil, target?):
            return target
        case (nil, nil):
            return nil
        }
    }

    private static func requireSuccessfulOutcome(
        _ outcome: DesktopActionOutcome,
        targetReceipt: DesktopActionTargetReceipt?,
        operation: String
    ) throws {
        guard !outcome.isAccepted(by: .confirmedOrDispatched) else { return }
        guard let failure = DesktopActionFailure(
            outcome: outcome,
            message: "\(operation) did not return a successful outcome.",
            hint: "Follow the canonical escalation metadata before deciding whether to retry.",
            targetReceipt: targetReceipt
        )
        else {
            preconditionFailure("A non-success outcome must construct a desktop action failure")
        }
        throw failure
    }
}
