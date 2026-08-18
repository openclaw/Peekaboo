import PeekabooCore
import PeekabooFoundation

@MainActor
func commandActionRoute(for services: any PeekabooServiceProviding) -> DesktopActionOutcome.Route {
    services.executionHost == .remote ? .bridge : .local
}

/// Command-layer composition for setup actions followed by one or more mutation leaves.
///
/// `UIAutomationActionResultSequenceAccumulator` owns outcome and target composition. This wrapper
/// retains the command-facing validation and result surface used by the CLI.
@MainActor
final class CommandActionSequenceAccumulator {
    private struct MissingReceiptPolicy {
        let receiptlessStep: DesktopActionSequenceAccumulator.Step?
        let defaultDispatchedUnitCount: DesktopActionOutcome.DispatchUnitCount?
    }

    private var sequence = UIAutomationActionResultSequenceAccumulator(
        targetProjectionPolicy: .coalescedIdentity
    )
    private(set) var targetIdentity: DesktopTargetIdentity?

    var mutationDisposition: DesktopActionMutationDisposition {
        self.sequence.resolution.mutationDisposition
    }

    var resolution: DesktopActionSequenceAccumulator.Resolution {
        self.sequence.sequenceResolution
    }

    func record(
        _ result: UIAutomationActionResult<some Sendable>,
        operation: String = "Desktop action",
        receiptlessStep: DesktopActionSequenceAccumulator.Step? = nil,
        defaultDispatchedUnitCount: DesktopActionOutcome.DispatchUnitCount? = .one
    ) throws {
        try self.record(
            outcome: result.outcome,
            targetIdentity: result.targetIdentity,
            operation: operation,
            receiptlessStep: receiptlessStep,
            defaultDispatchedUnitCount: defaultDispatchedUnitCount
        )
    }

    func record(
        outcome: DesktopActionOutcome?,
        targetIdentity: DesktopTargetIdentity? = nil,
        operation: String = "Desktop action",
        receiptlessStep: DesktopActionSequenceAccumulator.Step? = nil,
        defaultDispatchedUnitCount: DesktopActionOutcome.DispatchUnitCount? = .one
    ) throws {
        try self.record(
            outcome: outcome,
            targetIdentity: targetIdentity,
            attribution: .sequenceTarget,
            operation: operation,
            missingReceiptPolicy: MissingReceiptPolicy(
                receiptlessStep: receiptlessStep,
                defaultDispatchedUnitCount: defaultDispatchedUnitCount
            )
        )
    }

    private func record(
        outcome: DesktopActionOutcome?,
        targetIdentity: DesktopTargetIdentity?,
        attribution: UIAutomationActionResultSequenceAccumulator.PhaseAttributionRule,
        operation: String,
        missingReceiptPolicy: MissingReceiptPolicy
    ) throws {
        if let outcome {
            try Self.requireSuccessfulOutcome(
                outcome,
                targetReceipt: targetIdentity?.actionTargetReceipt,
                operation: operation
            )
        }

        let step = outcome.map { outcome in
            missingReceiptPolicy.defaultDispatchedUnitCount.map {
                DesktopActionSequenceAccumulator.Step.reportedOutcome(
                    outcome,
                    defaultDispatchedUnitCount: $0
                )
            } ?? .outcome(outcome)
        } ?? missingReceiptPolicy.receiptlessStep
        let effectiveAttribution: UIAutomationActionResultSequenceAccumulator.PhaseAttributionRule =
            attribution == .requiredTarget && targetIdentity != nil ? .sequenceTarget : attribution
        let priorConflict = self.sequence.resolution.targetConflictError
        if let step {
            if targetIdentity != nil || attribution == .requiredTarget {
                self.sequence.record(
                    step,
                    targetIdentity: targetIdentity,
                    attribution: effectiveAttribution
                )
            } else {
                self.sequence.record(step)
            }
        } else if targetIdentity != nil || attribution == .requiredTarget {
            self.sequence.record(
                outcome: nil,
                targetIdentity: targetIdentity,
                attribution: effectiveAttribution
            )
        }
        let targetResolution = self.sequence.resolution
        self.targetIdentity = targetResolution.targetIdentity
        if priorConflict == nil, let conflict = targetResolution.targetConflictError {
            throw conflict
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
        receiptlessStep: DesktopActionSequenceAccumulator.Step? = nil,
        defaultDispatchedUnitCount: DesktopActionOutcome.DispatchUnitCount? = .one
    ) throws {
        try self.record(
            outcome: outcome,
            targetIdentity: targetIdentity,
            attribution: .requiredTarget,
            operation: operation,
            missingReceiptPolicy: MissingReceiptPolicy(
                receiptlessStep: receiptlessStep,
                defaultDispatchedUnitCount: defaultDispatchedUnitCount
            )
        )
    }

    func result<Payload: Sendable>(payload: Payload) -> UIAutomationActionResult<Payload> {
        UIAutomationActionResult(
            payload: payload,
            outcome: self.resolution.outcome,
            targetIdentity: self.targetIdentity
        )
    }

    func preservingFailure(
        _ error: any Error,
        fallbackRoute: DesktopActionOutcome.Route,
        message: String,
        hint: String
    ) -> any Error {
        guard self.sequence.resolution.mutationDisposition.mutationDispatched else { return error }

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
        return self.sequence.failure(
            combining: leafFailure,
            operation: message,
            message: message,
            hint: hint,
            causeDescription: leafFailure.causeDescription ?? error.localizedDescription
        )
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
