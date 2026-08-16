import Foundation
import PeekabooFoundation

/// Target-aware composition for multi-phase automation results.
///
/// ``DesktopActionSequenceAccumulator`` remains the sole owner of outcome-state composition. This
/// layer keeps target attribution and selected-leaf evidence aligned with the phases that actually
/// dispatched, so setup results cannot silently lend their target to an unattributed leaf.
public struct UIAutomationActionResultSequenceAccumulator: Sendable {
    public enum PhaseAttributionRule: Equatable, Sendable {
        /// Only a phase that dispatched mutation contributes its target to the aggregate.
        case mutationTarget

        /// A reported target describes the operation even when no dispatch was necessary.
        case operationTarget

        /// This phase must report its own stable target; an earlier phase cannot substitute for it.
        case requiredTarget

        /// The phase is intentionally global and the aggregate must not claim an exact target.
        case targetless
    }

    public struct Resolution: Sendable {
        public let outcome: DesktopActionOutcome?
        public let mutationDisposition: DesktopActionMutationDisposition
        public let targetIdentity: DesktopTargetIdentity?
        public let targetReceipt: DesktopActionTargetReceipt?
        public let mutationTargetReceipt: DesktopActionTargetReceipt?
        public let selectedLeafEvidence: [DesktopSelectedLeafEvidence]?
        public let hasTargetConflict: Bool
        public let hasProhibitedTarget: Bool
        public let hasMissingRequiredTarget: Bool
        public let hasContradictoryRequiredTarget: Bool
        public let hasInvalidSelectedLeafEvidence: Bool
    }

    private struct TargetAccumulator: Sendable {
        private(set) var contributionCount = 0
        private(set) var missingCount = 0
        private(set) var hasContradiction = false
        private var mergedReceipt: DesktopActionTargetReceipt?
        private var mergedIdentity: DesktopTargetIdentity?
        private var hasMissingIdentity = false

        var hasIncompatibleContributions: Bool {
            self.hasContradiction || (self.contributionCount > 1 && self.missingCount > 0)
        }

        var receipt: DesktopActionTargetReceipt? {
            guard !self.hasContradiction, self.missingCount == 0 else { return nil }
            return self.mergedReceipt
        }

        var identity: DesktopTargetIdentity? {
            guard !self.hasContradiction,
                  self.missingCount == 0,
                  !self.hasMissingIdentity,
                  let receipt = self.mergedReceipt
            else { return nil }

            if receipt.windowID == nil {
                return try? DesktopTargetIdentity(processIdentity: ApplicationProcessIdentity(
                    processIdentifier: receipt.processIdentifier,
                    processStartIdentity: receipt.processStartIdentity))
            }
            guard let identity = self.mergedIdentity,
                  identity.actionTargetReceipt == receipt
            else { return nil }
            return identity
        }

        mutating func record(
            identity: DesktopTargetIdentity?,
            receipt explicitReceipt: DesktopActionTargetReceipt?)
        {
            self.contributionCount += 1
            let identityReceipt = identity?.actionTargetReceipt
            if let identityReceipt, let explicitReceipt, identityReceipt != explicitReceipt {
                self.hasContradiction = true
                self.mergedReceipt = nil
                self.mergedIdentity = nil
                return
            }
            guard let receipt = explicitReceipt ?? identityReceipt else {
                self.missingCount += 1
                self.hasMissingIdentity = true
                return
            }

            if let current = self.mergedReceipt {
                guard let merged = Self.commonScope(current, receipt) else {
                    self.hasContradiction = true
                    self.mergedReceipt = nil
                    self.mergedIdentity = nil
                    return
                }
                self.mergedReceipt = merged
            } else {
                self.mergedReceipt = receipt
            }

            guard let identity else {
                self.hasMissingIdentity = true
                return
            }
            if let current = self.mergedIdentity {
                do {
                    self.mergedIdentity = try current.coalescing(identity)
                } catch {
                    self.hasContradiction = true
                    self.mergedReceipt = nil
                    self.mergedIdentity = nil
                }
            } else {
                self.mergedIdentity = identity
            }
        }

        fileprivate static func commonScope(
            _ lhs: DesktopActionTargetReceipt,
            _ rhs: DesktopActionTargetReceipt) -> DesktopActionTargetReceipt?
        {
            guard lhs.processIdentifier == rhs.processIdentifier,
                  lhs.processStartIdentity == rhs.processStartIdentity
            else { return nil }
            if lhs.windowID == rhs.windowID {
                return lhs
            }
            guard lhs.windowID == nil || rhs.windowID == nil else { return nil }
            return DesktopActionTargetReceipt(
                processIdentifier: lhs.processIdentifier,
                processStartIdentity: lhs.processStartIdentity)
        }

