import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct UIAutomationActionResultSequenceAccumulatorTests {
    private static let windowBounds = CGRect(x: 10, y: 20, width: 300, height: 200)

    private let backgroundDelivery = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .background)

    @Test
    func `homogeneous mutation phases preserve target leaves and exact units`() throws {
        let target = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 71,
            bounds: Self.windowBounds).windowTargetIdentity
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
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001),
            windowID: 71,
            bounds: Self.windowBounds)
        let process = fixture.processIdentity
        let processTarget = fixture.processTargetIdentity
        let windowTarget = fixture.windowTargetIdentity
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
        let first = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 71,
            bounds: Self.windowBounds).windowTargetIdentity
        let second = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 72,
            bounds: Self.windowBounds).windowTargetIdentity
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
        let target = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 71,
            bounds: Self.windowBounds).windowTargetIdentity
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
    func `required phase rejects contradictory identity and receipt without compatibility opt in`() throws {
        let identityTarget = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 71,
            bounds: Self.windowBounds)
        let explicitTarget = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 72,
            bounds: Self.windowBounds)
        var sequence = UIAutomationActionResultSequenceAccumulator()
        sequence.record(
            outcome: .confirmedNoChange(),
            targetIdentity: identityTarget.windowTargetIdentity,
            targetReceipt: explicitTarget.windowTargetReceipt,
            attribution: .requiredTarget)

        do {
            _ = try sequence.result(
                payload: (),
                operation: "Contradictory required target",
                requiresOutcome: true)
            Issue.record("Expected the contradictory required target to fail without compatibility opt in")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount == nil)
            #expect(failure.targetReceipt == nil)
            #expect(failure.causeDescription ==
                DesktopTargetIdentityError.contradictoryWindowIdentity.localizedDescription)
        }
    }

    @Test
    func `targetless leaf suppresses setup attribution and rejects its own target`() throws {
        let target = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 71,
            bounds: Self.windowBounds).windowTargetIdentity
        let evidence = try self.leaf(index: 0, target: target.actionTargetReceipt)
        let pointerDelivery = DesktopActionOutcome.Delivery(
            mechanism: .globalEvents,
            mode: .foreground)
        var sequence = UIAutomationActionResultSequenceAccumulator()
        sequence.record(
            UIAutomationActionResult(
                payload: (),
                outcome: .confirmedChange(delivery: self.backgroundDelivery, unitCount: .one),
                targetIdentity: target,
                selectedLeafEvidence: [evidence]),
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
        #expect(result.selectedLeafEvidence == nil)
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
        let target = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 71,
            bounds: Self.windowBounds).windowTargetIdentity
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
        let leafFailure = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Later phase refused")
            .attributed(to: AutomationTestFixtures.linkedDesktopTarget(
                windowID: 72,
                bounds: Self.windowBounds).windowTargetReceipt)

        let failure = sequence.failure(
            combining: leafFailure,
            operation: "Fixture sequence")

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.dispatchState.unitCount == .one)
        #expect(failure.targetReceipt == target.actionTargetReceipt)
        #expect(failure.selectedLeafEvidence == [evidence])
    }

    @Test
    func `terminal failure drops selected leaves outside its own target`() throws {
        let target = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001),
            windowID: 71,
            bounds: Self.windowBounds)
        let sibling = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: target.processIdentity,
            windowID: 72,
            bounds: Self.windowBounds)
        let invalidEvidence = try self.leaf(index: 0, target: sibling.windowTargetReceipt)
        var sequence = UIAutomationActionResultSequenceAccumulator()
        sequence.record(
            outcome: .confirmedChange(delivery: self.backgroundDelivery, unitCount: .one),
            targetReceipt: target.windowTargetReceipt,
            attribution: .mutationTarget)
        let terminalFailure = DesktopActionFailure.indeterminate(
            delivery: self.backgroundDelivery,
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Terminal failure")
            .attributed(to: target.windowTargetReceipt)
            .selectingLeaves([invalidEvidence])

        let failure = sequence.failure(
            combining: terminalFailure,
            operation: "Invalid terminal evidence")

        #expect(failure.targetReceipt == target.windowTargetReceipt)
        #expect(failure.selectedLeafEvidence == nil)
    }

    @Test
    func `zero-prefix failure normalizes selected leaves against its terminal target`() throws {
        let target = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001),
            windowID: 71,
            bounds: Self.windowBounds)
        let sibling = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: target.processIdentity,
            windowID: 72,
            bounds: Self.windowBounds)
        let invalidEvidence = try self.leaf(index: 0, target: sibling.windowTargetReceipt)
        let terminalFailure = DesktopActionFailure.indeterminate(
            delivery: self.backgroundDelivery,
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Standalone terminal failure")
            .attributed(to: target.windowTargetReceipt)
            .selectingLeaves([invalidEvidence])
        let sequence = UIAutomationActionResultSequenceAccumulator()

        let failure = sequence.failure(
            combining: terminalFailure,
            operation: "Invalid standalone terminal evidence")

        #expect(failure.outcome == terminalFailure.outcome)
        #expect(failure.message == terminalFailure.message)
        #expect(failure.targetReceipt == target.windowTargetReceipt)
        #expect(failure.selectedLeafEvidence == nil)
    }

    @Test
    func `target-conflicted aggregate drops selected leaves when compatibility is optional`() throws {
        let first = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 71,
            bounds: Self.windowBounds)
        let second = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 72,
            bounds: Self.windowBounds)
        let evidence = try self.leaf(index: 0, target: first.windowTargetReceipt)
        var sequence = UIAutomationActionResultSequenceAccumulator()
        sequence.record(
            outcome: .confirmedChange(delivery: self.backgroundDelivery, unitCount: .one),
            targetReceipt: first.windowTargetReceipt,
            selectedLeafEvidence: [evidence],
            attribution: .operationTarget)
        sequence.record(
            outcome: .confirmedNoChange(),
            targetReceipt: second.windowTargetReceipt,
            attribution: .operationTarget)

        let result = try sequence.result(
            payload: (),
            operation: "Optional target compatibility",
            requiresOutcome: true)

        #expect(result.targetIdentity == nil)
        #expect(result.selectedLeafEvidence == nil)
    }

    @Test
    func `selected leaves require canonical dispatched evidence`() throws {
        let target = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 71,
            bounds: Self.windowBounds).windowTargetIdentity
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

    @Test
    func `empty selected-leaf collection is normalized to absent evidence`() throws {
        let target = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 71,
            bounds: Self.windowBounds)
        var sequence = UIAutomationActionResultSequenceAccumulator()
        sequence.record(
            outcome: .confirmedChange(delivery: self.backgroundDelivery, unitCount: .one),
            targetReceipt: target.windowTargetReceipt,
            selectedLeafEvidence: [],
            attribution: .mutationTarget)

        let result = try sequence.result(
            payload: (),
            operation: "Empty selected leaves",
            requiresOutcome: true,
            requiresCompatibleTarget: true)

        #expect(result.outcome?.state == .confirmedChange)
        #expect(result.selectedLeafEvidence == nil)
    }

    @Test
    func `selected leaves must be contained by the attributed phase target`() throws {
        let phase = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001),
            windowID: 71,
            bounds: Self.windowBounds)
        let sibling = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: phase.processIdentity,
            windowID: 72,
            bounds: Self.windowBounds)
        for unrelatedTarget in [sibling.windowTargetReceipt, phase.processTargetReceipt] {
            let evidence = try self.leaf(index: 0, target: unrelatedTarget)
            var sequence = UIAutomationActionResultSequenceAccumulator()
            sequence.record(
                UIAutomationActionResult(
                    payload: (),
                    outcome: .confirmedChange(delivery: self.backgroundDelivery, unitCount: .one),
                    targetIdentity: phase.windowTargetIdentity,
                    selectedLeafEvidence: [evidence]),
                attribution: .mutationTarget)

            #expect(throws: DesktopActionFailure.self) {
                _ = try sequence.result(
                    payload: (),
                    operation: "Mismatched selected leaf",
                    requiresOutcome: true,
                    requiresCompatibleTarget: true)
            }
            let failure = sequence.failure(
                combining: .preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Later phase refused"),
                operation: "Mismatched selected leaf")
            #expect(failure.selectedLeafEvidence == nil)
        }
    }

    @Test
    func `process phase accepts selected leaves from an exact child window`() throws {
        let phase = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001),
            windowID: 71,
            bounds: Self.windowBounds)
        let evidence = try self.leaf(index: 0, target: phase.windowTargetReceipt)
        var sequence = UIAutomationActionResultSequenceAccumulator()
        sequence.record(
            outcome: .confirmedChange(delivery: self.backgroundDelivery, unitCount: .one),
            targetIdentity: phase.processTargetIdentity,
            selectedLeafEvidence: [evidence],
            attribution: .mutationTarget)

        let result = try sequence.result(
            payload: (),
            operation: "Process selected leaf",
            requiresOutcome: true,
            requiresCompatibleTarget: true)

        #expect(result.selectedLeafEvidence == [evidence])
    }

    @Test
    func `coalesced projection preserves legacy richest-target semantics`() throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001),
            windowID: 71,
            bounds: Self.windowBounds)
        var sequence = UIAutomationActionResultSequenceAccumulator(
            targetProjectionPolicy: .coalescedIdentity)
        for target in [fixture.windowTargetIdentity, fixture.processTargetIdentity] {
            sequence.record(
                .reportedOutcome(
                    .confirmedChange(delivery: self.backgroundDelivery),
                    defaultDispatchedUnitCount: .one),
                targetIdentity: target,
                attribution: .sequenceTarget)
        }

        let result = try sequence.result(
            payload: (),
            operation: "Legacy-compatible sequence",
            requiresOutcome: true,
            requiresCompatibleTarget: true)

        #expect(result.outcome?.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(2))
        #expect(result.targetIdentity == fixture.windowTargetIdentity)
        #expect(sequence.sequenceResolution.outcome == result.outcome)
    }

    @Test
    func `raw required phase cannot borrow a sequence target`() throws {
        let target = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 71,
            bounds: Self.windowBounds).windowTargetIdentity
        var sequence = UIAutomationActionResultSequenceAccumulator(
            targetProjectionPolicy: .coalescedIdentity)
        sequence.record(
            .reportedOutcome(
                .confirmedChange(delivery: self.backgroundDelivery),
                defaultDispatchedUnitCount: .one),
            targetIdentity: target,
            attribution: .sequenceTarget)
        sequence.record(
            .reportedOutcome(
                .dispatchedUnverified(
                    delivery: self.backgroundDelivery,
                    evidence: .deliveryAccepted),
                defaultDispatchedUnitCount: .one),
            targetIdentity: nil,
            attribution: .requiredTarget)

        #expect(sequence.resolution.hasMissingRequiredTarget)
        #expect(sequence.resolution.targetIdentity == nil)
        do {
            _ = try sequence.result(
                payload: (),
                operation: "Required raw phase",
                requiresOutcome: true)
            Issue.record("Expected the missing required target to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(2))
            #expect(failure.targetReceipt == nil)
        }
    }

    @Test
    func `no-dispatch failure cannot hide a prior operation target conflict`() {
        let first = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 71,
            bounds: Self.windowBounds)
        let second = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 72,
            bounds: Self.windowBounds)
        let later = AutomationTestFixtures.linkedDesktopTarget(
            windowID: 73,
            bounds: Self.windowBounds)
        var sequence = UIAutomationActionResultSequenceAccumulator()
        for target in [first, second] {
            sequence.record(
                outcome: .confirmedNoChange(),
                targetReceipt: target.windowTargetReceipt,
                attribution: .operationTarget)
        }

        let failure = sequence.failure(
            combining: DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Later phase refused")
                .attributed(to: later.windowTargetReceipt),
            operation: "Conflicting no-dispatch targets")

        #expect(failure.targetReceipt == nil)
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
