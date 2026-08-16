import CoreGraphics
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct UIAutomationActionResultSequenceAccumulatorTests {
    private let backgroundDelivery = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .background)

    @Test
    func `homogeneous mutation phases preserve target leaves and exact units`() throws {
        let target = try self.windowTarget(windowID: 71)
        let receipt = target.actionTargetReceipt
        let firstLeaf = try self.leaf(index: 0, target: receipt)
        let secondLeaf = try self.leaf(index: 1, target: receipt)
        var sequence = UIAutomationActionResultSequenceAccumulator()
        sequence.record(
            UIAutomationActionResult(
                payload: (),
                outcome: .confirmedChange(delivery: self.backgroundDelivery, unitCount: .one),
                targetIdentity: target,
                selectedLeafEvidence: [firstLeaf]),
            attribution: .mutationTarget)
        sequence.record(
            UIAutomationActionResult(
                payload: (),
                outcome: .confirmedChange(delivery: self.backgroundDelivery, unitCount: .one),
                targetIdentity: target,
                selectedLeafEvidence: [secondLeaf]),
            attribution: .mutationTarget)

        let result = try sequence.result(
            payload: true,
            operation: "Fixture sequence",
            requiresOutcome: true,
            requiresTarget: true,
            requiresCompatibleTarget: true)

        #expect(result.payload)
        #expect(result.outcome?.state == .confirmedChange)
        #expect(result.outcome?.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(2))
        #expect(result.targetIdentity == target)
        #expect(result.selectedLeafEvidence == [firstLeaf, secondLeaf])
    }

    @Test
    func `process and exact mutation phases retain only their common process scope`() throws {
        let process = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 1001)
        let processTarget = try DesktopTargetIdentity(processIdentity: process)
        let windowTarget = try self.windowTarget(windowID: 71, process: process)
        var sequence = UIAutomationActionResultSequenceAccumulator()
        for target in [processTarget, windowTarget] {
            sequence.record(
                UIAutomationActionResult(
                    payload: (),
                    outcome: .confirmedChange(delivery: self.backgroundDelivery, unitCount: .one),
                    targetIdentity: target),
                attribution: .mutationTarget)
        }

        let result = try sequence.result(
            payload: (),
            operation: "Mixed-scope sequence",
            requiresOutcome: true,
            requiresTarget: true,
            requiresCompatibleTarget: true)

        #expect(result.targetIdentity?.processIdentity == process)
        #expect(result.targetIdentity?.exactWindow == nil)
        #expect(result.actionTargetReceipt == processTarget.actionTargetReceipt)
    }

    @Test
    func `different exact mutation targets fail closed`() throws {
        let first = try self.windowTarget(windowID: 71)
        let second = try self.windowTarget(windowID: 72)
        var sequence = UIAutomationActionResultSequenceAccumulator()
        for target in [first, second] {
            sequence.record(
                UIAutomationActionResult(
                    payload: (),
                    outcome: .confirmedChange(delivery: self.backgroundDelivery, unitCount: .one),
                    targetIdentity: target),
                attribution: .mutationTarget)
        }

        do {
            _ = try sequence.result(
                payload: (),
                operation: "Conflicting sequence",
                requiresOutcome: true,
                requiresCompatibleTarget: true)
            Issue.record("Expected contradictory exact targets to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(2))
            #expect(failure.targetReceipt == nil)
        }
    }

    @Test
    func `required leaf cannot borrow a setup target`() throws {
        let target = try self.windowTarget(windowID: 71)
        var sequence = UIAutomationActionResultSequenceAccumulator()
        sequence.record(
            UIAutomationActionResult(
                payload: (),
                outcome: .confirmedChange(delivery: self.backgroundDelivery, unitCount: .one),
                targetIdentity: target),
            attribution: .mutationTarget)
        sequence.record(
            UIAutomationActionResult(
                payload: (),
                outcome: .confirmedChange(delivery: self.backgroundDelivery, unitCount: .one)),
            attribution: .requiredTarget)

        do {
            _ = try sequence.result(
                payload: (),
                operation: "Required leaf sequence",
                requiresOutcome: true)
            Issue.record("Expected a missing required leaf target to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.targetReceipt == nil)
        }
    }

    @Test
    func `targetless leaf suppresses setup attribution and rejects its own target`() throws {
        let target = try self.windowTarget(windowID: 71)
        let pointerDelivery = DesktopActionOutcome.Delivery(
            mechanism: .globalEvents,
            mode: .foreground)
        var sequence = UIAutomationActionResultSequenceAccumulator()
        sequence.record(
            UIAutomationActionResult(
                payload: (),
                outcome: .confirmedChange(delivery: self.backgroundDelivery, unitCount: .one),
                targetIdentity: target),
            attribution: .mutationTarget)
        sequence.record(
            UIAutomationActionResult(
                payload: (),
                outcome: .confirmedChange(delivery: pointerDelivery, unitCount: .one)),
            attribution: .targetless)

        let result = try sequence.result(
            payload: (),
            operation: "Global pointer sequence",
            requiresOutcome: true,
            requiresCompatibleTarget: true)
        #expect(result.targetIdentity == nil)
        #expect(result.outcome?.delivery?.mechanism == .composite)

        var invalid = UIAutomationActionResultSequenceAccumulator()
        invalid.record(
            UIAutomationActionResult(
                payload: (),
                outcome: .confirmedChange(delivery: pointerDelivery, unitCount: .one),
                targetIdentity: target),
            attribution: .targetless)
        #expect(throws: DesktopActionFailure.self) {
            _ = try invalid.result(
                payload: (),
                operation: "Invalid global pointer")
        }
    }

    @Test
    func `failure composition follows dispatched targets and preserves prior leaves`() throws {
        let target = try self.windowTarget(windowID: 71)
        let evidence = try self.leaf(index: 0, target: target.actionTargetReceipt)
        var sequence = UIAutomationActionResultSequenceAccumulator()
        sequence.record(
            UIAutomationActionResult(
                payload: (),
                outcome: .dispatchedUnverified(
                    delivery: self.backgroundDelivery,
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                targetIdentity: target,
                selectedLeafEvidence: [evidence]),
            attribution: .operationTarget)
        let leafFailure = try DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Later phase refused")
            .attributed(to: self.windowTarget(windowID: 72).actionTargetReceipt)

        let failure = sequence.failure(
            combining: leafFailure,
            operation: "Fixture sequence")

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.dispatchState.unitCount == .one)
        #expect(failure.targetReceipt == target.actionTargetReceipt)
        #expect(failure.selectedLeafEvidence == [evidence])
    }

    @Test
    func `selected leaves require canonical dispatched evidence`() throws {
        let target = try self.windowTarget(windowID: 71)
        let evidence = try self.leaf(index: 0, target: target.actionTargetReceipt)
        var sequence = UIAutomationActionResultSequenceAccumulator()
        sequence.record(
            UIAutomationActionResult(
                payload: (),
                outcome: .confirmedNoChange(),
                targetIdentity: target,
                selectedLeafEvidence: [evidence]),
            attribution: .operationTarget)

        #expect(throws: DesktopActionFailure.self) {
            _ = try sequence.result(
                payload: (),
                operation: "No-dispatch leaf sequence",
                requiresOutcome: true)
        }
    }

    private func windowTarget(
        windowID: Int,
        process: ApplicationProcessIdentity = .init(
            processIdentifier: 42,
            processStartIdentity: 1001)) throws -> DesktopTargetIdentity
    {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        return try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: windowID,
                ownerProcessIdentifier: process.processIdentifier,
                ownerProcessStartIdentity: process.processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds))
    }

    private func leaf(
        index: Int,
        target: DesktopActionTargetReceipt) throws -> DesktopSelectedLeafEvidence
    {
        try DesktopSelectedLeafEvidence(
            kind: .menuBarItem,
            normalizedSelector: "fixture-\(index)",
            matchKind: .exact,
            selectedTargetReceipt: target,
            selectedIndex: index,
            selectedTitle: "Fixture \(index)",
            selectedIdentifier: "fixture.\(index)",
            selectedRole: "AXMenuBarItem",
            selectedFrame: CGRect(x: index * 20, y: 0, width: 18, height: 18),
            candidateSetSHA256: DesktopSelectedLeafEvidence.digestCandidateSet(["fixture", "\(index)"]),
            candidateCount: 1)
    }
}