        fileprivate static func contains(
            _ candidate: DesktopActionTargetReceipt,
            within scope: DesktopActionTargetReceipt) -> Bool
        {
            guard candidate.processIdentifier == scope.processIdentifier,
                  candidate.processStartIdentity == scope.processStartIdentity
            else { return false }
            guard let scopeWindowID = scope.windowID else { return true }
            return candidate.windowID == scopeWindowID
        }
    }

    private var sequence = DesktopActionSequenceAccumulator()
    private var operationTargets = TargetAccumulator()
    private var mutationTargets = TargetAccumulator()
    private var selectedLeaves: [DesktopSelectedLeafEvidence] = []
    private var forcesTargetlessResult = false
    private var targetlessPhaseReturnedTarget = false
    private var missingRequiredTarget = false
    private var contradictoryRequiredTarget = false
    private var invalidSelectedLeafEvidence = false

    public init() {}

    public mutating func record(
        _ result: UIAutomationActionResult<some Sendable>,
        attribution: PhaseAttributionRule,
        defaultDispatchedUnitCount: DesktopActionOutcome.DispatchUnitCount? = nil)
    {
        self.record(
            outcome: result.outcome,
            targetIdentity: result.targetIdentity,
            targetReceipt: nil,
            selectedLeafEvidence: result.selectedLeafEvidence,
            attribution: attribution,
            defaultDispatchedUnitCount: defaultDispatchedUnitCount)
    }

    public mutating func record(
        outcome: DesktopActionOutcome?,
        targetIdentity: DesktopTargetIdentity? = nil,
        targetReceipt: DesktopActionTargetReceipt? = nil,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil,
        attribution: PhaseAttributionRule,
        defaultDispatchedUnitCount: DesktopActionOutcome.DispatchUnitCount? = nil)
    {
        if let outcome {
            if let defaultDispatchedUnitCount {
                self.sequence.record(.reportedOutcome(
                    outcome,
                    defaultDispatchedUnitCount: defaultDispatchedUnitCount))
            } else {
                self.sequence.record(.outcome(outcome))
            }
        }

        let didDispatch = outcome?.dispatchState.mutationDispatched == true
        let hasTarget = targetIdentity != nil || targetReceipt != nil
        switch attribution {
        case .mutationTarget:
            if didDispatch {
                self.recordTargetContribution(
                    identity: targetIdentity,
                    receipt: targetReceipt,
                    contributesToOperation: true)
            }
        case .operationTarget:
            self.recordTargetContribution(
                identity: targetIdentity,
                receipt: targetReceipt,
                contributesToOperation: true,
                contributesToMutation: didDispatch)
        case .requiredTarget:
            if !hasTarget {
                self.missingRequiredTarget = true
            } else if let identityReceipt = targetIdentity?.actionTargetReceipt,
                      let targetReceipt,
                      identityReceipt != targetReceipt
            {
                self.contradictoryRequiredTarget = true
            }
            self.recordTargetContribution(
                identity: targetIdentity,
                receipt: targetReceipt,
                contributesToOperation: true,
                contributesToMutation: didDispatch)
        case .targetless:
            self.forcesTargetlessResult = true
            self.targetlessPhaseReturnedTarget = self.targetlessPhaseReturnedTarget || hasTarget
        }

        guard let selectedLeafEvidence, !selectedLeafEvidence.isEmpty else { return }
        let identityTargetReceipt = targetIdentity?.actionTargetReceipt
        let phaseTargetReceipt: DesktopActionTargetReceipt? = if let identityTargetReceipt,
                                                                 let targetReceipt
        {
            identityTargetReceipt == targetReceipt ? targetReceipt : nil
        } else {
            targetReceipt ?? identityTargetReceipt
        }
        guard didDispatch,
              selectedLeafEvidence.allSatisfy(\.isCanonical),
              let phaseTargetReceipt,
              selectedLeafEvidence.allSatisfy({ evidence in
                  TargetAccumulator.contains(
                      evidence.selectedTargetReceipt,
                      within: phaseTargetReceipt)
              })
        else {
            self.invalidSelectedLeafEvidence = true
            return
        }
        self.selectedLeaves.append(contentsOf: selectedLeafEvidence)
    }

