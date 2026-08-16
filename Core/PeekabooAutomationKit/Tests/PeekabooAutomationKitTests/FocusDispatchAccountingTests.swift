import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct FocusDispatchAccountingTests {
    private let nativeForeground = DesktopActionOutcome.Delivery(
        mechanism: .nativeFramework,
        mode: .foreground)
    private let valueForeground = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityValue,
        mode: .foreground)
    private let actionForeground = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .foreground)

    @Test
    func `rejected activation and AX value requests record no phantom units`() throws {
        var records: [FocusDispatchRecord] = []

        #expect(try !FocusDispatchAccounting.acceptingBool(
            delivery: self.nativeForeground,
            onDispatch: { records.append($0) },
            operation: { false }))
        #expect(try !FocusDispatchAccounting.acceptingBool(
            delivery: self.valueForeground,
            onDispatch: { records.append($0) },
            operation: { false }))
        #expect(records.isEmpty)
    }

    @Test
    func `accepted Bool requests record their exact delivery`() throws {
        var records: [FocusDispatchRecord] = []

        #expect(try FocusDispatchAccounting.acceptingBool(
            delivery: self.nativeForeground,
            onDispatch: { records.append($0) },
            operation: { true }))
        #expect(try FocusDispatchAccounting.acceptingBool(
            delivery: self.valueForeground,
            onDispatch: { records.append($0) },
            operation: { true }))
        #expect(records == [.accepted(self.nativeForeground), .accepted(self.valueForeground)])
    }

    @Test
    func `pre-cancelled focus submissions dispatch no activation main or raise units`() {
        var records: [FocusDispatchRecord] = []
        var operations: [String] = []
        let cancel: () throws -> Void = { throw CancellationError() }

        #expect(throws: CancellationError.self) {
            _ = try FocusDispatchAccounting.acceptingBool(
                delivery: self.nativeForeground,
                onDispatch: { records.append($0) },
                checkCancellation: cancel,
                operation: { operations.append("activate"); return true })
        }
        #expect(throws: CancellationError.self) {
            _ = try FocusDispatchAccounting.acceptingBool(
                delivery: self.valueForeground,
                onDispatch: { records.append($0) },
                checkCancellation: cancel,
                operation: { operations.append("main"); return true })
        }
        #expect(throws: CancellationError.self) {
            _ = try FocusDispatchAccounting.submittingThrowing(
                delivery: self.actionForeground,
                onDispatch: { records.append($0) },
                checkCancellation: cancel,
                operation: { operations.append("raise") })
        }

        #expect(operations.isEmpty)
        #expect(records.isEmpty)
    }

    @Test
    func `throwing AX request records ambiguous attempt and accepted success`() throws {
        var records: [FocusDispatchRecord] = []

        #expect(throws: FocusDispatchProbeError.self) {
            try FocusDispatchAccounting.submittingThrowing(
                delivery: self.actionForeground,
                onDispatch: { records.append($0) },
                operation: { throw FocusDispatchProbeError.rejected })
        }
        #expect(records == [.mayHaveDispatched(self.actionForeground)])

        let value = try FocusDispatchAccounting.submittingThrowing(
            delivery: self.actionForeground,
            onDispatch: { records.append($0) },
            operation: { () throws -> Int in 42 })
        #expect(value == 42)
        #expect(records == [
            .mayHaveDispatched(self.actionForeground),
            .accepted(self.actionForeground),
        ])
    }

    @Test
    func `throwing AX attempt resolves to indeterminate completion unknown`() {
        var sequence = DesktopActionSequenceAccumulator()

        #expect(throws: FocusDispatchProbeError.self) {
            try FocusDispatchAccounting.submittingThrowing(
                delivery: self.actionForeground,
                onDispatch: { sequence.record($0.sequenceStep) },
                operation: { throw FocusDispatchProbeError.rejected })
        }
        let leaf = DesktopActionFailure.preDispatchRefusal(
            reason: .operationUnsupported,
            message: "AX raise returned an error")
        let failure = sequence.failure(
            combining: leaf,
            message: "Focus completion is unknown")

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.evidence == .completionUnknown)
        #expect(failure.outcome.delivery == self.actionForeground)
        #expect(failure.outcome.dispatchState.unitCount == .one)
    }

    @Test
    func `unknown Space success is accounted while active Space is skipped`() async throws {
        #expect(FocusDispatchAccounting.shouldAccountSpaceSwitch(isActive: nil))
        #expect(FocusDispatchAccounting.shouldAccountSpaceSwitch(isActive: false))
        #expect(!FocusDispatchAccounting.shouldAccountSpaceSwitch(isActive: true))
        var records: [FocusDispatchRecord] = []

        try await FocusDispatchAccounting.submittingAsync(
            delivery: self.nativeForeground,
            onDispatch: { records.append($0) },
            operation: { () async throws in })
        #expect(records == [.accepted(self.nativeForeground)])
    }

    @Test
    func `unknown Space cancellation records possible unit`() async {
        var sequence = DesktopActionSequenceAccumulator()

        await #expect(throws: CancellationError.self) {
            try await FocusDispatchAccounting.submittingAsync(
                delivery: self.nativeForeground,
                onDispatch: { sequence.record($0.sequenceStep) },
                operation: { throw CancellationError() })
        }
        let failure = sequence.cancellationFailure(
            fallbackRoute: .local,
            message: "Space switch cancelled",
            hint: "Observe before retrying",
            causeDescription: "cancelled")

        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.evidence == .completionUnknown)
        #expect(failure?.outcome.delivery == self.nativeForeground)
        #expect(failure?.outcome.dispatchState.unitCount == .one)
    }

    @Test
    func `exact Space focus plans preserve the generation-pinned window receipt`() {
        let identity = WindowMutationIdentity(
            windowID: 4040,
            ownerProcessIdentifier: 999,
            ownerProcessStartIdentity: 1234,
            capturedBounds: .init(x: 10, y: 20, width: 300, height: 200))

        #expect(FocusSpaceActionPlan.make(
            bringToCurrentSpace: true,
            expectedIdentity: identity) == .moveToCurrentSpace(expectedIdentity: identity))
        #expect(FocusSpaceActionPlan.make(
            bringToCurrentSpace: false,
            expectedIdentity: identity) == .switchToWindowSpace(expectedIdentity: identity))
    }

    @Test
    func `pinned Space outcome accounting preserves exact units and delivery`() {
        let background = DesktopActionOutcome.Delivery(
            mechanism: .nativeFramework,
            mode: .background)
        var records: [FocusDispatchRecord] = []

        FocusDispatchAccounting.report(
            outcome: .confirmedChange(
                delivery: background,
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)),
            onDispatch: { records.append($0) })
        FocusDispatchAccounting.report(
            outcome: .confirmedNoChange(),
            onDispatch: { records.append($0) })

        #expect(records == [.accepted(background), .accepted(background)])
    }

    @Test
    func `pinned Space outcome validation rejects missing receipt as one possible exact dispatch`() throws {
        let identity = WindowMutationIdentity(
            windowID: 4040,
            ownerProcessIdentifier: 999,
            ownerProcessStartIdentity: 1234,
            capturedBounds: .init(x: 10, y: 20, width: 300, height: 200))
        let result = UIAutomationActionResult<Void>(payload: (), outcome: nil)

        let failure = #expect(throws: DesktopActionFailure.self) {
            _ = try FocusDispatchAccounting.requirePinnedSpaceOutcome(
                result,
                expectedIdentity: identity,
                requiredDeliveryMode: .foreground,
                operation: "Exact-window Space switch")
        }

        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.delivery == .init(mechanism: .nativeFramework, mode: .foreground))
        #expect(failure?.outcome.dispatchState.unitCount == .one)
        #expect(failure?.targetReceipt == DesktopActionTargetReceipt(
            processIdentifier: 999,
            processStartIdentity: 1234,
            windowID: 4040))
    }

    @Test
    func `verified exact focus promotes definite delivery for strict foreground consumers`() {
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(FocusDispatchRecord.accepted(self.actionForeground).sequenceStep)
        let unverified = sequence.successResolution()

        #expect(unverified.outcome?.state == .dispatchedUnverified)
        let verified = FocusDispatchAccounting.verifiedFocusOutcome(unverified)
        #expect(verified.state == .confirmedChange)
        #expect(verified.isConfirmed)
        #expect(verified.delivery == self.actionForeground)
        #expect(verified.dispatchState.unitCount == .one)

        let noDispatch = FocusDispatchAccounting.verifiedFocusOutcome(
            DesktopActionSequenceAccumulator().successResolution())
        #expect(noDispatch.state == .confirmedNoChange)
        #expect(noDispatch.dispatchState == .none)
    }

    @Test
    func `verified focus never promotes a possible dispatch`() {
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(FocusDispatchRecord.mayHaveDispatched(self.actionForeground).sequenceStep)

        let outcome = FocusDispatchAccounting.verifiedFocusOutcome(sequence.successResolution())

        #expect(outcome.state == .indeterminate)
        #expect(!outcome.isConfirmed)
        #expect(outcome.dispatchState.unitCount == .one)
    }

    @Test
    func `pinned Space failure is composed once for one and two unit focus sequences`() throws {
        let identity = WindowMutationIdentity(
            windowID: 4040,
            ownerProcessIdentifier: 999,
            ownerProcessStartIdentity: 1234,
            capturedBounds: .init(x: 10, y: 20, width: 300, height: 200))
        let bounds = try #require(identity.capturedBounds)
        let target = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds))
        let result = UIAutomationActionResult<Void>(
            payload: (),
            outcome: .indeterminate(
                delivery: self.nativeForeground,
                evidence: .completionUnknown,
                unitCount: .one),
            targetIdentity: target)
        var records: [FocusDispatchRecord] = []
        let failure = #expect(throws: DesktopActionFailure.self) {
            try FocusDispatchAccounting.reportPinnedSpaceOutcome(
                result,
                expectedIdentity: identity,
                requiredDeliveryMode: .foreground,
                operation: "Exact-window Space switch",
                onDispatch: { records.append($0) })
        }
        #expect(records.isEmpty)
        let leaf = try #require(failure)

        let emptySequence = DesktopActionSequenceAccumulator()
        let oneUnit = emptySequence.failure(combining: leaf, message: "Focus failed")
        #expect(oneUnit.outcome.dispatchState.unitCount == .one)

        var prefixedSequence = DesktopActionSequenceAccumulator()
        prefixedSequence.record(FocusDispatchRecord.accepted(self.nativeForeground).sequenceStep)
        let twoUnits = prefixedSequence.failure(combining: leaf, message: "Focus failed")
        #expect(twoUnits.outcome.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(2))
    }
}

private enum FocusDispatchProbeError: Error {
    case rejected
}