    public var resolution: Resolution {
        let sequenceResolution = self.sequence.successResolution()
        let targetConflict = self.targetlessPhaseReturnedTarget ||
            self.operationTargets.hasIncompatibleContributions
        let targetReceipt = self.forcesTargetlessResult ? nil : self.operationTargets.receipt
        let selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = if let targetReceipt,
                                                                      !self.selectedLeaves.isEmpty,
                                                                      self.selectedLeaves.allSatisfy({ leaf in
                                                                          TargetAccumulator.contains(
                                                                              leaf.selectedTargetReceipt,
                                                                              within: targetReceipt)
                                                                      })
        {
            self.selectedLeaves
        } else {
            nil
        }
        return Resolution(
            outcome: sequenceResolution.outcome,
            mutationDisposition: sequenceResolution.mutationDisposition,
            targetIdentity: self.forcesTargetlessResult ? nil : self.operationTargets.identity,
            targetReceipt: targetReceipt,
            mutationTargetReceipt: self.forcesTargetlessResult ? nil : self.mutationTargets.receipt,
            selectedLeafEvidence: selectedLeafEvidence,
            hasTargetConflict: targetConflict,
            hasProhibitedTarget: self.targetlessPhaseReturnedTarget,
            hasMissingRequiredTarget: self.missingRequiredTarget,
            hasContradictoryRequiredTarget: self.contradictoryRequiredTarget,
            hasInvalidSelectedLeafEvidence: self.invalidSelectedLeafEvidence)
    }

    public func result<Payload: Sendable>(
        payload: Payload,
        fallbackOutcome: DesktopActionOutcome? = nil,
        operation: String,
        requiresOutcome: Bool = false,
        requiresTarget: Bool = false,
        requiresCompatibleTarget: Bool = false,
        failureMessage: String? = nil,
        failureHint: String = "Observe the target before retrying.") throws -> UIAutomationActionResult<Payload>
    {
        let resolution = self.resolution
        let outcome = resolution.outcome ?? fallbackOutcome
        if resolution.hasInvalidSelectedLeafEvidence {
            throw self.compositionFailure(
                outcome: outcome,
                operation: operation,
                message: failureMessage ?? "\(operation) returned invalid selected-leaf evidence.",
                hint: failureHint,
                causeDescription: "Selected-leaf evidence requires a dispatched mutation and canonical fields.")
        }
        if resolution.hasMissingRequiredTarget {
            throw self.compositionFailure(
                outcome: outcome,
                operation: operation,
                message: failureMessage ?? "\(operation) returned without its required phase target.",
                hint: failureHint,
                causeDescription: DesktopTargetIdentityError.missingProcessGeneration.localizedDescription)
        }
        if resolution.hasContradictoryRequiredTarget {
            throw self.compositionFailure(
                outcome: outcome,
                operation: operation,
                message: failureMessage ??
                    "\(operation) returned contradictory identity and receipt for a required phase target.",
                hint: failureHint,
                causeDescription: DesktopTargetIdentityError.contradictoryWindowIdentity.localizedDescription)
        }
        if resolution.hasProhibitedTarget {
            throw self.compositionFailure(
                outcome: outcome,
                operation: operation,
                message: failureMessage ?? "\(operation) returned a target for a targetless phase.",
                hint: failureHint,
                causeDescription: "A globally delivered phase cannot claim exact target attribution.")
        }
        if requiresCompatibleTarget, resolution.hasTargetConflict {
            throw self.compositionFailure(
                outcome: outcome,
                operation: operation,
                message: failureMessage ?? "\(operation) returned contradictory phase targets.",
                hint: failureHint,
                causeDescription: DesktopTargetIdentityError.contradictoryWindowIdentity.localizedDescription)
        }
        if requiresTarget, resolution.targetIdentity == nil {
            throw self.compositionFailure(
                outcome: outcome,
                operation: operation,
                message: failureMessage ?? "\(operation) returned without its required aggregate target.",
                hint: failureHint,
                causeDescription: DesktopTargetIdentityError.missingProcessGeneration.localizedDescription)
        }
        if requiresOutcome, outcome == nil {
            throw self.compositionFailure(
                outcome: nil,
                operation: operation,
                message: failureMessage ?? "\(operation) returned without a canonical aggregate outcome.",
                hint: failureHint,
                causeDescription: nil)
        }
        return UIAutomationActionResult(
            payload: payload,
            outcome: outcome,
            targetIdentity: resolution.targetIdentity,
            selectedLeafEvidence: resolution.selectedLeafEvidence)
    }

    public func failure(
        combining leafFailure: DesktopActionFailure,
        operation: String,
        message: String? = nil,
        hint: String? = nil,
        causeDescription: String? = nil) -> DesktopActionFailure
    {
        let composed = self.sequence.failure(
            combining: leafFailure,
            message: message ?? leafFailure.message,
            hint: hint ?? leafFailure.hint,
            causeDescription: causeDescription ?? leafFailure.causeDescription)
        let targetReceipt = self.failureTargetReceipt(leafFailure)
        let evidence = self.combinedSelectedLeafEvidence(
            leafFailure,
            targetReceipt: targetReceipt)
        guard let normalized = DesktopActionFailure(
            outcome: composed.outcome,
            message: composed.message,
            hint: composed.hint,
            causeDescription: composed.causeDescription,
            targetReceipt: targetReceipt,
            selectedLeafEvidence: evidence)
        else {
            preconditionFailure("Composed action failures must retain a non-confirmed canonical outcome")
        }
        return normalized
    }

    private mutating func recordTargetContribution(
        identity: DesktopTargetIdentity?,
        receipt: DesktopActionTargetReceipt?,
        contributesToOperation: Bool,
        contributesToMutation: Bool = true)
    {
        if contributesToOperation {
            self.operationTargets.record(identity: identity, receipt: receipt)
        }
        if contributesToMutation {
            self.mutationTargets.record(identity: identity, receipt: receipt)
        }
    }

    private func failureTargetReceipt(_ leafFailure: DesktopActionFailure) -> DesktopActionTargetReceipt? {
        guard !self.forcesTargetlessResult else { return nil }
        let priorTarget = self.resolution.mutationTargetReceipt
        switch (
            self.sequence.mutationDisposition.mutationDispatched,
            leafFailure.outcome.dispatchState.mutationDispatched)
        {
        case (true, true):
            guard let priorTarget, let laterTarget = leafFailure.targetReceipt else { return nil }
            return TargetAccumulator.commonScope(priorTarget, laterTarget)
        case (true, false):
            return priorTarget
        case (false, true):
            return leafFailure.targetReceipt
        case (false, false):
            guard !self.resolution.hasTargetConflict else { return nil }
            switch (self.resolution.targetReceipt, leafFailure.targetReceipt) {
            case let (prior?, later?):
                return TargetAccumulator.commonScope(prior, later)
            case let (target?, nil), let (nil, target?):
                return target
            case (nil, nil):
                return nil
            }
        }
    }

    private func combinedSelectedLeafEvidence(
        _ leafFailure: DesktopActionFailure,
        targetReceipt: DesktopActionTargetReceipt?) -> [DesktopSelectedLeafEvidence]?
    {
        let leafEvidence = leafFailure.selectedLeafEvidence ?? []
        let evidence = self.selectedLeaves + leafEvidence
        guard !evidence.isEmpty,
              let targetReceipt,
              evidence.allSatisfy(\.isCanonical),
              evidence.allSatisfy({ leaf in
                  TargetAccumulator.contains(
                      leaf.selectedTargetReceipt,
                      within: targetReceipt)
              })
        else { return nil }
        if !leafEvidence.isEmpty {
            guard leafFailure.outcome.dispatchState.mutationDispatched,
                  let leafTargetReceipt = leafFailure.targetReceipt,
                  leafEvidence.allSatisfy({ leaf in
                      TargetAccumulator.contains(
                          leaf.selectedTargetReceipt,
                          within: leafTargetReceipt)
                  })
            else { return nil }
        }
        return evidence
    }

    private func compositionFailure(
        outcome: DesktopActionOutcome?,
        operation _: String,
        message: String,
        hint: String,
        causeDescription: String?) -> DesktopActionFailure
    {
        let failure = outcome.flatMap {
            DesktopActionFailure(
                outcome: $0,
                message: message,
                hint: hint,
                causeDescription: causeDescription)
        } ?? .indeterminate(
            route: outcome?.route ?? .local,
            delivery: outcome?.delivery,
            evidence: .completionUnknown,
            unitCount: outcome?.dispatchState.unitCount ?? self.sequence.mutationDisposition.unitCount,
            message: message,
            hint: hint,
            causeDescription: causeDescription)
        return failure
            .attributed(to: self.resolution.targetReceipt)
            .selectingLeaves(self.resolution.selectedLeafEvidence)
    }
}
